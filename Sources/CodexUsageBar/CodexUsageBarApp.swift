import AppKit
import Combine
import Darwin
import ObjectiveC
import Security
import ServiceManagement
import SwiftUI

private let usageDashboardURL = URL(string: "https://chatgpt.com/codex/settings/usage")!

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
        process.environment = environment

        let input = Pipe()
        let output = Pipe()
        let errors = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors

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
                    "name": "codex-usage-bar",
                    "title": "Codex Usage Bar",
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

        var responseData = Data()
        while process.isRunning {
            let chunk = output.fileHandleForReading.availableData
            if chunk.isEmpty { break }
            responseData.append(chunk)
            if containsResponse(id: 2, in: responseData) {
                process.terminate()
                break
            }
        }
        try? input.fileHandleForWriting.close()
        if process.isRunning { process.terminate() }
        process.waitUntilExit()
        timeout.cancel()

        if timedOut.value && responseData.isEmpty {
            throw UsageClientError.timedOut
        }

        return try parseResponse(responseData)
    }

    private static func containsResponse(id: Int, in data: Data) -> Bool {
        guard let text = String(data: data, encoding: .utf8) else { return false }
        return text.split(whereSeparator: \.isNewline).contains { line in
            guard let lineData = String(line).data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] else {
                return false
            }
            return (json["id"] as? NSNumber)?.intValue == id
        }
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

        var request = URLRequest(url: usageURL)
        request.httpMethod = "GET"
        request.timeoutInterval = 15
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let session = URLSession(configuration: .ephemeral, delegate: RedirectGuard(), delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }

        do {
            let (data, response) = try await withThrowingTaskGroup(of: (Data, URLResponse).self) { group in
                group.addTask {
                    try await session.data(for: request)
                }
                group.addTask {
                    try await Task.sleep(nanoseconds: 20_000_000_000)
                    throw OpenCodeGoUsageClientError.timedOut
                }
                guard let first = try await group.next() else {
                    throw OpenCodeGoUsageClientError.timedOut
                }
                group.cancelAll()
                return first
            }
            guard let http = response as? HTTPURLResponse else {
                throw OpenCodeGoUsageClientError.invalidResponse
            }
            switch http.statusCode {
            case 200:
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
    private static let service = "com.local.codexusagebar"
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
    @Published var touchBarEnabled: Bool {
        didSet { UserDefaults.standard.set(touchBarEnabled, forKey: "touchBarEnabled") }
    }
    @Published var touchBarWhenCodexActive: Bool {
        didSet { UserDefaults.standard.set(touchBarWhenCodexActive, forKey: "touchBarWhenCodexActive") }
    }
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
    private var lastUsageError: UsageClientError?
    private var lastOpenCodeGoError: OpenCodeGoUsageClientError?
    private var openCodeGoFetchGeneration = 0

    init() {
        let defaults = UserDefaults.standard
        menuIconName = defaults.string(forKey: "menuIconName") ?? "gauge.with.dots.needle.67percent"
        menuIconSize = defaults.object(forKey: "menuIconSize") as? Double ?? 12
        menuTextSize = defaults.object(forKey: "menuTextSize") as? Double ?? 12
        touchBarEnabled = defaults.object(forKey: "touchBarEnabled") as? Bool ?? true
        touchBarWhenCodexActive = defaults.object(forKey: "touchBarWhenCodexActive") as? Bool ?? true
        appLanguage = defaults.string(forKey: "appLanguage").flatMap(AppLanguage.init(rawValue:)) ?? .system
        openCodeGoKeyStored = KeychainStore.loadOpenCodeGoAPIKey() != nil
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
        guard !isLoading else { return }
        isLoading = true
        errorMessage = nil
        lastUsageError = nil

        Task {
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

        Task {
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
        openCodeGoFetchGeneration += 1
        openCodeGoIsLoading = false
        refreshOpenCodeGo()
        return nil
    }

    func removeOpenCodeGoAPIKey() {
        KeychainStore.deleteOpenCodeGoAPIKey()
        OpenCodeGoUsageClient.cacheAPIKey(nil)
        openCodeGoFetchGeneration += 1
        openCodeGoIsLoading = false
        openCodeGoKeyStored = false
        lastOpenCodeGoError = nil
        openCodeGoSnapshot = nil
        openCodeGoErrorMessage = nil
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
    static let systemTrayIdentifier = NSTouchBarItem.Identifier("com.local.codexusagebar.touchbar")

    private static let presentSelector = NSSelectorFromString(
        "presentSystemModalTouchBar:placement:systemTrayItemIdentifier:"
    )
    private static let dismissSelector = NSSelectorFromString("dismissSystemModalTouchBar:")
    private static let minimizeSelector = NSSelectorFromString("minimizeSystemModalTouchBar:")
    private static let addSystemTrayItemSelector = NSSelectorFromString("addSystemTrayItem:")
    private static let removeSystemTrayItemSelector = NSSelectorFromString("removeSystemTrayItem:")

    private typealias SetControlStripPresence = @convention(c) (CFString, Bool) -> Void

    nonisolated(unsafe) private static let dfrHandle: UnsafeMutableRawPointer? = dlopen(
        "/System/Library/PrivateFrameworks/DFRFoundation.framework/DFRFoundation",
        RTLD_NOW
    )
    private static let setControlStripPresence: SetControlStripPresence? = {
        guard let dfrHandle,
              let pointer = dlsym(dfrHandle, "DFRElementSetControlStripPresenceForIdentifier") else {
            return nil
        }
        return unsafeBitCast(pointer, to: SetControlStripPresence.self)
    }()

    static var isAvailable: Bool {
        class_getClassMethod(NSTouchBar.self, presentSelector) != nil &&
            class_getClassMethod(NSTouchBar.self, dismissSelector) != nil &&
            class_getClassMethod(NSTouchBarItem.self, addSystemTrayItemSelector) != nil &&
            class_getClassMethod(NSTouchBarItem.self, removeSystemTrayItemSelector) != nil &&
            setControlStripPresence != nil
    }

    static func addSystemTrayItem(_ item: NSTouchBarItem) -> Bool {
        guard let method = class_getClassMethod(NSTouchBarItem.self, addSystemTrayItemSelector) else {
            return false
        }
        typealias Function = @convention(c) (AnyObject, Selector, NSTouchBarItem) -> Void
        let function = unsafeBitCast(method_getImplementation(method), to: Function.self)
        function(NSTouchBarItem.self, addSystemTrayItemSelector, item)
        setControlStripPresence?(systemTrayIdentifier.rawValue as CFString, true)
        return true
    }

    static func removeSystemTrayItem(_ item: NSTouchBarItem) {
        setControlStripPresence?(systemTrayIdentifier.rawValue as CFString, false)
        guard let method = class_getClassMethod(NSTouchBarItem.self, removeSystemTrayItemSelector) else {
            return
        }
        typealias Function = @convention(c) (AnyObject, Selector, NSTouchBarItem) -> Void
        let function = unsafeBitCast(method_getImplementation(method), to: Function.self)
        function(NSTouchBarItem.self, removeSystemTrayItemSelector, item)
    }

    static func present(_ touchBar: NSTouchBar) -> Bool {
        guard let method = class_getClassMethod(NSTouchBar.self, presentSelector) else {
            return false
        }
        typealias Function = @convention(c) (
            AnyObject,
            Selector,
            NSTouchBar,
            Int,
            NSString
        ) -> Void
        let function = unsafeBitCast(method_getImplementation(method), to: Function.self)
        function(
            NSTouchBar.self,
            presentSelector,
            touchBar,
            1,
            systemTrayIdentifier.rawValue as NSString
        )
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
    static let fiveHourUsage = NSTouchBarItem.Identifier("com.local.codexusagebar.five-hour")
    static let weeklyUsage = NSTouchBarItem.Identifier("com.local.codexusagebar.weekly")
    static let resetTimes = NSTouchBarItem.Identifier("com.local.codexusagebar.reset-times")
    static let refreshUsage = NSTouchBarItem.Identifier("com.local.codexusagebar.refresh")
    static let goRollingUsage = NSTouchBarItem.Identifier("com.local.codexusagebar.go-rolling")
    static let goWeeklyUsage = NSTouchBarItem.Identifier("com.local.codexusagebar.go-weekly")
    static let goMonthlyUsage = NSTouchBarItem.Identifier("com.local.codexusagebar.go-monthly")
    static let goResetTimes = NSTouchBarItem.Identifier("com.local.codexusagebar.go-reset-times")
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

@MainActor
final class UsageTouchBarController: NSObject, NSTouchBarDelegate {
    let touchBar = NSTouchBar()

    private let store: UsageStore
    private var fiveHourLabel: NSTextField?
    private var fiveHourProgress: TouchBarProgressView?
    private var weeklyLabel: NSTextField?
    private var weeklyProgress: TouchBarProgressView?
    private var resetLabel: NSTextField?
    private var refreshButton: NSButton?
    private var systemTrayItem: NSCustomTouchBarItem?
    private var goRollingLabel: NSTextField?
    private var goRollingProgress: TouchBarProgressView?
    private var goWeeklyLabel: NSTextField?
    private var goWeeklyProgress: TouchBarProgressView?
    private var goMonthlyLabel: NSTextField?
    private var goMonthlyProgress: TouchBarProgressView?
    private var goResetLabel: NSTextField?
    private var subscriptions = Set<AnyCancellable>()
    private var systemModalVisible = false
    private var codexIsFrontmost = false

    init(store: UsageStore) {
        self.store = store
        super.init()

        touchBar.delegate = self
        touchBar.customizationIdentifier = NSTouchBar.CustomizationIdentifier(
            "com.local.codexusagebar.usage"
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

        Publishers.CombineLatest(store.$touchBarEnabled, store.$touchBarWhenCodexActive)
            .receive(on: RunLoop.main)
            .sink { [weak self] _, _ in self?.applyPresentationMode() }
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
        updateItems()
        applyPresentationMode()
    }

    deinit {
        if systemModalVisible {
            TouchBarSystemModal.dismiss(touchBar)
        }
        if let systemTrayItem {
            TouchBarSystemModal.removeSystemTrayItem(systemTrayItem)
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
        case .resetTimes:
            let item = NSCustomTouchBarItem(identifier: identifier)
            let label = NSTextField(labelWithString: store.tr("loading_reset"))
            label.font = .systemFont(ofSize: 11, weight: .regular)
            label.textColor = .secondaryLabelColor
            label.alignment = .center
            label.lineBreakMode = .byTruncatingMiddle
            label.widthAnchor.constraint(equalToConstant: 160).isActive = true
            item.view = label
            item.customizationLabel = store.tr("reset_customization")
            resetLabel = label
            updateItems()
            return item
        case .refreshUsage:
            let item = NSCustomTouchBarItem(identifier: identifier)
            let button = NSButton(
                image: NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: store.tr("refresh_usage"))!,
                target: self,
                action: #selector(refreshUsage)
            )
            button.bezelColor = .controlAccentColor
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
        case .goResetTimes:
            let item = NSCustomTouchBarItem(identifier: identifier)
            let label = NSTextField(labelWithString: store.tr("loading_reset"))
            label.font = .systemFont(ofSize: 11, weight: .regular)
            label.textColor = .secondaryLabelColor
            label.alignment = .center
            label.lineBreakMode = .byTruncatingMiddle
            label.widthAnchor.constraint(equalToConstant: 170).isActive = true
            item.view = label
            item.customizationLabel = store.tr("go_reset_customization")
            goResetLabel = label
            updateItems()
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

        if let snapshot = store.snapshot {
            let primaryReset = resetText(snapshot.primary?.resetsAt, short: true)
            let weeklyReset = resetText(snapshot.secondary?.resetsAt, short: false)
            resetLabel?.stringValue = store.tr("touch_bar_reset", primaryReset, weeklyReset)
        } else {
            resetLabel?.stringValue = store.isLoading ? store.tr("loading_usage") : store.tr("usage_unavailable")
        }

        if let go = store.openCodeGoSnapshot {
            let rollingReset = resetText(go.rolling?.resetsAt, short: true)
            let weeklyReset = resetText(go.weekly?.resetsAt, short: false)
            let monthlyReset = resetText(go.monthly?.resetsAt, short: false)
            goResetLabel?.stringValue = store.tr("go_touch_bar_reset", rollingReset, weeklyReset, monthlyReset)
        } else {
            goResetLabel?.stringValue = store.openCodeGoIsLoading ? store.tr("loading_usage") : store.tr("usage_unavailable")
        }
        refreshButton?.isEnabled = !store.isLoading && !store.openCodeGoIsLoading
    }

    private func updateDefaultItemIdentifiers() {
        let goIdentifiers: [NSTouchBarItem.Identifier] = store.openCodeGoConfigured
            ? [
                .goRollingUsage,
                .fixedSpaceSmall,
                .goWeeklyUsage,
                .fixedSpaceSmall,
                .goMonthlyUsage,
                .fixedSpaceSmall,
                .goResetTimes
            ]
            : []
        let identifiers: [NSTouchBarItem.Identifier] = [
            .fiveHourUsage,
            .fixedSpaceSmall,
            .weeklyUsage,
            .fixedSpaceSmall,
            .resetTimes
        ] + goIdentifiers + [.flexibleSpace, .refreshUsage]
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

    private func resetText(_ date: Date?, short: Bool) -> String {
        guard let date else { return "–" }
        return store.formatDate(date, includeDate: !short)
    }

    private func applyPresentationMode(reassert: Bool = false) {
        NSApp.touchBar = store.touchBarEnabled ? touchBar : nil
        let canUseSystemModal = store.touchBarEnabled &&
            store.touchBarWhenCodexActive &&
            TouchBarSystemModal.isAvailable

        if canUseSystemModal {
            installSystemTrayItem()
        } else {
            if systemModalVisible {
                TouchBarSystemModal.dismiss(touchBar)
                systemModalVisible = false
            }
            removeSystemTrayItem()
        }

        let shouldShowSystemModal = canUseSystemModal && codexIsFrontmost

        if reassert && shouldShowSystemModal && systemModalVisible {
            TouchBarSystemModal.dismiss(touchBar)
            systemModalVisible = false
        }
        if shouldShowSystemModal && !systemModalVisible {
            systemModalVisible = TouchBarSystemModal.present(touchBar)
        } else if !shouldShowSystemModal && systemModalVisible {
            TouchBarSystemModal.minimize(touchBar)
            systemModalVisible = false
        }
    }

    func shutDown() {
        if systemModalVisible {
            TouchBarSystemModal.dismiss(touchBar)
            systemModalVisible = false
        }
        removeSystemTrayItem()
        NSApp.touchBar = nil
    }

    private func installSystemTrayItem() {
        guard systemTrayItem == nil else { return }
        let item = NSCustomTouchBarItem(identifier: TouchBarSystemModal.systemTrayIdentifier)
        let button = NSButton(
            image: NSImage(
                systemSymbolName: "gauge.with.dots.needle.67percent",
                accessibilityDescription: store.tr("settings")
            ) ?? NSImage(),
            target: self,
            action: #selector(presentFromSystemTray)
        )
        button.bezelStyle = .texturedRounded
        button.setAccessibilityLabel(store.tr("settings"))
        item.view = button
        guard TouchBarSystemModal.addSystemTrayItem(item) else { return }
        systemTrayItem = item
    }

    private func removeSystemTrayItem() {
        guard let systemTrayItem else { return }
        TouchBarSystemModal.removeSystemTrayItem(systemTrayItem)
        self.systemTrayItem = nil
    }

    @objc private func presentFromSystemTray() {
        guard store.touchBarEnabled, TouchBarSystemModal.isAvailable else { return }
        if systemModalVisible {
            TouchBarSystemModal.minimize(touchBar)
            systemModalVisible = false
        } else {
            systemModalVisible = TouchBarSystemModal.present(touchBar)
        }
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
                Toggle(store.tr("show_touch_bar"), isOn: $store.touchBarEnabled)
                Toggle(store.tr("auto_touch_bar"), isOn: $store.touchBarWhenCodexActive)
                    .disabled(!store.touchBarEnabled || !TouchBarSystemModal.isAvailable)

                Text(TouchBarSystemModal.isAvailable
                     ? store.tr("touch_bar_description")
                     : store.tr("touch_bar_unavailable"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
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
        .frame(width: 440, height: 560)
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
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
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

    private func presentSettingsWindow() {
        if settingsWindow == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 440, height: 560),
                styleMask: [.titled, .closable],
                backing: .buffered,
                defer: false
            )
            window.title = store.tr("settings_window_title")
            window.isReleasedWhenClosed = false
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
struct CodexUsageBarApp: App {
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
