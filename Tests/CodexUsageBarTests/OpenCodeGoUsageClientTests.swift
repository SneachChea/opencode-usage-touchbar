import XCTest
@testable import CodexUsageBar

final class OpenCodeGoUsageClientTests: XCTestCase {
    func testParsesValidResponse() throws {
        let json = """
        {
          "usage": {
            "rolling": { "percent": 40, "resetsAt": "2026-08-31T14:30:00Z", "status": "ok" },
            "weekly": { "percent": 30, "resetsAt": "2026-09-06T23:59:59Z", "status": "ok" },
            "monthly": { "percent": 20, "resetsAt": "2026-09-30T00:00:00Z", "status": "ok" }
          }
        }
        """
        let snapshot = try OpenCodeGoUsageClient.parse(Data(json.utf8))
        XCTAssertEqual(snapshot.rolling?.usedPercent, 40)
        XCTAssertEqual(snapshot.rolling?.remainingPercent, 60)
        XCTAssertEqual(snapshot.rolling?.durationMinutes, 300)
        XCTAssertEqual(snapshot.weekly?.usedPercent, 30)
        XCTAssertEqual(snapshot.weekly?.durationMinutes, 10080)
        XCTAssertEqual(snapshot.monthly?.usedPercent, 20)
        XCTAssertNil(snapshot.monthly?.durationMinutes)
    }

    func testParsesFractionalSecondResetDate() throws {
        let json = """
        {
          "usage": {
            "rolling": { "percent": 10, "resetsAt": "2026-08-31T14:30:00.123Z", "status": "ok" },
            "weekly": { "percent": 5, "resetsAt": "2026-09-06T00:00:00Z", "status": "ok" },
            "monthly": { "percent": 2, "resetsAt": "2026-09-30T00:00:00Z", "status": "ok" }
          }
        }
        """
        let snapshot = try OpenCodeGoUsageClient.parse(Data(json.utf8))
        XCTAssertNotNil(snapshot.rolling?.resetsAt)
    }

    func testMissingRollingIsInvalidResponse() {
        let json = """
        {
          "usage": {
            "weekly": { "percent": 10, "resetsAt": "2026-09-06T00:00:00Z", "status": "ok" }
          }
        }
        """
        XCTAssertThrowsError(try OpenCodeGoUsageClient.parse(Data(json.utf8))) { error in
            XCTAssertEqual(error as? OpenCodeGoUsageClientError, .invalidResponse)
        }
    }

    func testMalformedRollingIsInvalidResponse() {
        let json = """
        {
          "usage": {
            "rolling": { "percent": "nope", "resetsAt": "2026-08-31T14:30:00Z", "status": "ok" }
          }
        }
        """
        XCTAssertThrowsError(try OpenCodeGoUsageClient.parse(Data(json.utf8))) { error in
            XCTAssertEqual(error as? OpenCodeGoUsageClientError, .invalidResponse)
        }
    }

    func testInvalidWeeklyWindowYieldsNil() throws {
        let json = """
        {
          "usage": {
            "rolling": { "percent": 50, "resetsAt": "2026-08-31T14:30:00Z", "status": "ok" },
            "weekly": { "percent": "abc", "resetsAt": "2026-09-06T00:00:00Z", "status": "ok" },
            "monthly": { "percent": 25, "resetsAt": "2026-09-30T00:00:00Z", "status": "ok" }
          }
        }
        """
        let snapshot = try OpenCodeGoUsageClient.parse(Data(json.utf8))
        XCTAssertNil(snapshot.weekly)
        XCTAssertEqual(snapshot.monthly?.usedPercent, 25)
    }

    func testInvalidResetDateYieldsNil() throws {
        let json = """
        {
          "usage": {
            "rolling": { "percent": 60, "resetsAt": "not-a-date", "status": "ok" },
            "weekly": { "percent": 30, "resetsAt": "2026-09-06T00:00:00Z", "status": "ok" },
            "monthly": { "percent": 20, "resetsAt": "2026-09-30T00:00:00Z", "status": "ok" }
          }
        }
        """
        let snapshot = try OpenCodeGoUsageClient.parse(Data(json.utf8))
        XCTAssertNil(snapshot.rolling?.resetsAt)
        XCTAssertEqual(snapshot.rolling?.usedPercent, 60)
    }

    func testNonJSONDataIsInvalidResponse() {
        XCTAssertThrowsError(try OpenCodeGoUsageClient.parse(Data("not json".utf8))) { error in
            XCTAssertEqual(error as? OpenCodeGoUsageClientError, .invalidResponse)
        }
    }
}