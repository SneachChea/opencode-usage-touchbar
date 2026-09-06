import AppKit
import Combine
import Darwin
import ObjectiveC
import Security
import ServiceManagement
import SwiftUI

private let usageDashboardURL = URL(string: "https://chatgpt.com/codex/settings/usage")!
private let petGalleryURL = URL(string: "https://codexpet.top")!

struct RateWindow: Sendable {
    let usedPercent: Int
    let durationMinutes: Int?
    let resetsAt: Date?

    var remainingPercent: Int { max(0, min(100, 100 - usedPercent)) }
}

struct UsageSnapshot: Sendable {
    let primary: RateWindow?
    let secondary: RateWindow?
    let plan: String?
    let creditBalance: String?
    let unlimitedCredits: Bool
    let resetCredits: Int
    let fetchedAt: Date
}

struct OpenCodeGoUsageSnapshot: Sendable {
    let rolling: RateWindow?
    let weekly: RateWindow?
    let monthly: RateWindow?
    let fetchedAt: Date
}

enum UsageClientError: LocalizedError {
    case codexNotFound
    case launchFailed(String)
    case timedOut
    case invalidResponse
    case server(String)

    func message(language: AppLanguage) -> String {
        switch self {
        case .codexNotFound:
            return L10n.string("error_codex_not_found", language: language)
        case .launchFailed(let message):
            return L10n.format("error_launch_failed", language: language, message)
        case .timedOut:
            return L10n.string("error_timeout", language: language)
        case .invalidResponse:
            return L10n.string("error_invalid_response", language: language)
        case .server(let message):
            return L10n.format("error_server", language: language, message)
        }
    }

    var errorDescription: String? { message(language: .system) }
}

enum OpenCodeGoUsageClientError: LocalizedError, Equatable {
    case missingAPIKey
    case invalidCredentials
    case timedOut
    case invalidResponse
    case server(String)

    func message(language: AppLanguage) -> String {
        switch self {
        case .missingAPIKey:
            return L10n.string("error_opencode_go_key_missing", language: language)
        case .invalidCredentials:
            return L10n.string("error_opencode_go_invalid_credentials", language: language)
        case .timedOut:
            return L10n.string("error_timeout", language: language)
        case .invalidResponse:
            return L10n.string("error_opencode_go_invalid_response", language: language)
        case .server(let message):
            return L10n.format("error_opencode_go_server", language: language, message)
        }
    }

    var errorDescription: String? { message(language: .system) }
}

enum CodexUsageClient {
    static func fetch() throws -> UsageSnapshot {
        guard let executable = findCodexExecutable() else {
            throw UsageClientError.codexNotFound
        }

        let process = Process()
        process.executableURL = executable
        process.arguments = ["app-server", "--stdio"]

        var environment = ProcessInfo.processInfo.environment
        environment["TERM"] = "dumb"
        // The OpenCode Go key belongs to this app only; never hand it to the
        // Codex child process.
        environment["OPENCODE_GO_API_KEY"] = nil
        process.environment = environment

        let input = Pipe()
        let output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        // stderr is never drained; a full pipe would stall the child.
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            throw UsageClientError.launchFailed(error.localizedDescription)
        }

        let timedOut = LockedFlag()
        let timeout = DispatchWorkItem {
            if process.isRunning {
                timedOut.value = true
                process.terminate()
            }
        }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 15, execute: timeout)

        let initialize: [String: Any] = [
            "id": 1,
            "method": "initialize",
            "params": [
                "clientInfo": [
                    "name": "opencode-usage-touchbar",
                    "title": "OpenCode Usage TouchBar",
                    "version": "1.0.0"
                ],
                "capabilities": ["experimentalApi": true]
            ]
        ]
        let request: [String: Any] = [
            "id": 2,
            "method": "account/rateLimits/read",
            "params": NSNull()
        ]

        do {
            let payload = try line(for: initialize) + line(for: request)
            try input.fileHandleForWriting.write(contentsOf: payload)
        } catch {
            if process.isRunning { process.terminate() }
            timeout.cancel()
            throw UsageClientError.launchFailed(error.localizedDescription)
        }

        // A usage reply is well under 10 KB; 512 KB bounds a misbehaving child.
        let maxPendingBytes = 512 * 1024
        var pending = Data()
        var responseLine: Data?
        outer: while true {
            let chunk = output.fileHandleForReading.availableData
            if chunk.isEmpty { break } // EOF: the child exited or closed stdout.
            pending.append(chunk)
            // Parse each complete NDJSON line once, stop at the reply we asked for.
            for line in drainLines(from: &pending) {
                if isResponse(id: 2, in: line) {
                    responseLine = line
                    break outer
                }
            }
            // Only a newline-less giant line can exceed the cap after draining.
            if pending.count > maxPendingBytes { break }
        }
        try? input.fileHandleForWriting.close()
        if process.isRunning { process.terminate() }
        process.waitUntilExit()
        timeout.cancel()

        guard let responseLine else {
            if timedOut.value && pending.isEmpty {
                throw UsageClientError.timedOut
            }
            guard pending.isEmpty == false, pending.count <= maxPendingBytes else {
                throw UsageClientError.invalidResponse
            }
            // Final line may arrive without a trailing newline.
            return try parseResponse(pending)
        }
        return try parseResponse(responseLine)
    }

    /// Remove and return the complete `\n`-terminated lines in `buffer`, keeping
    /// any trailing partial line for the next read.
    static func drainLines(from buffer: inout Data) -> [Data] {
        var lines: [Data] = []
        while let newline = buffer.firstIndex(of: 0x0A) {
            lines.append(buffer.subdata(in: buffer.startIndex..<newline))
            buffer.removeSubrange(buffer.startIndex...newline)
        }
        return lines
    }

    static func isResponse(id: Int, in line: Data) -> Bool {
        guard let json = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else {
            return false
        }
        return (json["id"] as? NSNumber)?.intValue == id
    }

    private static func line(for object: [String: Any]) throws -> Data {
        var data = try JSONSerialization.data(withJSONObject: object)
        data.append(0x0A)
        return data
    }

    private static func parseResponse(_ data: Data) throws -> UsageSnapshot {
        guard let text = String(data: data, encoding: .utf8) else {
            throw UsageClientError.invalidResponse
        }

        for line in text.split(whereSeparator: \.isNewline) {
            guard let lineData = String(line).data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                  (json["id"] as? NSNumber)?.intValue == 2 else {
                continue
            }

            if let error = json["error"] as? [String: Any] {
                throw UsageClientError.server(error["message"] as? String ?? "Unknown error")
            }

            guard let result = json["result"] as? [String: Any],
                  let limits = preferredLimits(from: result) else {
                throw UsageClientError.invalidResponse
            }

            let credits = limits["credits"] as? [String: Any]
            let resets = result["rateLimitResetCredits"] as? [String: Any]

            return UsageSnapshot(
                primary: parseWindow(limits["primary"]),
                secondary: parseWindow(limits["secondary"]),
                plan: limits["planType"] as? String,
                creditBalance: credits?["balance"] as? String,
                unlimitedCredits: credits?["unlimited"] as? Bool ?? false,
                resetCredits: (resets?["availableCount"] as? NSNumber)?.intValue ?? 0,
                fetchedAt: Date()
            )
        }

        throw UsageClientError.invalidResponse
    }

    private static func preferredLimits(from result: [String: Any]) -> [String: Any]? {
        if let buckets = result["rateLimitsByLimitId"] as? [String: Any],
           let codex = buckets["codex"] as? [String: Any] {
            return codex
        }
        return result["rateLimits"] as? [String: Any]
    }

    private static func parseWindow(_ value: Any?) -> RateWindow? {
        guard let object = value as? [String: Any],
              let used = (object["usedPercent"] as? NSNumber)?.intValue else {
            return nil
        }
        let duration = (object["windowDurationMins"] as? NSNumber)?.intValue
        let resetTimestamp = (object["resetsAt"] as? NSNumber)?.doubleValue
        return RateWindow(
            usedPercent: used,
            durationMinutes: duration,
            resetsAt: resetTimestamp.map(Date.init(timeIntervalSince1970:))
        )
    }

    static var isInstalled: Bool { findCodexExecutable() != nil }

    private static func findCodexExecutable() -> URL? {
        let candidates = [
            "/Applications/ChatGPT.app/Contents/Resources/codex",
            "/Applications/Codex.app/Contents/Resources/codex",
            "/opt/homebrew/bin/codex",
            "/usr/local/bin/codex"
        ]
        return candidates
            .first(where: { FileManager.default.isExecutableFile(atPath: $0) })
            .map(URL.init(fileURLWithPath:))
    }
}

