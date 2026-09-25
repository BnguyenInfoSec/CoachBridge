import XCTest
@testable import CoachBridge

final class RecoverySignalTests: XCTestCase {
    private let base = Array(repeating: 45.0, count: 14)
    private let hrvBase = Array(repeating: 50.0, count: 20)

    func testUnknownWithoutData() {
        XCTAssertEqual(RecoverySignal.evaluate(rhrToday: nil, rhrBaseline: [], hrvRecent: [], hrvBaseline: []).level, .unknown)
        // Too little baseline also counts as unknown.
        XCTAssertEqual(RecoverySignal.evaluate(rhrToday: 44, rhrBaseline: [45, 46], hrvRecent: [], hrvBaseline: []).level, .unknown)
    }

    func testCautionOnElevatedRHR() {
        let s = RecoverySignal.evaluate(rhrToday: 51, rhrBaseline: base, hrvRecent: [50, 50, 50], hrvBaseline: hrvBase)
        XCTAssertEqual(s.level, .caution)
        XCTAssertTrue(s.reasons[0].contains("6 bpm above"))
    }

    func testCautionOnSuppressedHRV() {
        let s = RecoverySignal.evaluate(rhrToday: 45, rhrBaseline: base, hrvRecent: [42, 43, 44], hrvBaseline: hrvBase)
        XCTAssertEqual(s.level, .caution)
    }

    func testGoodWhenBothFavourable() {
        XCTAssertEqual(RecoverySignal.evaluate(rhrToday: 43, rhrBaseline: base, hrvRecent: [53, 54, 55], hrvBaseline: hrvBase).level, .good)
    }

    func testNormalInBetween() {
        XCTAssertEqual(RecoverySignal.evaluate(rhrToday: 47, rhrBaseline: base, hrvRecent: [49, 50, 48], hrvBaseline: hrvBase).level, .normal)
    }

    func testRHROnlyStillEvaluates() {
        XCTAssertEqual(RecoverySignal.evaluate(rhrToday: 44, rhrBaseline: base, hrvRecent: [], hrvBaseline: []).level, .good)
    }
}

final class TrendMathTests: XCTestCase {
    private var cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        c.firstWeekday = 2  // Monday
        return c
    }()
    private func day(_ d: Int, _ h: Int = 0) -> Date { cal.date(from: DateComponents(year: 2026, month: 9, day: d, hour: h))! }

    func testRollingAverageUsesCalendarDays() {
        let pts = [DailyPoint(day: day(1), value: 10), DailyPoint(day: day(7), value: 20), DailyPoint(day: day(8), value: 30)]
        let r = Stats.rollingAverage(pts, days: 7, calendar: cal)
        XCTAssertEqual(r.map(\.value), [10, 15, 25])   // day 8's window is days 2–8, so day 1 drops out
    }

    func testWeeklyLoadBucketsBySportAndWeek() {
        let loads = Stats.weeklyLoad([
            (start: day(14, 7), duration: 3600, sport: .run),      // Mon Sep 14
            (start: day(16, 18), duration: 1800, sport: .run),
            (start: day(19, 8), duration: 7200, sport: .bike),
            (start: day(21, 6), duration: 2700, sport: .swim),     // Mon Sep 21
        ], calendar: cal)
        XCTAssertEqual(loads.count, 3)
        XCTAssertEqual(loads[0].sport, .bike)                      // Sport.allCases order within a week
        XCTAssertEqual(loads.first { $0.sport == .run }?.hours, 1.5)
        XCTAssertEqual(loads.last?.weekStart, day(21))
    }
}

final class AnthropicClientTests: XCTestCase {
    func testParsesTextDelta() {
        let line = #"data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Hi"}}"#
        XCTAssertEqual(AnthropicClient.parse(line: line), .text("Hi"))
    }

    func testParsesStopAndError() {
        XCTAssertEqual(AnthropicClient.parse(line: #"data: {"type":"message_stop"}"#), .stop)
        XCTAssertEqual(AnthropicClient.parse(line: #"data: {"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}"#),
                       .error("Overloaded"))
    }

    func testIgnoresOtherLines() {
        XCTAssertEqual(AnthropicClient.parse(line: "event: content_block_delta"), .none)
        XCTAssertEqual(AnthropicClient.parse(line: #"data: {"type":"ping"}"#), .none)
        XCTAssertEqual(AnthropicClient.parse(line: ""), .none)
    }

    func testRequestShape() throws {
        let c = AnthropicClient(apiKey: "sk-ant-test", model: "claude-sonnet-5")
        let req = try c.makeRequest(system: "sys", messages: [ChatMessage(role: .user, text: "hello")])
        XCTAssertEqual(req.value(forHTTPHeaderField: "x-api-key"), "sk-ant-test")
        XCTAssertEqual(req.value(forHTTPHeaderField: "anthropic-version"), "2023-06-01")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: req.httpBody!) as? [String: Any])
        XCTAssertEqual(body["model"] as? String, "claude-sonnet-5")
        XCTAssertEqual(body["stream"] as? Bool, true)
        XCTAssertEqual((body["messages"] as? [[String: String]])?.first?["content"], "hello")
    }

    func testMissingKeyThrows() {
        XCTAssertThrowsError(try AnthropicClient(apiKey: "", model: "m").makeRequest(system: "", messages: []))
    }

    func testHistoryStartsWithUserAndDropsEmpty() {
        let h = ChatModel.trimHistory([
            ChatMessage(role: .assistant, text: "old"),
            ChatMessage(role: .user, text: "q1"),
            ChatMessage(role: .assistant, text: ""),
            ChatMessage(role: .user, text: "q2"),
        ])
        XCTAssertEqual(h.map(\.text), ["q1", "q2"])
    }
}

final class CoachContextTests: XCTestCase {
    private func sample() -> DashboardData {
        DashboardData(
            today: DayRecord(date: "2026-09-22", exportedAt: .now, metrics: [.rhr: 46, .steps: 9120]),
            rhr: [], hrv: [], hrvRolling: [], weekly: [], recent: [],
            recovery: RecoverySignal(level: .normal, reasons: ["Resting HR 46 bpm"]),
            ignoredLongSessions: 0, generatedAt: .now)
    }

    func testSummaryMarksYesterdayMetricsAndMissingData() {
        let s = CoachContext.healthSummary(sample())
        XCTAssertTrue(s.contains("Resting HR 46 bpm"))
        XCTAssertTrue(s.contains("Steps (yesterday) 9120 steps"))
        XCTAssertTrue(s.contains("No workouts in the last 8 weeks."))
        XCTAssertFalse(s.contains("Sleep"))
    }

    func testSystemPromptWithoutHealth() {
        let p = CoachContext.systemPrompt(profile: "I race Ironman.", healthSummary: nil, now: .now)
        XCTAssertTrue(p.contains("I race Ironman."))
        XCTAssertTrue(p.contains("Not shared for this conversation."))
    }
}
