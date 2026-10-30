import XCTest
@testable import SwitcherCore

final class UsageDecoderTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_760_000_000)

    func testClaudeFullResponse() throws {
        let json = """
        {"five_hour":{"utilization":23.5,"resets_at":"2025-10-10T12:00:00.123456+00:00"},
         "seven_day":{"utilization":41,"resets_at":"2025-10-14T00:00:00Z"},
         "seven_day_opus":{"utilization":12.25,"resets_at":"2025-10-14T00:00:00Z"},
         "seven_day_sonnet":{"utilization":0,"resets_at":null},
         "limits":[{"kind":"weekly_scoped","percent":55,"resets_at":"2025-10-14T00:00:00Z","scope":{"model":{"id":null,"display_name":"Fable"}}},
                   {"kind":"weekly_scoped","percent":99,"scope":{"model":{"display_name":"Opus"}}}],
         "extra_usage":{"is_enabled":true,"monthly_limit":500,"used_credits":314.12,"currency":"USD","out_of_credits":false}}
        """
        let r = try ClaudeUsageDecoder.decode(Data(json.utf8))
        let s = try XCTUnwrap(ClaudeUsageDecoder.snapshot(from: r, accountId: "a", now: now))
        XCTAssertEqual(s.fiveHour?.usedPercent, 23.5)
        XCTAssertEqual(s.fiveHour?.resetsAt, Date(timeIntervalSince1970: 1_760_097_600))
        XCTAssertEqual(s.weekly?.usedPercent, 41)
        XCTAssertEqual(s.modelWindows.map(\.label), ["Opus weekly", "Fable weekly"], "legacy opus kept, zero sonnet dropped, scoped Fable added, duplicate Opus skipped")
        XCTAssertEqual(s.modelWindows.first?.usedPercent, 12.25)
        XCTAssertEqual(s.extraUsage?.usedPercent ?? 0, 62.824, accuracy: 0.001)
        XCTAssertEqual(s.worstPercent, 55)
        XCTAssertEqual(s.nextReset, s.fiveHour?.resetsAt)
    }

    func testClaudeNullWindowsMeansNoDashboard() throws {
        let r = try ClaudeUsageDecoder.decode(Data("{\"five_hour\":null,\"seven_day\":null}".utf8))
        XCTAssertNil(ClaudeUsageDecoder.snapshot(from: r, accountId: "a", now: now))
        let r2 = try ClaudeUsageDecoder.decode(Data("{\"limits\":[{\"kind\":\"session\",\"percent\":5},{\"kind\":\"weekly_all\",\"percent\":7}]}".utf8))
        let s2 = try XCTUnwrap(ClaudeUsageDecoder.snapshot(from: r2, accountId: "a", now: now))
        XCTAssertEqual(s2.fiveHour?.usedPercent, 5)
        XCTAssertEqual(s2.weekly?.usedPercent, 7)
    }

    func testClaudeStatusLineBeacon() {
        let json = "{\"rate_limits\":{\"five_hour\":{\"used_percentage\":23.5,\"resets_at\":1738425600},\"seven_day\":{\"used_percentage\":41.2,\"resets_at\":1738857600}}}"
        let s = ClaudeUsageDecoder.snapshot(fromStatusLineJSON: Data(json.utf8), accountId: "a", observedAt: now)!
        XCTAssertEqual(s.source, "statusline-beacon")
        XCTAssertEqual(s.fiveHour?.usedPercent, 23.5)
        XCTAssertEqual(s.weekly?.resetsAt, Date(timeIntervalSince1970: 1_738_857_600))
        XCTAssertNil(ClaudeUsageDecoder.snapshot(fromStatusLineJSON: Data("{\"cwd\":\"/\"}".utf8), accountId: "a", observedAt: now))
    }

    func testCodexClassifiesWindowsByDuration() throws {
        let json = """
        {"plan_type":"plus","rate_limit":{"allowed":true,"limit_reached":false,
          "primary_window":{"used_percent":12.5,"limit_window_seconds":604800,"reset_after_seconds":3600},
          "secondary_window":{"used_percent":80,"limit_window_seconds":18000,"reset_at":1760003600}},
         "credits":{"has_credits":true,"unlimited":false,"balance":"12.50"}}
        """
        let r = try CodexUsageDecoder.decode(Data(json.utf8))
        let s = try XCTUnwrap(CodexUsageDecoder.snapshot(from: r, accountId: "c", now: now))
        XCTAssertEqual(s.fiveHour?.usedPercent, 80, "5-hour window found in the secondary slot")
        XCTAssertEqual(s.fiveHour?.resetsAt, Date(timeIntervalSince1970: 1_760_003_600))
        XCTAssertEqual(s.weekly?.usedPercent, 12.5)
        XCTAssertEqual(s.weekly?.resetsAt, now.addingTimeInterval(3600), "reset_after_seconds fallback")
        XCTAssertEqual(s.credits?.balance, 12.5)
        XCTAssertEqual(s.plan, "plus")
        XCTAssertEqual(s.primaryPercent, 80)
    }

    func testCodexSingleWindowAndNumericBalance() throws {
        let json = "{\"rate_limit\":{\"primary_window\":{\"used_percent\":3}},\"credits\":{\"has_credits\":false,\"balance\":0}}"
        let s = try XCTUnwrap(CodexUsageDecoder.snapshot(from: CodexUsageDecoder.decode(Data(json.utf8)), accountId: "c", now: now))
        XCTAssertNil(s.fiveHour)
        XCTAssertEqual(s.weekly?.usedPercent, 3, "unknown duration defaults to weekly")
        XCTAssertEqual(s.credits?.balance, 0)
        XCTAssertNil(CodexUsageDecoder.snapshot(from: CodexUsageDecoder.decode(Data("{}".utf8)), accountId: "c", now: now))
    }

    func testWindowMath() {
        let w = UsageWindow(kind: .fiveHour, label: "5-hour", usedPercent: 150, resetsAt: now.addingTimeInterval(3600), windowSeconds: 18000)
        XCTAssertEqual(w.usedPercent, 100, "clamped")
        XCTAssertEqual(w.elapsedRatio(now: now)!, 0.8, accuracy: 0.0001)
        XCTAssertEqual(w.secondsUntilReset(now: now), 3600)
        XCTAssertNil(UsageWindow(kind: .weekly, label: "w", usedPercent: 1).elapsedRatio(now: now))
    }

    func testRetryAfterParsing() {
        XCTAssertEqual(HTTPResponse(status: 429, headers: ["retry-after": "120"]).retryAfter, 120)
        XCTAssertNil(HTTPResponse(status: 429, headers: ["retry-after": "0"]).retryAfter)
        XCTAssertNil(HTTPResponse(status: 429).retryAfter)
        XCTAssertTrue(HTTPResponse(status: 200, body: Data("<!DOCTYPE html><html>".utf8)).looksLikeHTML)
    }
}