enum OpenCodeGoUsageClient {
    private static let usageURL = URL(string: "https://opencode.ai/zen/go/v1/usage")!
    /// Reused stateless ephemeral session: no cookies, no on-disk cache, and a
    /// hard 15 s wall-clock bound per request (timeoutInterval alone is only an
    /// idle-data timer).
    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = false
        config.timeoutIntervalForResource = 15
        return URLSession(configuration: config, delegate: RedirectGuard(), delegateQueue: nil)
    }()
    private static var cachedAPIKey: String?

    static func cacheAPIKey(_ key: String?) {
        cachedAPIKey = key
    }

    static var apiKey: String? {
        if let cached = cachedAPIKey, !cached.isEmpty {
            return cached
        }
        if let stored = KeychainStore.loadOpenCodeGoAPIKey(), !stored.isEmpty {
            return stored
        }
        let value = ProcessInfo.processInfo.environment["OPENCODE_GO_API_KEY"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (value?.isEmpty ?? true) ? nil : value
    }

    static func fetch() async throws -> OpenCodeGoUsageSnapshot {
        guard let apiKey else { throw OpenCodeGoUsageClientError.missingAPIKey }

        var requestBuilder = URLRequest(url: usageURL)
        requestBuilder.httpMethod = "GET"
        requestBuilder.timeoutInterval = 15
        requestBuilder.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        requestBuilder.setValue("application/json", forHTTPHeaderField: "Accept")
        let request = requestBuilder

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw OpenCodeGoUsageClientError.invalidResponse
            }
            switch http.statusCode {
            case 200:
                guard data.count <= 512 * 1024 else {
                    throw OpenCodeGoUsageClientError.invalidResponse
                }
                return try parse(data)
            case 401, 403:
                throw OpenCodeGoUsageClientError.invalidCredentials
            default:
                throw OpenCodeGoUsageClientError.server(serverMessage(from: data) ?? "HTTP \(http.statusCode)")
            }
        } catch let error as OpenCodeGoUsageClientError {
            throw error
        } catch let error as URLError where error.code == .timedOut {
            throw OpenCodeGoUsageClientError.timedOut
        } catch {
            throw OpenCodeGoUsageClientError.server(error.localizedDescription)
        }
    }

    static func parse(_ data: Data) throws -> OpenCodeGoUsageSnapshot {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let usage = object["usage"] as? [String: Any] else {
            throw OpenCodeGoUsageClientError.invalidResponse
        }
        guard let rolling = parseWindow(usage["rolling"], durationMinutes: 5 * 60) else {
            throw OpenCodeGoUsageClientError.invalidResponse
        }
        return OpenCodeGoUsageSnapshot(
            rolling: rolling,
            weekly: parseWindow(usage["weekly"], durationMinutes: 7 * 24 * 60),
            monthly: parseWindow(usage["monthly"], durationMinutes: nil),
            fetchedAt: Date()
        )
    }

    private static func parseWindow(_ value: Any?, durationMinutes: Int?) -> RateWindow? {
        guard let object = value as? [String: Any],
              let percent = (object["percent"] as? NSNumber)?.intValue else {
            return nil
        }
        return RateWindow(
            usedPercent: percent,
            durationMinutes: durationMinutes,
            resetsAt: parseDate(object["resetsAt"])
        )
    }

    private static func parseDate(_ value: Any?) -> Date? {
        guard let string = value as? String else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: string) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: string)
    }

    private static func serverMessage(from data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        if let error = object["error"] as? [String: Any], let message = error["message"] as? String {
            return message
        }
        return object["message"] as? String
    }
}

private final class RedirectGuard: NSObject, URLSessionTaskDelegate {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        let sourceHost = task.originalRequest?.url?.host?.lowercased()
        let destinationHost = request.url?.host?.lowercased()
        if sourceHost != nil, sourceHost == destinationHost, request.url?.scheme?.lowercased() == "https" {
            completionHandler(request)
        } else {
            completionHandler(nil)
        }
    }
}

private enum KeychainStore {
    private static let service = "com.local.opencodeusagetouchbar"
    private static let account = "opencode-go-api-key"

    static func loadOpenCodeGoAPIKey() -> String? {
        var query = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func saveOpenCodeGoAPIKey(_ key: String) throws {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw KeychainError.status(errSecParam) }
        let data = Data(trimmed.utf8)
        var query = baseQuery()
        if SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess {
            let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
            guard status == errSecSuccess else { throw KeychainError.status(status) }
        } else {
            query[kSecValueData as String] = data
            let status = SecItemAdd(query as CFDictionary, nil)
            guard status == errSecSuccess else { throw KeychainError.status(status) }
        }
    }

    static func deleteOpenCodeGoAPIKey() {
        SecItemDelete(baseQuery() as CFDictionary)
    }

    private static func baseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock
        ]
    }
}

private enum KeychainError: LocalizedError {
    case status(OSStatus)

    var errorDescription: String? {
        switch self {
        case .status(let status):
            return SecCopyErrorMessageString(status, nil) as String? ?? "OSStatus \(status)"
        }
    }
}

private final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = false

    var value: Bool {
        get {
            lock.lock()
            defer { lock.unlock() }
            return storage
        }
        set {
            lock.lock()
            storage = newValue
            lock.unlock()
        }
    }
}

enum TouchBarMode: String, CaseIterable, Identifiable {
    case always
    case codexActive
    case disabled

    var id: String { rawValue }

    var localizationKey: String {
        switch self {
        case .always: return "touch_bar_mode_always"
        case .codexActive: return "touch_bar_mode_codex"
        case .disabled: return "touch_bar_mode_disabled"
        }
    }
}

@MainActor
final class UsageStore: ObservableObject {
    @Published var snapshot: UsageSnapshot?
    @Published var errorMessage: String?
    @Published var isLoading = false
    @Published var openCodeGoSnapshot: OpenCodeGoUsageSnapshot?
    @Published var openCodeGoErrorMessage: String?
    @Published var openCodeGoIsLoading = false
    @Published var openCodeGoKeyStored: Bool

    var openCodeGoConfigured: Bool { OpenCodeGoUsageClient.apiKey != nil }
    @Published var launchAtLogin = SMAppService.mainApp.status == .enabled
    @Published var menuIconName: String {
        didSet { UserDefaults.standard.set(menuIconName, forKey: "menuIconName") }
    }
    @Published var menuIconSize: Double {
        didSet { UserDefaults.standard.set(menuIconSize, forKey: "menuIconSize") }
    }
    @Published var menuTextSize: Double {
        didSet { UserDefaults.standard.set(menuTextSize, forKey: "menuTextSize") }
    }
    @Published var touchBarMode: TouchBarMode {
        didSet {
            UserDefaults.standard.set(touchBarMode.rawValue, forKey: "touchBarMode")
        }
    }
    @Published var petID: String? {
        didSet {
            if let petID {
                UserDefaults.standard.set(petID, forKey: "petID")
            } else {
                UserDefaults.standard.removeObject(forKey: "petID")
            }
        }
    }
    @Published var petsFolderOverride: String? {
        didSet {
            if let petsFolderOverride {
                UserDefaults.standard.set(petsFolderOverride, forKey: "petFolder")
            } else {
                UserDefaults.standard.removeObject(forKey: "petFolder")
            }
        }
    }
    @Published var petMinInterval: Double {
        didSet { UserDefaults.standard.set(petMinInterval, forKey: "petMinInterval") }
    }
    @Published var petMaxInterval: Double {
        didSet { UserDefaults.standard.set(petMaxInterval, forKey: "petMaxInterval") }
    }
    @Published private(set) var availablePets: [PetSummary] = []
    @Published private(set) var codexConfigured = CodexUsageClient.isInstalled
    @Published var appLanguage: AppLanguage {
        didSet {
            UserDefaults.standard.set(appLanguage.rawValue, forKey: "appLanguage")
            if let lastUsageError {
                errorMessage = lastUsageError.message(language: appLanguage)
            }
            if let lastOpenCodeGoError {
                openCodeGoErrorMessage = lastOpenCodeGoError.message(language: appLanguage)
            }
        }
    }

