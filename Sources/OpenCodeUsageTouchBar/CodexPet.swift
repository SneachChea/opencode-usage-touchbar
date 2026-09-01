import CoreGraphics
import Foundation
import ImageIO

/// The nine standard Codex pet animation rows (atlas rows 0-8, shared by V1
/// and V2). V2 adds two look-direction rows that the Touch Bar ignores.
enum PetAction: Int, CaseIterable {
    case idle = 0
    case runningRight = 1
    case runningLeft = 2
    case waving = 3
    case jumping = 4
    case failed = 5
    case waiting = 6
    case running = 7
    case review = 8
}

enum PetAtlas {
    static let columns = 8
    static let cellWidth = 192
    static let cellHeight = 208
    static let v1Height = 1872
    static let v2Height = 2288

    /// Canonical frame count per animation row (OpenAI hatch-pet contract).
    /// Cells after the last used frame in a row are fully transparent padding
    /// and are trimmed. Never assume every row has 8 frames.
    static let frameCounts: [PetAction: Int] = [
        .idle: 6,
        .runningRight: 8,
        .runningLeft: 8,
        .waving: 4,
        .jumping: 5,
        .failed: 8,
        .waiting: 6,
        .running: 6,
        .review: 6
    ]

    /// Per-frame durations in seconds, matching the hatch-pet timing table.
    static let frameDurations: [PetAction: [TimeInterval]] = [
        .idle: [0.28, 0.11, 0.11, 0.14, 0.14, 0.32],
        .runningRight: [0.12, 0.12, 0.12, 0.12, 0.12, 0.12, 0.12, 0.22],
        .runningLeft: [0.12, 0.12, 0.12, 0.12, 0.12, 0.12, 0.12, 0.22],
        .waving: [0.14, 0.14, 0.14, 0.28],
        .jumping: [0.14, 0.14, 0.14, 0.14, 0.28],
        .failed: [0.14, 0.14, 0.14, 0.14, 0.14, 0.14, 0.14, 0.24],
        .waiting: [0.15, 0.15, 0.15, 0.15, 0.15, 0.26],
        .running: [0.12, 0.12, 0.12, 0.12, 0.12, 0.22],
        .review: [0.15, 0.15, 0.15, 0.15, 0.15, 0.28]
    ]

    /// Ambient actions a random idle pet may play. `failed` is deliberately
    /// excluded: it would suggest a real error.
    static let ambientActions: [PetAction] = [.waving, .jumping, .waiting, .running, .review]

    static func rows(forImageHeight height: Int) -> Int? {
        switch height {
        case v1Height: return 9
        case v2Height: return 11
        default: return nil
        }
    }
}

struct PetSummary: Identifiable, Sendable {
    let id: String
    let displayName: String
    /// Localization key of a non-fatal manifest warning, if any.
    let warningKey: String?
}

struct PetManifest {
    let displayName: String
    let spritesheetPath: String
    let warningKey: String?
}

enum PetLoadError: Error {
    case missingManifest
    case missingSpritesheet
    case invalidImage
    case invalidDimensions
}

/// Loads a `~/.codex/pets/<pet-id>/` package (pet.json + spritesheet.webp).
/// The WebP is decoded once; frames are cropped and cached afterwards.
struct CodexPetPackage {
    let id: String
    let displayName: String
    let warningKey: String?
    let frames: [PetAction: [CGImage]]

    static func load(folder: URL) throws -> CodexPetPackage {
        guard let manifest = readManifest(folder: folder) else {
            throw PetLoadError.missingManifest
        }
        guard let sheetURL = resolvedSpritesheetURL(folder: folder, path: manifest.spritesheetPath),
              FileManager.default.fileExists(atPath: sheetURL.path) else {
            throw PetLoadError.missingSpritesheet
        }
        guard let source = CGImageSourceCreateWithURL(sheetURL as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw PetLoadError.invalidImage
        }
        return CodexPetPackage(
            id: folder.lastPathComponent,
            displayName: manifest.displayName,
            warningKey: manifest.warningKey,
            frames: try extractFrames(from: image)
        )
    }

