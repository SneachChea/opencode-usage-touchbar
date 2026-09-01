import CoreGraphics
import XCTest
@testable import OpenCodeUsageTouchBar

final class CodexPetPackageTests: XCTestCase {
    func testCanonicalFrameCounts() {
        XCTAssertEqual(PetAtlas.frameCounts[.idle], 6)
        XCTAssertEqual(PetAtlas.frameCounts[.runningRight], 8)
        XCTAssertEqual(PetAtlas.frameCounts[.runningLeft], 8)
        XCTAssertEqual(PetAtlas.frameCounts[.waving], 4)
        XCTAssertEqual(PetAtlas.frameCounts[.jumping], 5)
        XCTAssertEqual(PetAtlas.frameCounts[.failed], 8)
        XCTAssertEqual(PetAtlas.frameCounts[.waiting], 6)
        XCTAssertEqual(PetAtlas.frameCounts[.running], 6)
        XCTAssertEqual(PetAtlas.frameCounts[.review], 6)
    }

    func testRowsForImageHeight() {
        XCTAssertEqual(PetAtlas.rows(forImageHeight: PetAtlas.v1Height), 9)
        XCTAssertEqual(PetAtlas.rows(forImageHeight: PetAtlas.v2Height), 11)
        XCTAssertNil(PetAtlas.rows(forImageHeight: 1000))
    }

    func testExtractsCanonicalRowsAndTrimsTrailingEmptyCells() throws {
        // idle: 6 red frames; waving: 4 green frames; waiting: 2 blue frames.
        // Every other row stays fully transparent.
        let image = makeAtlas(fills: [
            Fill(row: 0, columns: 0..<6, color: (1, 0, 0)),
            Fill(row: 3, columns: 0..<4, color: (0, 1, 0)),
            Fill(row: 6, columns: 0..<2, color: (0, 0, 1))
        ])
        let frames = try CodexPetPackage.extractFrames(from: image)

        XCTAssertEqual(frames[.idle]?.count, 6)
        XCTAssertEqual(frames[.waving]?.count, 4)
        XCTAssertEqual(frames[.waiting]?.count, 2)
        // Untouched rows yield no frames at all.
        XCTAssertNil(frames[.runningRight])
        XCTAssertNil(frames[.review])

        // Row/crop mapping guard: row 0 must reach idle and row 3 must reach
        // waving (catches a flipped crop origin).
        let idlePixel = sampleCenter(frames[.idle]![0])
        XCTAssertGreaterThan(idlePixel.r, 200)
        XCTAssertLessThan(idlePixel.g, 80)
        XCTAssertLessThan(idlePixel.b, 80)
        let wavingPixel = sampleCenter(frames[.waving]![0])
        XCTAssertLessThan(wavingPixel.r, 80)
        XCTAssertGreaterThan(wavingPixel.g, 200)
        XCTAssertLessThan(wavingPixel.b, 80)
    }

    func testShorterRowsPlayTheirActualFrameCount() throws {
        // idle filled with only 3 frames: trailing empty cells must be trimmed.
        let image = makeAtlas(fills: [Fill(row: 0, columns: 0..<3, color: (1, 0, 0))])
        let frames = try CodexPetPackage.extractFrames(from: image)
        XCTAssertEqual(frames[.idle]?.count, 3)
    }

    func testInvalidDimensionsAreRejected() {
        let image = makeAtlas(width: 1536, height: 1000, fills: [])
        XCTAssertThrowsError(try CodexPetPackage.extractFrames(from: image)) { error in
            guard case PetLoadError.invalidDimensions = error else {
                return XCTFail("Expected invalidDimensions, got \(error)")
            }
        }
    }

    func testReadManifestDefaults() throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        try Data(#"{"displayName": "Bob"}"#.utf8).write(to: folder.appendingPathComponent("pet.json"))

        let manifest = try XCTUnwrap(CodexPetPackage.readManifest(folder: folder))
        XCTAssertEqual(manifest.displayName, "Bob")
        XCTAssertEqual(manifest.spritesheetPath, "spritesheet.webp")
        // Missing id is a warning, not a rejection.
        XCTAssertEqual(manifest.warningKey, "pet_warning_id")
    }