    private var refreshTask: Task<Void, Never>?
    private var codexTask: Task<Void, Never>?
    private var openCodeGoTask: Task<Void, Never>?
    private var lastUsageError: UsageClientError?
    private var lastOpenCodeGoError: OpenCodeGoUsageClientError?
    private var openCodeGoFetchGeneration = 0

    init() {
        let defaults = UserDefaults.standard
        menuIconName = defaults.string(forKey: "menuIconName") ?? "gauge.with.dots.needle.67percent"
        menuIconSize = defaults.object(forKey: "menuIconSize") as? Double ?? 12
        menuTextSize = defaults.object(forKey: "menuTextSize") as? Double ?? 12
        // The bundle identifier changed at rename, so old preferences are
        // unreachable; default to the persistent mode the user sees.
        touchBarMode = defaults.string(forKey: "touchBarMode").flatMap(TouchBarMode.init(rawValue:)) ?? .always
        appLanguage = defaults.string(forKey: "appLanguage").flatMap(AppLanguage.init(rawValue:)) ?? .system
        petID = defaults.string(forKey: "petID")
        petsFolderOverride = defaults.string(forKey: "petFolder")
        petMinInterval = defaults.object(forKey: "petMinInterval") as? Double ?? 30
        petMaxInterval = defaults.object(forKey: "petMaxInterval") as? Double ?? 90
        openCodeGoKeyStored = KeychainStore.loadOpenCodeGoAPIKey() != nil
        refreshAvailablePets()
        refresh()
        refreshTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 300_000_000_000)
                guard !Task.isCancelled, let self else { return }
                self.refresh()
            }
        }
    }

    deinit {
        refreshTask?.cancel()
        codexTask?.cancel()
        openCodeGoTask?.cancel()
    }

    var petsFolderURL: URL? {
        if let petsFolderOverride {
            return URL(fileURLWithPath: petsFolderOverride)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/pets", isDirectory: true)
    }

    var petsFolderDisplay: String { petsFolderURL?.path ?? "~/.codex/pets" }

    func refreshAvailablePets() {
        guard let url = petsFolderURL else {
            availablePets = []
            return
        }
        availablePets = CodexPetLibrary.scan(folder: url)
    }

    var menuTitle: String {
        let codexPart: String
        if let snapshot {
            let fiveHour = snapshot.primary.map { "\($0.remainingPercent)%" } ?? "–"
            let weekly = snapshot.secondary.map { "\($0.remainingPercent)%" } ?? "–"
            codexPart = openCodeGoConfigured ? "C \(fiveHour)·\(weekly)" : "\(fiveHour)·\(weekly)"
        } else {
            codexPart = isLoading ? "…" : "!"
        }

        guard openCodeGoConfigured else { return codexPart }

        let goPart: String
        if let go = openCodeGoSnapshot {
            let rolling = go.rolling.map { "\($0.remainingPercent)%" } ?? "–"
            let weekly = go.weekly.map { "\($0.remainingPercent)%" } ?? "–"
            let monthly = go.monthly.map { "\($0.remainingPercent)%" } ?? "–"
            goPart = "\(rolling)·\(weekly)·\(monthly)"
        } else {
            goPart = openCodeGoIsLoading ? "…" : "–"
        }
        return "\(codexPart) | G \(goPart)"
    }

    func tr(_ key: String) -> String {
        L10n.string(key, language: appLanguage)
    }

    func tr(_ key: String, _ arguments: CVarArg...) -> String {
        String(format: tr(key), locale: appLanguage.locale, arguments: arguments)
    }

    func formatDate(_ date: Date, includeDate: Bool = true) -> String {
        let formatter = DateFormatter()
        formatter.locale = appLanguage.locale
        formatter.setLocalizedDateFormatFromTemplate(includeDate ? "MdHm" : "Hm")
        return formatter.string(from: date)
    }

    func refresh() {
        refreshCodex()
        refreshOpenCodeGo()
    }

    private func refreshCodex() {
        codexConfigured = CodexUsageClient.isInstalled
        guard !isLoading else { return }
        isLoading = true
        errorMessage = nil
        lastUsageError = nil

        codexTask = Task {
            do {
                let value = try await Task.detached(priority: .userInitiated) {
                    try CodexUsageClient.fetch()
                }.value
                snapshot = value
            } catch let error as UsageClientError {
                lastUsageError = error
                errorMessage = error.message(language: appLanguage)
            } catch {
                errorMessage = error.localizedDescription
            }
            isLoading = false
        }
    }

    private func refreshOpenCodeGo() {
        guard openCodeGoConfigured, !openCodeGoIsLoading else { return }
        openCodeGoFetchGeneration += 1
        let generation = openCodeGoFetchGeneration
        openCodeGoIsLoading = true
        openCodeGoErrorMessage = nil
        lastOpenCodeGoError = nil

        openCodeGoTask = Task {
            do {
                let value = try await OpenCodeGoUsageClient.fetch()
                guard generation == openCodeGoFetchGeneration else { return }
                openCodeGoSnapshot = value
            } catch let error as OpenCodeGoUsageClientError {
                guard generation == openCodeGoFetchGeneration else { return }
                lastOpenCodeGoError = error
                openCodeGoErrorMessage = error.message(language: appLanguage)
            } catch {
                guard generation == openCodeGoFetchGeneration else { return }
                openCodeGoErrorMessage = error.localizedDescription
            }
            if generation == openCodeGoFetchGeneration {
                openCodeGoIsLoading = false
            }
        }
    }

    func saveOpenCodeGoAPIKey(_ key: String) -> String? {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            try KeychainStore.saveOpenCodeGoAPIKey(trimmed)
        } catch {
            return tr("error_opencode_go_key_save", error.localizedDescription)
        }
        OpenCodeGoUsageClient.cacheAPIKey(trimmed)
        openCodeGoKeyStored = true
        restartOpenCodeGoFetch()
        refreshOpenCodeGo()
        return nil
    }

    func removeOpenCodeGoAPIKey() {
        KeychainStore.deleteOpenCodeGoAPIKey()
        OpenCodeGoUsageClient.cacheAPIKey(nil)
        restartOpenCodeGoFetch()
        openCodeGoKeyStored = false
        lastOpenCodeGoError = nil
        openCodeGoSnapshot = nil
        openCodeGoErrorMessage = nil
    }

    /// Invalidate the in-flight request so a saved or removed key cannot keep
    /// being refreshed with the previous credentials.
    private func restartOpenCodeGoFetch() {
        openCodeGoTask?.cancel()
        openCodeGoTask = nil
        openCodeGoFetchGeneration += 1
        openCodeGoIsLoading = false
    }

    func openDashboard() {
        NSWorkspace.shared.open(usageDashboardURL)
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            launchAtLogin = enabled
        } catch {
            errorMessage = tr("error_launch_at_login", error.localizedDescription)
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
    }
}

struct UsageWindowRow: View {
    @ObservedObject var store: UsageStore
    let titleKey: String
    let window: RateWindow?

    private var color: Color {
        guard let remaining = window?.remainingPercent else { return .secondary }
        if remaining <= 10 { return .red }
        if remaining <= 25 { return .orange }
        return .accentColor
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text(store.tr(titleKey))
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                Text(window.map { store.tr("remaining", $0.remainingPercent) } ?? store.tr("unavailable"))
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .foregroundStyle(color)
            }

            ProgressView(value: Double(window?.remainingPercent ?? 0), total: 100)
                .tint(color)

            if let reset = window?.resetsAt {
                Text(store.tr("reset_at", store.formatDate(reset)))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

}

struct UsagePopover: View {
    @ObservedObject var store: UsageStore
    let onShowSettings: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Codex Usage")
                        .font(.headline)
                    Text(store.snapshot?.plan?.uppercased() ?? store.tr("loading_account"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    onShowSettings()
                } label: {
                    Image(systemName: "gearshape")
                }
                .buttonStyle(.borderless)
                .help(store.tr("settings"))
                if store.isLoading {
                    ProgressView()
                        .controlSize(.small)
                }
            }

