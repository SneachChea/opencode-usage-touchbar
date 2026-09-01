// Verifies the Codex pet frame-extraction logic against the PRODUCTION sources.
// This machine has no XCTest/Testing frameworks (CommandLineTools only), so
// `swift test` cannot run here. Instead this check compiles the real pet code
// together with this script and asserts against PetAtlas/CodexPetPackage
// directly (same compilation unit, internal access works):
//
//   swiftc Sources/OpenCodeUsageTouchBar/CodexPet.swift \
//           scripts/verify-pet-logic.swift -o /tmp/pet-verify
//   /tmp/pet-verify
//
// Mirrors Tests/OpenCodeUsageTouchBarTests/CodexPetPackageTests.swift, which
// CI and machines with a full Xcode toolchain execute instead.
import CoreGraphics
import Foundation

// MARK: - Test oracle

// Expected canonical values; production constants are asserted against them.
let expectedCounts: [PetAction: Int] = [
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

var failures = 0
func check(_ condition: Bool, _ label: String) {
    if condition { print("PASS: \(label)") } else { print("FAIL: \(label)"); failures += 1 }
}

// MARK: - Atlas contract

@main
struct PetVerifyMain {
    static func main() {

for action in PetAction.allCases {
    let actual = PetAtlas.frameCounts[action]
    check(actual == expectedCounts[action], "frameCounts[\(action)] == \(expectedCounts[action] ?? -1) (got \(actual ?? -1))")
}

for action in PetAction.allCases {
    let counts = PetAtlas.frameCounts[action] ?? 0
    let durations = PetAtlas.frameDurations[action] ?? []
    check(durations.count == counts, "frameDurations[\(action)] length \(durations.count) matches frames \(counts)")
}

check(PetAtlas.rows(forImageHeight: PetAtlas.v1Height) == 9, "v1 height maps to 9 rows")
check(PetAtlas.rows(forImageHeight: PetAtlas.v2Height) == 11, "v2 height maps to 11 rows")
check(PetAtlas.rows(forImageHeight: 1000) == nil, "unknown height maps to nil")

check(PetAtlas.columns * PetAtlas.cellWidth == 1536, "columns x cellWidth == 1536")
check(9 * PetAtlas.cellHeight == PetAtlas.v1Height, "9 x cellHeight == v1Height (1872)")
check(11 * PetAtlas.cellHeight == PetAtlas.v2Height, "11 x cellHeight == v2Height (2288)")

// MARK: - Fixtures

struct Fill {
    let row: Int
    let columns: Range<Int>
    let color: (CGFloat, CGFloat, CGFloat)
}

// CGContext origin is bottom-left; makeImage() exposes the buffer with the
// context's top row first, i.e. row 0 of the atlas is at the top.
func makeAtlas(width: Int, height: Int, fills: [Fill]) -> CGImage {
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

func sample(_ image: CGImage) -> (r: UInt8, g: UInt8, b: UInt8) {
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
    return (pixel[0], pixel[1], pixel[2])
}

// MARK: - Frame extraction (production code under test)

// v1: idle=6 red, waving=4 green, waiting=2 blue; other rows untouched.
let atlas = makeAtlas(width: PetAtlas.columns * PetAtlas.cellWidth, height: PetAtlas.v1Height, fills: [
    Fill(row: 0, columns: 0..<6, color: (1, 0, 0)),
    Fill(row: 3, columns: 0..<4, color: (0, 1, 0)),
    Fill(row: 6, columns: 0..<2, color: (0, 0, 1))
])
if let frames = try? CodexPetPackage.extractFrames(from: atlas) {
    check(frames[.idle]?.count == 6, "idle has 6 frames, got \(frames[.idle]?.count ?? -1)")
    check(frames[.waving]?.count == 4, "waving has 4 frames, got \(frames[.waving]?.count ?? -1)")
    check(frames[.waiting]?.count == 2, "waiting has 2 frames (trimmed), got \(frames[.waiting]?.count ?? -1)")
    check(frames[.runningRight] == nil && frames[.review] == nil, "untouched rows yield no frames")

    let idlePixel = sample(frames[.idle]![0])
    check(idlePixel.r > 200 && idlePixel.g < 80 && idlePixel.b < 80,
          "idle frame is red (r=\(idlePixel.r) g=\(idlePixel.g) b=\(idlePixel.b)) - crop origin not flipped")
    let wavingPixel = sample(frames[.waving]![0])
    check(wavingPixel.g > 200 && wavingPixel.r < 80,
          "waving frame is green (r=\(wavingPixel.r) g=\(wavingPixel.g))")
} else {
    check(false, "v1 extraction should succeed")
}

// Shorter rows: 3 filled idle cells are trimmed to 3.
let short = makeAtlas(width: PetAtlas.columns * PetAtlas.cellWidth, height: PetAtlas.v1Height, fills: [
    Fill(row: 0, columns: 0..<3, color: (1, 0, 0))
])
if let frames = try? CodexPetPackage.extractFrames(from: short) {
    check(frames[.idle]?.count == 3, "3-frame idle row trimmed to 3")
} else {
    check(false, "short-row extraction should succeed")
}

// v2: rows 0-8 extract; look-direction content in rows 9-10 must be ignored.
let v2 = makeAtlas(width: PetAtlas.columns * PetAtlas.cellWidth, height: PetAtlas.v2Height, fills: [
    Fill(row: 0, columns: 0..<6, color: (1, 0, 0)),
    Fill(row: 9, columns: 0..<8, color: (1, 1, 0)),
    Fill(row: 10, columns: 0..<8, color: (1, 0, 1))
])
if let frames = try? CodexPetPackage.extractFrames(from: v2) {
    check(frames[.idle]?.count == 6, "v2 idle still extracts 6 frames")
    check(frames.count == 1, "v2 look-direction rows 9-10 are not extracted (got \(frames.count) rows)")
} else {
    check(false, "v2 extraction should succeed")
}

// Invalid dimensions are rejected.
let bad = makeAtlas(width: 1536, height: 1000, fills: [])
do {
    _ = try CodexPetPackage.extractFrames(from: bad)
    check(false, "invalid dimensions rejected")
} catch {
    check(true, "invalid dimensions rejected")
}

print(failures == 0 ? "\nALL CHECKS PASSED" : "\n\(failures) CHECK(S) FAILED")
exit(failures == 0 ? 0 : 1)
    }
}