    func testManifestIDMismatchIsWarning() throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        try Data(#"{"id": "other-id", "displayName": "Bob"}"#.utf8)
            .write(to: folder.appendingPathComponent("pet.json"))

        let manifest = try XCTUnwrap(CodexPetPackage.readManifest(folder: folder))
        XCTAssertEqual(manifest.warningKey, "pet_warning_id")
    }

    func testManifestIDMatchHasNoWarning() throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let id = folder.lastPathComponent
        let json = #"{"id": "\#(id)", "displayName": "Bob"}"#
        try Data(json.utf8).write(to: folder.appendingPathComponent("pet.json"))

        let manifest = try XCTUnwrap(CodexPetPackage.readManifest(folder: folder))
        XCTAssertNil(manifest.warningKey)
    }

    func testResolvedSpritesheetRejectsTraversal() {
        let folder = URL(fileURLWithPath: "/tmp/pets/some-pet")
        XCTAssertEqual(
            CodexPetPackage.resolvedSpritesheetURL(folder: folder, path: "spritesheet.webp"),
            folder.appendingPathComponent("spritesheet.webp")
        )
        XCTAssertNil(CodexPetPackage.resolvedSpritesheetURL(folder: folder, path: "../x.webp"))
        XCTAssertNil(CodexPetPackage.resolvedSpritesheetURL(folder: folder, path: "a/b.webp"))
        XCTAssertNil(CodexPetPackage.resolvedSpritesheetURL(folder: folder, path: ""))
    }

    func testLoadFailsWithoutManifest() throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        XCTAssertThrowsError(try CodexPetPackage.load(folder: folder)) { error in
            guard case PetLoadError.missingManifest = error else {
                return XCTFail("Expected missingManifest, got \(error)")
            }
        }
    }

    func testGeometryInvariants() {
        XCTAssertEqual(PetAtlas.columns * PetAtlas.cellWidth, 1536)
        XCTAssertEqual(9 * PetAtlas.cellHeight, PetAtlas.v1Height)
        XCTAssertEqual(11 * PetAtlas.cellHeight, PetAtlas.v2Height)
    }

    func testFrameDurationsMatchFrameCounts() {
        for action in PetAction.allCases {
            XCTAssertEqual(
                PetAtlas.frameDurations[action]?.count,
                PetAtlas.frameCounts[action],
                "\(action) durations length must match its frame count"
            )
        }
    }

    func testV2ExtractionIgnoresLookDirectionRows() throws {
        // Rows 9-10 hold the 16 look directions; only rows 0-8 may extract.
        let image = makeAtlas(width: PetAtlas.columns * PetAtlas.cellWidth, height: PetAtlas.v2Height, fills: [
            Fill(row: 0, columns: 0..<6, color: (1, 0, 0)),
            Fill(row: 9, columns: 0..<8, color: (1, 1, 0)),
            Fill(row: 10, columns: 0..<8, color: (1, 0, 1))
        ])
        let frames = try CodexPetPackage.extractFrames(from: image)
        XCTAssertEqual(frames[.idle]?.count, 6)
        XCTAssertEqual(frames.count, 1, "look-direction rows 9-10 must not be extracted")
    }

    func testCodexPetLibraryScan() throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let fm = FileManager.default

        // pet-b is created before pet-a to prove the scan sorts by name.
        try fm.createDirectory(at: folder.appendingPathComponent("pet-b"), withIntermediateDirectories: true)
        try fm.createDirectory(at: folder.appendingPathComponent("pet-a"), withIntermediateDirectories: true)
        try fm.createDirectory(at: folder.appendingPathComponent("not-a-pet"), withIntermediateDirectories: true)

        try Data(#"{"id": "pet-a", "displayName": "Pet A"}"#.utf8)
            .write(to: folder.appendingPathComponent("pet-a/pet.json"))
        try Data("x".utf8).write(to: folder.appendingPathComponent("pet-a/spritesheet.webp"))
        try Data(#"{"id": "pet-b", "displayName": "Pet B"}"#.utf8)
            .write(to: folder.appendingPathComponent("pet-b/pet.json"))
        try Data("x".utf8).write(to: folder.appendingPathComponent("pet-b/spritesheet.webp"))

        // Manifest without spritesheet: skipped.
        try fm.createDirectory(at: folder.appendingPathComponent("pet-c"), withIntermediateDirectories: true)
        try Data(#"{"id": "pet-c"}"#.utf8).write(to: folder.appendingPathComponent("pet-c/pet.json"))
        // Stray file in the pets folder: ignored.
        try Data("notes".utf8).write(to: folder.appendingPathComponent("readme.txt"))

        let summaries = CodexPetLibrary.scan(folder: folder)
        XCTAssertEqual(summaries.map(\.id), ["pet-a", "pet-b"])
        XCTAssertEqual(summaries.map(\.displayName), ["Pet A", "Pet B"])
    }

    func testReadManifestRejectsNonJSON() throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        try Data("not json".utf8).write(to: folder.appendingPathComponent("pet.json"))
        XCTAssertNil(CodexPetPackage.readManifest(folder: folder))
    }

    func testReadManifestWrongTypedFieldsFallBackToDefaults() throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        try Data(#"{"id": 123, "displayName": 456, "spritesheetPath": 789}"#.utf8)
            .write(to: folder.appendingPathComponent("pet.json"))
        let manifest = try XCTUnwrap(CodexPetPackage.readManifest(folder: folder))
        XCTAssertEqual(manifest.displayName, folder.lastPathComponent)
        XCTAssertEqual(manifest.spritesheetPath, "spritesheet.webp")
        XCTAssertEqual(manifest.warningKey, "pet_warning_id")
    }

    // MARK: - Fixtures

    private struct Fill {
        let row: Int
        let columns: Range<Int>
        let color: (CGFloat, CGFloat, CGFloat)
    }

    private func makeFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-pet-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    private func makeAtlas(fills: [Fill]) -> CGImage {
        makeAtlas(width: PetAtlas.columns * PetAtlas.cellWidth, height: PetAtlas.v1Height, fills: fills)
    }

    private func makeAtlas(width: Int, height: Int, fills: [Fill]) -> CGImage {
        // CGContext origin is bottom-left; makeImage() exposes the buffer with
        // the context's top row first, i.e. row 0 of the atlas is at the top.
        let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.clear(CGRect(x: 0, y: 0, width: width, height: height))
        for fill in fills {
            context.setFillColor(CGColor(
                red: fill.color.0,
                green: fill.color.1,
                blue: fill.color.2,
                alpha: 1
            ))
            let y = height - (fill.row + 1) * PetAtlas.cellHeight
            context.fill(CGRect(
                x: 0,
                y: y,
                width: PetAtlas.cellWidth * max(0, fill.columns.count),
                height: PetAtlas.cellHeight
            ))
        }
        return context.makeImage()!
    }

    private func sampleCenter(_ image: CGImage) -> (r: UInt8, g: UInt8, b: UInt8, a: UInt8) {
        let center = image.cropping(to: CGRect(
            x: CGFloat(image.width / 2),
            y: CGFloat(image.height / 2),
            width: 1,
            height: 1
        )) ?? image
        var pixel = [UInt8](repeating: 0, count: 4)
        pixel.withUnsafeMutableBytes { buffer in
            let context = CGContext(
                data: buffer.baseAddress,
                width: 1,
                height: 1,
                bitsPerComponent: 8,
                bytesPerRow: 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )!
            context.draw(center, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        }
        return (pixel[0], pixel[1], pixel[2], pixel[3])
    }
}