            if let snapshot = store.snapshot {
                UsageWindowRow(store: store, titleKey: "five_hour_quota", window: snapshot.primary)
                UsageWindowRow(store: store, titleKey: "weekly_quota", window: snapshot.secondary)

                Divider()

                HStack(spacing: 18) {
                    Label(creditLabel(snapshot), systemImage: "creditcard")
                    if snapshot.resetCredits > 0 {
                        Label(store.tr("reset_count", snapshot.resetCredits), systemImage: "arrow.counterclockwise.circle")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)

                Text(store.tr("updated_at", store.formatDate(snapshot.fetchedAt, includeDate: false)))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            } else if let message = store.errorMessage {
                Label(message, systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let message = store.errorMessage, store.snapshot != nil {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()

            HStack {
                Text(store.tr("go_title"))
                    .font(.headline)
                Spacer()
                if store.openCodeGoIsLoading {
                    ProgressView()
                        .controlSize(.small)
                }
            }

            if let go = store.openCodeGoSnapshot {
                UsageWindowRow(store: store, titleKey: "go_rolling_quota", window: go.rolling)
                UsageWindowRow(store: store, titleKey: "go_weekly_quota", window: go.weekly)
                UsageWindowRow(store: store, titleKey: "go_monthly_quota", window: go.monthly)

                Text(store.tr("updated_at", store.formatDate(go.fetchedAt, includeDate: false)))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            } else if !store.openCodeGoConfigured {
                Text(store.tr("error_opencode_go_key_missing"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else if let message = store.openCodeGoErrorMessage {
                Label(message, systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let message = store.openCodeGoErrorMessage, store.openCodeGoSnapshot != nil {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()

            HStack {
                Button {
                    store.refresh()
                } label: {
                    Label(store.tr("refresh"), systemImage: "arrow.clockwise")
                }
                .disabled(store.isLoading)

                Button {
                    store.openDashboard()
                } label: {
                    Label(store.tr("official_usage"), systemImage: "safari")
                }

                Spacer()

                Button {
                    NSApplication.shared.terminate(nil)
                } label: {
                    Image(systemName: "power")
                }
                .help(store.tr("quit"))
                .fixedSize()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)

            Text(versionLabel)
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, alignment: .center)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .environment(\.locale, store.appLanguage.locale)
        .frame(width: 330)
    }

    private func creditLabel(_ snapshot: UsageSnapshot) -> String {
        if snapshot.unlimitedCredits { return store.tr("credits_unlimited") }
        if let balance = snapshot.creditBalance { return store.tr("credits_balance", balance) }
        return store.tr("credits_unavailable")
    }

    private var versionLabel: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "local"
        return "v\(version) · build \(build)"
    }
}

enum TouchBarSystemModal {
    private static let presentSelector = NSSelectorFromString(
        "presentSystemModalTouchBar:placement:systemTrayItemIdentifier:"
    )
    private static let dismissSelector = NSSelectorFromString("dismissSystemModalTouchBar:")
    private static let minimizeSelector = NSSelectorFromString("minimizeSystemModalTouchBar:")

    private typealias SetShowsCloseBox = @convention(c) (Bool) -> Void

    nonisolated(unsafe) private static let dfrHandle: UnsafeMutableRawPointer? = dlopen(
        "/System/Library/PrivateFrameworks/DFRFoundation.framework/DFRFoundation",
        RTLD_NOW
    )
    private static let setShowsCloseBox: SetShowsCloseBox? = {
        guard let dfrHandle,
              let pointer = dlsym(dfrHandle, "DFRSystemModalShowsCloseBoxWhenFrontMost") else {
            return nil
        }
        return unsafeBitCast(pointer, to: SetShowsCloseBox.self)
    }()

    static var isAvailable: Bool {
        class_getClassMethod(NSTouchBar.self, presentSelector) != nil &&
            class_getClassMethod(NSTouchBar.self, dismissSelector) != nil
    }

    /// Presents the bar as the system-modal Touch Bar. Placement 0 shares the bar
    /// with the Control Strip; placement 1 would cover it (not used).
    /// Calling this again while presented is cheap and idempotent - macOS reclaims
    /// the modal bar when apps switch, so it must be re-asserted on every activation.
    @discardableResult
    static func present(_ touchBar: NSTouchBar) -> Bool {
        guard let method = class_getClassMethod(NSTouchBar.self, presentSelector) else {
            return false
        }
        setShowsCloseBox?(false)
        typealias Function = @convention(c) (
            AnyObject,
            Selector,
            NSTouchBar,
            Int,
            NSString?
        ) -> Void
        let function = unsafeBitCast(method_getImplementation(method), to: Function.self)
        function(NSTouchBar.self, presentSelector, touchBar, 0, nil)
        return true
    }

    static func minimize(_ touchBar: NSTouchBar) {
        guard let method = class_getClassMethod(NSTouchBar.self, minimizeSelector) else {
            dismiss(touchBar)
            return
        }
        typealias Function = @convention(c) (AnyObject, Selector, NSTouchBar) -> Void
        let function = unsafeBitCast(method_getImplementation(method), to: Function.self)
        function(NSTouchBar.self, minimizeSelector, touchBar)
    }

    static func dismiss(_ touchBar: NSTouchBar) {
        guard let method = class_getClassMethod(NSTouchBar.self, dismissSelector) else { return }
        typealias Function = @convention(c) (AnyObject, Selector, NSTouchBar) -> Void
        let function = unsafeBitCast(method_getImplementation(method), to: Function.self)
        function(NSTouchBar.self, dismissSelector, touchBar)
    }
}

private extension NSTouchBarItem.Identifier {
    static let fiveHourUsage = NSTouchBarItem.Identifier("com.local.opencodeusagetouchbar.five-hour")
    static let weeklyUsage = NSTouchBarItem.Identifier("com.local.opencodeusagetouchbar.weekly")
    static let refreshUsage = NSTouchBarItem.Identifier("com.local.opencodeusagetouchbar.refresh")
    static let goRollingUsage = NSTouchBarItem.Identifier("com.local.opencodeusagetouchbar.go-rolling")
    static let goWeeklyUsage = NSTouchBarItem.Identifier("com.local.opencodeusagetouchbar.go-weekly")
    static let goMonthlyUsage = NSTouchBarItem.Identifier("com.local.opencodeusagetouchbar.go-monthly")
    static let openCodeLogo = NSTouchBarItem.Identifier("com.local.opencodeusagetouchbar.opencode-logo")
    static let noUsageSource = NSTouchBarItem.Identifier("com.local.opencodeusagetouchbar.no-source")
    static let pet = NSTouchBarItem.Identifier("com.local.opencodeusagetouchbar.pet")
}

final class TouchBarProgressView: NSView {
    var value: Double = 0 {
        didSet { needsDisplay = true }
    }
    var tintColor: NSColor = .controlAccentColor {
        didSet { needsDisplay = true }
    }

    override var intrinsicContentSize: NSSize { NSSize(width: 110, height: 5) }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let rect = bounds.insetBy(dx: 0, dy: 0.5)
        let radius = rect.height / 2
        NSColor.labelColor.withAlphaComponent(0.16).setFill()
        NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()

        let fraction = max(0, min(1, value / 100))
        guard fraction > 0 else { return }
        let fillRect = NSRect(x: rect.minX, y: rect.minY, width: rect.width * fraction, height: rect.height)
        tintColor.setFill()
        NSBezierPath(roundedRect: fillRect, xRadius: radius, yRadius: radius).fill()
    }
}

/// Animated, tappable pet shown on the Touch Bar. Between ambient actions the
/// pet rests on a single static idle frame: no continuous per-frame redraws.
/// The anti-App-Nap activity is held while this view is attached to a
/// presented bar (and released on detach or dealloc) so the ambient timer
/// keeps firing; the app-wide activity that existed before this release does
/// not.
@MainActor
final class TouchBarPetView: NSButton {
    private let package: CodexPetPackage
    private let store: UsageStore
    private var images: [PetAction: [NSImage]] = [:]
    private var petState: PetAction = .idle
    private var frameIndex = 0
    private var currentLoops = 0
    private var loopsRemaining = 1
    private var pendingReturnToIdle = false
    private var frameTimer: Timer?
    private var ambientTimer: Timer?
    private var activity: NSObjectProtocol?
    private var subscriptions = Set<AnyCancellable>()

    init(package: CodexPetPackage, store: UsageStore) {
        self.package = package
        self.store = store
        super.init(frame: .zero)
        isBordered = false
        imageScaling = .scaleProportionallyUpOrDown
        target = self
        action = #selector(petTapped)
        setAccessibilityLabel(store.tr("pet_accessibility", package.displayName))
        widthAnchor.constraint(equalToConstant: 30).isActive = true
        heightAnchor.constraint(equalToConstant: 30).isActive = true
        let frameSize = NSSize(width: CGFloat(PetAtlas.cellWidth), height: CGFloat(PetAtlas.cellHeight))
        for (action, frames) in package.frames {
            images[action] = frames.map { NSImage(cgImage: $0, size: frameSize) }
        }

        store.$petMinInterval
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.ambientSettingsChanged() }
            .store(in: &subscriptions)
        store.$petMaxInterval
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.ambientSettingsChanged() }
            .store(in: &subscriptions)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    deinit {
        frameTimer?.invalidate()
        ambientTimer?.invalidate()
        if let activity {
            ProcessInfo.processInfo.endActivity(activity)
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil {
            beginActivity()
            pendingReturnToIdle = false
            showIdle()
            armAmbientTimer()
        } else {
            frameTimer?.invalidate()
            ambientTimer?.invalidate()
            endActivity()
        }
    }

    @objc private func petTapped() {
        play(.waving, loops: 1)
    }

    private func play(_ action: PetAction, loops: Int) {
        guard action != .idle, let frames = images[action], !frames.isEmpty else {
            // A row with no frames must not kill the ambient chain.
            armAmbientTimer()
            return
        }
        petState = action
        frameIndex = 0
        currentLoops = 0
        loopsRemaining = loops
        pendingReturnToIdle = true
        showFrame()
        armFrameTimer()
    }

    /// Static idle frame: no frame timer, so an idle pet costs nothing to draw.
    private func showIdle() {
        frameTimer?.invalidate()
        petState = .idle
        frameIndex = 0
        currentLoops = 0
        showFrame()
    }

    private func showFrame() {
        guard let frames = images[petState], !frames.isEmpty else {
            image = nil
            return
        }
        image = frames[min(frameIndex, frames.count - 1)]
    }

    private func advanceFrame() {
        // A fired timer's Task can run just after the view detached; without
        // this guard the chain would re-arm on a hidden view until dealloc.
        guard window != nil else { return }
        guard petState != .idle else { return }
        guard let frames = images[petState], !frames.isEmpty else { return }
        frameIndex += 1
        if frameIndex >= frames.count {
            frameIndex = 0
            currentLoops += 1
            if pendingReturnToIdle && currentLoops >= loopsRemaining {
                finishAction()
                return
            }
        }
        showFrame()
        armFrameTimer()
    }

    private func finishAction() {
        pendingReturnToIdle = false
        showIdle()
        armAmbientTimer()
    }

    /// Timers run in `.common` mode so the pet keeps animating while a menu
    /// or other control is tracking (the default mode freezes them).
    private func armFrameTimer() {
        frameTimer?.invalidate()
        let delay = frameDelay()
        let timer = Timer(timeInterval: delay, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in self?.advanceFrame() }
        }
        RunLoop.main.add(timer, forMode: .common)
        frameTimer = timer
    }

    private func frameDelay() -> TimeInterval {
        let durations = PetAtlas.frameDurations[petState] ?? []
        guard !durations.isEmpty else { return 0.12 }
        return durations[min(frameIndex, durations.count - 1)]
    }

    private func armAmbientTimer() {
        ambientTimer?.invalidate()
        let minSeconds = Int(min(store.petMinInterval, store.petMaxInterval))
        let maxSeconds = Int(max(store.petMinInterval, store.petMaxInterval))
        let delay = TimeInterval(Int.random(in: minSeconds...maxSeconds))
        let timer = Timer(timeInterval: delay, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in self?.ambientTick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        ambientTimer = timer
    }

    private func ambientSettingsChanged() {
        // Re-arm with the new interval when the change happens while the pet
        // is visible; a change while hidden applies on the next presentation.
        guard window != nil else { return }
        armAmbientTimer()
    }

    private func ambientTick() {
        // Same detach race as advanceFrame; never start an action off-screen.
        guard window != nil else { return }
        guard let action = PetAtlas.ambientActions.randomElement() else { return }
        let loops = (action == .waving || action == .jumping) ? 1 : 2
        play(action, loops: loops)
    }

    private func beginActivity() {
        guard activity == nil else { return }
        activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiatedAllowingIdleSystemSleep],
            reason: "Keep the Touch Bar pet animation running"
        )
    }

    private func endActivity() {
        guard let activity else { return }
        self.activity = nil
        ProcessInfo.processInfo.endActivity(activity)
    }
}

@MainActor
final class UsageTouchBarController: NSObject, NSTouchBarDelegate {
    let touchBar = NSTouchBar()

    private let store: UsageStore
    private var fiveHourLabel: NSTextField?
    private var fiveHourProgress: TouchBarProgressView?
    private var weeklyLabel: NSTextField?
    private var weeklyProgress: TouchBarProgressView?
    private var refreshButton: NSButton?
    private var goRollingLabel: NSTextField?
    private var goRollingProgress: TouchBarProgressView?
    private var goWeeklyLabel: NSTextField?
    private var goWeeklyProgress: TouchBarProgressView?
    private var goMonthlyLabel: NSTextField?
    private var goMonthlyProgress: TouchBarProgressView?
    private var petPackage: CodexPetPackage?
    private var petView: TouchBarPetView?
    private var subscriptions = Set<AnyCancellable>()
    private var systemModalVisible = false
    private var codexIsFrontmost = false

    init(store: UsageStore) {
        self.store = store
        super.init()

        touchBar.delegate = self
        // Deliberately bumped when the default layout changes: macOS otherwise
        // re-applies the persisted custom item order, which pins newly added
        // items (the pet) to the right end of the bar. The previous identifier
        // referenced items that no longer exist (reset times, hide button).
        touchBar.customizationIdentifier = NSTouchBar.CustomizationIdentifier(
            "com.local.opencodeusagetouchbar.usage.pet-v1"
        )
        updateDefaultItemIdentifiers()

        Publishers.CombineLatest3(store.$snapshot, store.$isLoading, store.$errorMessage)
            .receive(on: RunLoop.main)
            .sink { [weak self] _, _, _ in self?.updateItems() }
            .store(in: &subscriptions)

        Publishers.CombineLatest3(
            store.$openCodeGoSnapshot,
            store.$openCodeGoIsLoading,
            store.$openCodeGoErrorMessage
        )
        .receive(on: RunLoop.main)
        .sink { [weak self] _, _, _ in self?.updateItems() }
        .store(in: &subscriptions)

        store.$openCodeGoKeyStored
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.updateItems() }
            .store(in: &subscriptions)

        store.$appLanguage
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.updateItems() }
            .store(in: &subscriptions)

        store.$touchBarMode
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.applyPresentationMode(reassert: true) }
            .store(in: &subscriptions)

        store.$codexConfigured
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.updateItems() }
            .store(in: &subscriptions)

        store.$petID
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.reloadPetPackage() }
            .store(in: &subscriptions)