    /// Parses pet.json. Lenient by design and matching the Codex loader: `id`
    /// is optional (a mismatch is a warning, never a rejection),
    /// `spritesheetPath` defaults to `spritesheet.webp`, and extra files in
    /// the folder are ignored.
    static func readManifest(folder: URL) -> PetManifest? {
        let manifestURL = folder.appendingPathComponent("pet.json")
        guard let data = try? Data(contentsOf: manifestURL),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return nil
        }
        let folderName = folder.lastPathComponent
        let manifestID = json["id"] as? String
        let displayName = json["displayName"] as? String ?? manifestID ?? folderName
        let spritesheetPath = json["spritesheetPath"] as? String ?? "spritesheet.webp"
        let warningKey: String? = manifestID != folderName ? "pet_warning_id" : nil
        return PetManifest(
            displayName: displayName,
            spritesheetPath: spritesheetPath,
            warningKey: warningKey
        )
    }

    /// Keeps the spritesheet inside the pet folder; path traversal is rejected.
    static func resolvedSpritesheetURL(folder: URL, path: String) -> URL? {
        guard !path.isEmpty, !path.contains("/"), !path.contains("..") else { return nil }
        return folder.appendingPathComponent(path)
    }

    /// A pet id is a folder name inside the pets directory. Reject anything
    /// that could escape it (UserDefaults can be edited by hand or tools).
    static func isValidPetID(_ id: String) -> Bool {
        !id.isEmpty && !id.contains("/") && !id.contains("..")
    }

    /// Crops the canonical frame rows from a decoded atlas. Trailing fully
    /// transparent cells are trimmed, so rows with fewer frames than the
    /// canonical count (e.g. a 4-frame waving row) play correctly.
    static func extractFrames(from image: CGImage) throws -> [PetAction: [CGImage]] {
        guard image.width == PetAtlas.columns * PetAtlas.cellWidth,
              let rows = PetAtlas.rows(forImageHeight: image.height) else {
            throw PetLoadError.invalidDimensions
        }
        let cellWidth = image.width / PetAtlas.columns
        let cellHeight = image.height / rows
        var frames: [PetAction: [CGImage]] = [:]
        for action in PetAction.allCases {
            let maxFrames = PetAtlas.frameCounts[action] ?? 0
            var rowFrames: [CGImage] = []
            for column in 0..<maxFrames {
                let rect = CGRect(
                    x: CGFloat(column * cellWidth),
                    y: CGFloat(action.rawValue * cellHeight),
                    width: CGFloat(cellWidth),
                    height: CGFloat(cellHeight)
                )
                guard let cell = image.cropping(to: rect) else { break }
                if !hasVisiblePixels(cell) { break }
                rowFrames.append(cell)
            }
            if !rowFrames.isEmpty {
                frames[action] = rowFrames
            }
        }
        return frames
    }

    static func hasVisiblePixels(_ image: CGImage) -> Bool {
        let width = image.width
        let height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        // When the image cannot be inspected, keep the frame rather than drop it.
        guard drawn else { return true }
        var index = 3
        while index < pixels.count {
            if pixels[index] > 0 { return true }
            index += 4
        }
        return false
    }
}

/// Scans a pets folder for installable pets. A pet needs a readable pet.json
/// and its referenced spritesheet; anything else in the folder is ignored.
enum CodexPetLibrary {
    static func scan(folder: URL) -> [PetSummary] {
        let fileManager = FileManager.default
        guard let entries = try? fileManager.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return [] }
        var summaries: [PetSummary] = []
        let sorted = entries.sorted { $0.lastPathComponent < $1.lastPathComponent }
        for entry in sorted {
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: entry.path, isDirectory: &isDirectory),
                  isDirectory.boolValue,
                  let manifest = CodexPetPackage.readManifest(folder: entry),
                  let sheetURL = CodexPetPackage.resolvedSpritesheetURL(
                      folder: entry,
                      path: manifest.spritesheetPath
                  ),
                  fileManager.fileExists(atPath: sheetURL.path) else { continue }
            summaries.append(PetSummary(
                id: entry.lastPathComponent,
                displayName: manifest.displayName,
                warningKey: manifest.warningKey
            ))
        }
        return summaries
    }
}