import Foundation
import XCTest
@testable import OpenCodeUsageTouchBar

final class CodexUsageClientTests: XCTestCase {
    func testDrainLinesReturnsCompleteLinesAndKeepsPartialTail() {
        var buffer = Data("a\nb\npartial".utf8)
        XCTAssertEqual(CodexUsageClient.drainLines(from: &buffer).map { String(data: $0, encoding: .utf8) }, ["a", "b"])
        XCTAssertEqual(String(data: buffer, encoding: .utf8), "partial")
    }

    func testDrainLinesWithoutNewlineYieldsNothing() {
        var buffer = Data("incomplete".utf8)
        XCTAssertTrue(CodexUsageClient.drainLines(from: &buffer).isEmpty)
        XCTAssertEqual(buffer.count, "incomplete".utf8.count)
    }

    /// The read loop drains after every chunk: a line split across two reads
    /// must surface exactly once, on the read that completes it.
    func testDrainLinesAcrossTwoReadsReturnsOnlyNewlyCompleteLines() {
        var buffer = Data()
        buffer.append(Data("{\"id\":1}\n{\"id\":2".utf8))
        var lines = CodexUsageClient.drainLines(from: &buffer)
        XCTAssertEqual(lines.count, 1)
        XCTAssertEqual(String(data: buffer, encoding: .utf8), "{\"id\":2")

        buffer.append(Data(",\"result\":{}}\n{\"id\":3}\n".utf8))
        lines = CodexUsageClient.drainLines(from: &buffer)
        XCTAssertEqual(lines.count, 2)
        XCTAssertTrue(CodexUsageClient.isResponse(id: 2, in: lines[0]))
        XCTAssertFalse(CodexUsageClient.isResponse(id: 2, in: lines[1]))
        XCTAssertTrue(buffer.isEmpty)
    }

    func testIsResponseMatchesOnlyTheRequestedId() {
        XCTAssertTrue(CodexUsageClient.isResponse(id: 2, in: Data("{\"id\":2,\"result\":{}}".utf8)))
        XCTAssertFalse(CodexUsageClient.isResponse(id: 2, in: Data("{\"id\":1,\"result\":{}}".utf8)))
        XCTAssertFalse(CodexUsageClient.isResponse(id: 2, in: Data("{\"method\":\"notify\"}".utf8)))
        XCTAssertFalse(CodexUsageClient.isResponse(id: 2, in: Data("not json".utf8)))
        XCTAssertFalse(CodexUsageClient.isResponse(id: 2, in: Data()))
    }
}