        store.$petsFolderOverride
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.reloadPetPackage() }
            .store(in: &subscriptions)

        NSWorkspace.shared.notificationCenter.publisher(
            for: NSWorkspace.didActivateApplicationNotification
        )
        .receive(on: RunLoop.main)
        .sink { [weak self] notification in
            guard let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey]
            as? NSRunningApplication else { return }
            self?.codexIsFrontmost = application.bundleIdentifier == "com.openai.codex"
            self?.applyPresentationMode(reassert: true)
        }
        .store(in: &subscriptions)

        codexIsFrontmost = NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.openai.codex"
        DistributedNotificationCenter.default().publisher(
            for: NSNotification.Name("com.apple.screenIsUnlocked")
        )
        .receive(on: RunLoop.main)
        .sink { [weak self] _ in
            guard let self, self.systemModalVisible else { return }
            TouchBarSystemModal.present(self.touchBar)
        }
        .store(in: &subscriptions)

        // Sleep can drop the modal bar without any screen-lock cycle, and DFR may
        // still be coming back when the wake notification lands, so assert once
        // immediately and once more shortly after.
        NSWorkspace.shared.notificationCenter.publisher(
            for: NSWorkspace.didWakeNotification
        )
        .receive(on: RunLoop.main)
        .sink { [weak self] _ in
            self?.refreshPresentation()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                self?.refreshPresentation()
            }
        }
        .store(in: &subscriptions)
        updateItems()
        applyPresentationMode()
    }

    deinit {
        if systemModalVisible {
            TouchBarSystemModal.dismiss(touchBar)
        }
    }

    func touchBar(
        _ touchBar: NSTouchBar,
        makeItemForIdentifier identifier: NSTouchBarItem.Identifier
    ) -> NSTouchBarItem? {
        switch identifier {
        case .fiveHourUsage:
            let result = makeUsageItem(identifier: identifier, title: store.tr("five_hour_short"))
            fiveHourLabel = result.label
            fiveHourProgress = result.progress
            updateItems()
            return result.item
        case .weeklyUsage:
            let result = makeUsageItem(identifier: identifier, title: store.tr("weekly_short"))
            weeklyLabel = result.label
            weeklyProgress = result.progress
            updateItems()
            return result.item
        case .refreshUsage:
            let item = NSCustomTouchBarItem(identifier: identifier)
            let button = NSButton(
                image: NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: store.tr("refresh_usage"))!,
                target: self,
                action: #selector(refreshUsage)
            )
            // Compact borderless icon instead of the default full-height bezel.
            button.isBordered = false
            button.contentTintColor = .controlAccentColor
            button.widthAnchor.constraint(equalToConstant: 28).isActive = true
            item.view = button
            item.customizationLabel = store.tr("refresh_codex_usage")
            refreshButton = button
            updateItems()
            return item
        case .goRollingUsage:
            let result = makeUsageItem(identifier: identifier, title: "5h", customizationKey: "go_quota_customization")
            goRollingLabel = result.label
            goRollingProgress = result.progress
            updateItems()
            return result.item
        case .goWeeklyUsage:
            let result = makeUsageItem(identifier: identifier, title: store.tr("weekly_prefix"), customizationKey: "go_quota_customization")
            goWeeklyLabel = result.label
            goWeeklyProgress = result.progress
            updateItems()
            return result.item
        case .goMonthlyUsage:
            let result = makeUsageItem(identifier: identifier, title: store.tr("monthly_prefix"), customizationKey: "go_quota_customization")
            goMonthlyLabel = result.label
            goMonthlyProgress = result.progress
            updateItems()
            return result.item
        case .pet:
            let item = NSCustomTouchBarItem(identifier: identifier)
            if let petPackage {
                let view = TouchBarPetView(package: petPackage, store: store)
                petView = view
                item.view = view
            } else {
                item.view = NSView()
            }
            item.customizationLabel = store.tr("pet_customization")
            return item
        case .noUsageSource:
            let item = NSCustomTouchBarItem(identifier: identifier)
            let label = NSTextField(labelWithString: store.tr("no_usage_source"))
            label.font = .systemFont(ofSize: 12, weight: .regular)
            label.textColor = .secondaryLabelColor
            item.view = label
            item.customizationLabel = store.tr("no_usage_source")
            return item
        case .openCodeLogo:
            let item = NSCustomTouchBarItem(identifier: identifier)
            let view = NSImageView()
            view.image = OpenCodeLogo.image
            view.imageScaling = .scaleProportionallyUpOrDown
            view.widthAnchor.constraint(equalToConstant: 30).isActive = true
            item.view = view
            item.customizationLabel = "OpenCode"
            return item
        default:
            return nil
        }
    }

    private func makeUsageItem(
        identifier: NSTouchBarItem.Identifier,
        title: String,
        customizationKey: String = "quota_customization"
    ) -> (item: NSCustomTouchBarItem, label: NSTextField, progress: TouchBarProgressView) {
        let item = NSCustomTouchBarItem(identifier: identifier)
        let label = NSTextField(labelWithString: "\(title) –")
        label.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        label.alignment = .center

        let progress = TouchBarProgressView()
        progress.widthAnchor.constraint(equalToConstant: 110).isActive = true
        progress.heightAnchor.constraint(equalToConstant: 5).isActive = true

        let stack = NSStackView(views: [label, progress])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 3
        stack.edgeInsets = NSEdgeInsets(top: 2, left: 4, bottom: 2, right: 4)
        stack.widthAnchor.constraint(equalToConstant: 120).isActive = true

        item.view = stack
        item.customizationLabel = store.tr(customizationKey, title)
        return (item, label, progress)
    }

    private func updateItems() {
        updateDefaultItemIdentifiers()

        updateUsage(
            window: store.snapshot?.primary,
            prefix: "5h",
            label: fiveHourLabel,
            progress: fiveHourProgress
        )
        updateUsage(
            window: store.snapshot?.secondary,
            prefix: store.tr("weekly_prefix"),
            label: weeklyLabel,
            progress: weeklyProgress
        )
        updateUsage(
            window: store.openCodeGoSnapshot?.rolling,
            prefix: "5h",
            label: goRollingLabel,
            progress: goRollingProgress
        )
        updateUsage(
            window: store.openCodeGoSnapshot?.weekly,
            prefix: store.tr("weekly_prefix"),
            label: goWeeklyLabel,
            progress: goWeeklyProgress
        )
        updateUsage(
            window: store.openCodeGoSnapshot?.monthly,
            prefix: store.tr("monthly_prefix"),
            label: goMonthlyLabel,
            progress: goMonthlyProgress
        )

        refreshButton?.isEnabled = !store.isLoading && !store.openCodeGoIsLoading
    }

    private func reloadPetPackage() {
        guard let petID = store.petID,
              CodexPetPackage.isValidPetID(petID),
              let petsFolderURL = store.petsFolderURL else {
            petPackage = nil
            petView = nil
            updateItems()
            return
        }
        petPackage = try? CodexPetPackage.load(folder: petsFolderURL.appendingPathComponent(petID))
        petView = nil
        if petPackage != nil {
            // Force the bar to rebuild items so a pet change applies even
            // when the same id resolves to new content (e.g. a folder switch
            // to a same-named pet).
            touchBar.defaultItemIdentifiers = []
        }
        updateItems()
    }

    private func updateDefaultItemIdentifiers() {
        let petIdentifiers: [NSTouchBarItem.Identifier] = petPackage != nil
            ? [.pet, .fixedSpaceSmall]
            : []
        let goIdentifiers: [NSTouchBarItem.Identifier] = store.openCodeGoConfigured
            ? [
                .openCodeLogo,
                .fixedSpaceSmall,
                .goRollingUsage,
                .fixedSpaceSmall,
                .goWeeklyUsage,
                .fixedSpaceSmall,
                .goMonthlyUsage
            ]
            : []
        let codexIdentifiers: [NSTouchBarItem.Identifier] = store.codexConfigured
            ? [
                .fiveHourUsage,
                .fixedSpaceSmall,
                .weeklyUsage
            ]
            : []
        // Pet sits after the usage groups, right of the monthly bar.
        var identifiers = codexIdentifiers + goIdentifiers + petIdentifiers
        if identifiers.isEmpty {
            identifiers = [
                .openCodeLogo,
                .fixedSpaceSmall,
                .noUsageSource
            ]
        }
        identifiers += [.flexibleSpace, .refreshUsage]
        guard touchBar.defaultItemIdentifiers != identifiers else { return }
        touchBar.defaultItemIdentifiers = identifiers
    }

    private func updateUsage(
        window: RateWindow?,
        prefix: String,
        label: NSTextField?,
        progress: TouchBarProgressView?
    ) {
        guard let window else {
            label?.stringValue = "\(prefix) –"
            label?.textColor = .secondaryLabelColor
            progress?.value = 0
            return
        }
        let remaining = window.remainingPercent
        let color: NSColor
        if remaining <= 10 {
            color = .systemRed
        } else if remaining <= 25 {
            color = .systemOrange
        } else {
            color = .controlAccentColor
        }
        label?.stringValue = "\(prefix) \(remaining)%"
        label?.textColor = color
        progress?.value = Double(remaining)
        progress?.tintColor = color
    }

    private func applyPresentationMode(reassert: Bool = false) {
        let mode = store.touchBarMode
        // Public-API path: still shows the bar while this app itself is active,
        // and is the only path when the system-modal SPI is unavailable.
        NSApp.touchBar = mode == .disabled ? nil : touchBar
        let shouldShow = mode != .disabled &&
            (mode == .always || codexIsFrontmost) &&
            TouchBarSystemModal.isAvailable

        if shouldShow {
            if !systemModalVisible {
                systemModalVisible = TouchBarSystemModal.present(touchBar)
            } else if reassert {
                // macOS can reclaim the modal bar during activation changes;
                // re-presenting is cheap and idempotent.
                TouchBarSystemModal.present(touchBar)
            }
        } else if systemModalVisible {
            if mode == .disabled {
                TouchBarSystemModal.dismiss(touchBar)
            } else {
                TouchBarSystemModal.minimize(touchBar)
            }
            systemModalVisible = false
        }
    }

    func refreshPresentation() {
        codexIsFrontmost = NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.openai.codex"
        applyPresentationMode(reassert: true)
    }

    func shutDown() {
        if systemModalVisible {
            TouchBarSystemModal.dismiss(touchBar)
            systemModalVisible = false
        }
        NSApp.touchBar = nil
    }

    @objc private func refreshUsage() {
        store.refresh()
    }
}

struct SettingsView: View {
    @ObservedObject var store: UsageStore
    @State private var apiKeyInput = ""
    @State private var keyError: String?

    private let icons = [
        ("gauge.with.dots.needle.67percent", "icon_gauge"),
        ("gauge.medium", "icon_simple_gauge"),
        ("speedometer", "icon_speedometer"),
        ("chart.bar.fill", "icon_bar_chart"),
        ("chart.line.uptrend.xyaxis", "icon_trend"),
        ("percent", "icon_percent"),
        ("bolt.circle.fill", "icon_bolt"),
        ("flame.fill", "icon_flame"),
        ("sparkles", "icon_sparkles"),
        ("terminal.fill", "icon_terminal"),
        ("command.circle.fill", "icon_command"),
        ("cpu", "icon_cpu"),
        ("memorychip", "icon_chip"),
        ("timer", "icon_timer"),
        ("clock.arrow.circlepath", "icon_refresh_clock"),
        ("waveform.path.ecg", "icon_waveform"),
        ("none", "icon_hidden")
    ]

    var body: some View {
        Form {
            Section(store.tr("section_language")) {
                Picker(store.tr("language"), selection: $store.appLanguage) {
                    ForEach(AppLanguage.allCases) { language in
                        Text(language == .system ? store.tr("system_default") : language.nativeName)
                            .tag(language)
                    }
                }
            }

            Section(store.tr("section_menu_bar")) {
                Picker(store.tr("icon"), selection: $store.menuIconName) {
                    ForEach(icons, id: \.0) { icon in
                        Label(store.tr(icon.1), systemImage: icon.0 == "none" ? "eye.slash" : icon.0)
                            .tag(icon.0)
                    }
                }

                settingSlider(
                    title: store.tr("icon_size"),
                    value: $store.menuIconSize,
                    range: 9...18,
                    suffix: "\(Int(store.menuIconSize)) pt"
                )

                settingSlider(
                    title: store.tr("text_size"),
                    value: $store.menuTextSize,
                    range: 8...18,
                    suffix: "\(Int(store.menuTextSize)) pt"
                )
            }

            Section(store.tr("section_general")) {
                Toggle(store.tr("launch_at_login"), isOn: Binding(
                    get: { store.launchAtLogin },
                    set: { store.setLaunchAtLogin($0) }
                ))
            }

            Section("Touch Bar") {
                Picker(store.tr("touch_bar_mode"), selection: $store.touchBarMode) {
                    ForEach(TouchBarMode.allCases) { mode in
                        Text(store.tr(mode.localizationKey)).tag(mode)
                    }
                }

                Text(TouchBarSystemModal.isAvailable
                     ? store.tr("touch_bar_description")
                     : store.tr("touch_bar_unavailable"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section(store.tr("section_pet")) {
                Picker(store.tr("pet"), selection: $store.petID) {
                    Text(store.tr("pet_none")).tag(String?.none)
                    ForEach(store.availablePets) { pet in
                        Text(pet.displayName).tag(Optional(pet.id))
                    }
                }

                Text(store.availablePets.isEmpty
                     ? store.tr("pet_no_pets")
                     : store.tr("pet_folder_label", store.petsFolderDisplay))
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if let selectedID = store.petID,
                   let summary = store.availablePets.first(where: { $0.id == selectedID }),
                   let warningKey = summary.warningKey {
                    Text(store.tr(warningKey))
                        .font(.caption)
                        .foregroundStyle(.orange)
                }

                if store.petID != nil,
                   !store.availablePets.contains(where: { $0.id == store.petID }) {
                    Text(store.tr("pet_selected_missing"))
                        .font(.caption)
                        .foregroundStyle(.orange)
                }

                settingSlider(
                    title: store.tr("pet_min_interval"),
                    value: $store.petMinInterval,
                    range: 5...300,
                    step: 5,
                    suffix: "\(Int(store.petMinInterval)) s"
                )

                settingSlider(
                    title: store.tr("pet_max_interval"),
                    value: $store.petMaxInterval,
                    range: 5...300,
                    step: 5,
                    suffix: "\(Int(store.petMaxInterval)) s"
                )

                HStack {
                    Button(store.tr("pet_refresh")) { store.refreshAvailablePets() }
                    Button(store.tr("pet_choose_folder")) { choosePetFolder() }
                    if store.petsFolderOverride != nil {
                        Button(store.tr("pet_reset_folder")) {
                            store.petsFolderOverride = nil
                            store.refreshAvailablePets()
                        }
                    }
                }

                Button(store.tr("pet_open_gallery")) {
                    NSWorkspace.shared.open(petGalleryURL)
                }
            }

            Section(store.tr("go_title")) {
                SecureField(store.tr("opencode_go_key_placeholder"), text: $apiKeyInput)
                HStack {
                    Button(store.tr("opencode_go_key_save")) {
                        keyError = store.saveOpenCodeGoAPIKey(apiKeyInput)
                        if keyError == nil {
                            apiKeyInput = ""
                        }
                    }
                    .disabled(apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                    if store.openCodeGoKeyStored {
                        Button(store.tr("opencode_go_key_remove"), role: .destructive) {
                            store.removeOpenCodeGoAPIKey()
                            keyError = nil
                        }
                    }
                }

                Text(store.openCodeGoKeyStored
                     ? store.tr("opencode_go_key_stored")
                     : store.tr("opencode_go_key_not_stored"))
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if let keyError {
                    Text(keyError)
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
        }
        .formStyle(.grouped)
        .padding(4)
        .environment(\.locale, store.appLanguage.locale)
        .frame(width: 440, height: 720)
    }

    private func choosePetFolder() {
        let panel = NSOpenPanel()
        panel.title = store.tr("pet_choose_folder")
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = store.petsFolderURL
        guard panel.runModal() == .OK, let url = panel.url else { return }
        store.petsFolderOverride = url.path
        store.refreshAvailablePets()
    }

    @ViewBuilder
    private func settingSlider(
        title: String,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        step: Double = 1,
        suffix: String
    ) -> some View {
        HStack {
            Text(title)
            Slider(value: value, in: range, step: step)
            Text(suffix)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 48, alignment: .trailing)
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, NSWindowDelegate {
    let store = UsageStore()

    private var statusItem: NSStatusItem?
    private var usageMenu: NSMenu?
    private var usageHostingView: NSHostingView<UsagePopover>?
    private var usageScrollView: NSScrollView?
    private var settingsWindow: NSWindow?
    private var touchBarController: UsageTouchBarController?
    private var showSettingsAfterMenuCloses = false
    private var subscriptions = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        touchBarController = UsageTouchBarController(store: store)

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem = item

        if let button = item.button {
            button.imagePosition = .imageLeading
            button.imageHugsTitle = true
            button.alignment = .center
        }

        let menu = makeUsageMenu()
        usageMenu = menu
        item.menu = menu

        Publishers.CombineLatest3(store.$snapshot, store.$isLoading, store.$errorMessage)
            .receive(on: RunLoop.main)
            .sink { [weak self] _, _, _ in
                self?.updateStatusItemAndMenuLayout()
            }
            .store(in: &subscriptions)

        Publishers.CombineLatest3(
            store.$openCodeGoSnapshot,
            store.$openCodeGoIsLoading,
            store.$openCodeGoErrorMessage
        )
        .receive(on: RunLoop.main)
        .sink { [weak self] _, _, _ in
            self?.updateStatusItemAndMenuLayout()
        }
        .store(in: &subscriptions)

        Publishers.CombineLatest3(store.$menuIconName, store.$menuIconSize, store.$menuTextSize)
            .receive(on: RunLoop.main)
            .sink { [weak self] _, _, _ in self?.updateStatusItem() }
            .store(in: &subscriptions)

        store.$appLanguage
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self else { return }
                self.settingsWindow?.title = self.store.tr("settings_window_title")
                self.updateMenuLayoutSoon()
            }
            .store(in: &subscriptions)

        updateStatusItem()
    }

    func applicationWillTerminate(_ notification: Notification) {
        touchBarController?.shutDown()
    }

    private func updateStatusItem() {
        guard let button = statusItem?.button else { return }

        let pointSize = CGFloat(store.menuTextSize)
        let textFont = NSFont.monospacedDigitSystemFont(ofSize: pointSize, weight: .medium)
        let baselineOffset = -max(0.5, round(pointSize * 0.08 * 2) / 2)
        button.font = textFont
        button.attributedTitle = NSAttributedString(
            string: store.menuTitle,
            attributes: [
                .font: textFont,
                .foregroundColor: NSColor.labelColor,
                .baselineOffset: baselineOffset
            ]
        )

        if store.menuIconName == "none" {
            button.image = nil
        } else {
            let symbolConfiguration = NSImage.SymbolConfiguration(pointSize: CGFloat(store.menuIconSize), weight: .medium)
            let image = NSImage(systemSymbolName: store.menuIconName, accessibilityDescription: "Codex Usage")?
                .withSymbolConfiguration(symbolConfiguration)
            image?.isTemplate = true
            button.image = image
        }
        button.imageScaling = .scaleProportionallyDown
    }

    private func updateStatusItemAndMenuLayout() {
        updateStatusItem()
        updateMenuLayoutSoon()
    }

    private func updateMenuLayoutSoon() {
        DispatchQueue.main.async { [weak self] in
            self?.updateMenuLayout()
        }
    }

    private func updateMenuLayout() {
        guard let hostingView = usageHostingView, let scrollView = usageScrollView else { return }
        hostingView.layoutSubtreeIfNeeded()
        let contentHeight = max(1, hostingView.fittingSize.height)
        let screenHeight = NSScreen.main?.visibleFrame.height ?? 600
        let visibleHeight = max(240, screenHeight - 80)
        let menuHeight = min(contentHeight, visibleHeight)
        hostingView.frame = NSRect(x: 0, y: 0, width: 330, height: contentHeight)
        scrollView.frame = NSRect(x: 0, y: 0, width: 330, height: menuHeight)
        scrollView.hasVerticalScroller = contentHeight > menuHeight
    }

    private func makeUsageMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.minimumWidth = 330
        menu.delegate = self

        let contentItem = NSMenuItem()
        let hostingView = NSHostingView(rootView: UsagePopover(
            store: store,
            onShowSettings: { [weak self] in self?.requestSettings() }
        ))
        hostingView.wantsLayer = true
        hostingView.layer?.backgroundColor = NSColor.clear.cgColor
        usageHostingView = hostingView

        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.scrollerStyle = .overlay
        scrollView.autohidesScrollers = true
        scrollView.documentView = hostingView
        usageScrollView = scrollView
        contentItem.view = scrollView
        menu.addItem(contentItem)
        updateMenuLayout()
        return menu
    }

    private func requestSettings() {
        guard usageMenu != nil else {
            presentSettingsWindow()
            return
        }
        showSettingsAfterMenuCloses = true
        usageMenu?.cancelTrackingWithoutAnimation()
    }

    func menuDidClose(_ menu: NSMenu) {
        guard showSettingsAfterMenuCloses else { return }
        showSettingsAfterMenuCloses = false
        DispatchQueue.main.async { [weak self] in self?.presentSettingsWindow() }
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, window === settingsWindow else { return }
        DispatchQueue.main.async { [weak self] in
            self?.touchBarController?.refreshPresentation()
        }
    }

    private func presentSettingsWindow() {
        if settingsWindow == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 440, height: 720),
                styleMask: [.titled, .closable],
                backing: .buffered,
                defer: false
            )
            window.title = store.tr("settings_window_title")
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.center()
            window.contentView = NSHostingView(rootView: SettingsView(store: store))
            settingsWindow = window
        }

        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.center()
        settingsWindow?.makeKeyAndOrderFront(nil)
    }
}

@main
struct OpenCodeUsageTouchBarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    init() {
        if CommandLine.arguments.contains("--self-test") {
            do {
                let snapshot = try CodexUsageClient.fetch()
                let primary = snapshot.primary?.remainingPercent.description ?? "n/a"
                let secondary = snapshot.secondary?.remainingPercent.description ?? "n/a"
                print("OK 5h=\(primary)% weekly=\(secondary)% resets=\(snapshot.resetCredits)")
                exit(EXIT_SUCCESS)
            } catch {
                fputs("ERROR \(error.localizedDescription)\n", stderr)
                exit(EXIT_FAILURE)
            }
        }
        if CommandLine.arguments.contains("--self-test-opencode-go") {
            let semaphore = DispatchSemaphore(value: 0)
            Task.detached {
                do {
                    let snapshot = try await OpenCodeGoUsageClient.fetch()
                    let rolling = snapshot.rolling?.remainingPercent.description ?? "n/a"
                    let weekly = snapshot.weekly?.remainingPercent.description ?? "n/a"
                    let monthly = snapshot.monthly?.remainingPercent.description ?? "n/a"
                    print("OK go 5h=\(rolling)% weekly=\(weekly)% monthly=\(monthly)%")
                    exit(EXIT_SUCCESS)
                } catch {
                    fputs("ERROR \(error.localizedDescription)\n", stderr)
                    exit(EXIT_FAILURE)
                }
            }
            semaphore.wait()
        }
    }

    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}

enum OpenCodeLogo {
    /// OpenCode mark with transparent background (source: seeklogo.com, 66/665474).
    /// Rendered as a template image so AppKit tints the glyph for the dark
    /// Touch Bar context without shipping a colour variant.
    static var image: NSImage? {
        guard let data = Data(base64Encoded: pngBase64), let image = NSImage(data: data) else {
            return nil
        }
        image.isTemplate = true
        image.size = NSSize(width: 22, height: 27)
        return image
    }

    private static let pngBase64 = "iVBORw0KGgoAAAANSUhEUgAAALAAAADYCAYAAABLEGlpAAAC3ElEQVR42u3SwQmCcBjGYScJWkLoIEU3qTkawtrCkzZJ2gzaDtaxGarjX28pgdDzwu8b4OOJTllWhC0Xi5c014ZeI4AFsASwNALw8XPCPElzbugVYAEsASwBLIA9SQBLAEsAC2AJYAlgAQywAJYAlgAWwAALYAlgCWABLAEsASwBLIAlgCWABTDAAlgCWAJYAAMsgCWAJYAFsATwL9puNs+wXZo+NL7hPwEGGGCAAQYYYAE8v9qm2YdFNmm3tt2HAQwwwAADDDDABjDAAAMMMMAAAwwwwAYwwAADDDDAAAMMMMAAAwwwwAADDDDABjDAAAMMMMAAAwwwwAYwwAADDDDAAAMMMMAGMMAAAwwwwAADDDDAAAMMMMAAAwwwwAYwwAADDDDAAAMMMMAGMMAAAwwwwAADDDDABjDAAAMMMMD/B7i6XPKwe9cdNL66qvIwgAEGGGCAAQZYAM+vsih6XetaEzqXZS+AAQYYYIABBlgAAwwwwAADDDDAAAMsgAEGGGCAAQYYYIABBhhggAEGGGCAARbAAAMMMMAAAwwwwAALYIABBhhggAEGGGCABTDAAAMMMMAAAwwwwAADDDDAAAMMMMACGGCAAQYYYIABBhhgAQwwwAADDDDAAAMMsAAGGGCAAQYYYAgBBhhggAEGGGCAAQZYAAMMMMAAAwwwwAADLIABBhhggAEGGGCAARbAAAMMMMAAAyyAAQYYYIABBhhggAEWwAADDDDAAAMMMMAAC2CAAQYYYIABBhhggAUwwAADDDDAAAtggAEGGGCAAQYYYIAFMMAAAwwwwAADDDDAAhhggAEGGGCAAQYYYAEMMMAAf9Mqjnutk0QTGv4TYIABBhhggAEWwBLAEsASwAJYAlgCWAADLIAlgCWABTDAAlgCWAJYAEsASwBLAAtgCWAJYAEMsACWAJYAFsCeJIAlgCWABbAEsASwAAZYAEsASwALYIAFsASw9CXgN3zVXSulPvT5AAAAAElFTkSuQmCC"
}
