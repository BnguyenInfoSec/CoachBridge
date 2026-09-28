import XCTest
@testable import CoachBridge

final class UsageTests: XCTestCase {

    // MARK: Reading what the provider reports

    func testAnthropicResponseCountsCacheTokensAsInput() {
        let json = #"{"usage":{"input_tokens":1200,"cache_creation_input_tokens":300,"cache_read_input_tokens":500,"output_tokens":410}}"#
        XCTAssertEqual(UsageParsing.anthropic(response: Data(json.utf8)), TokenUsage(input: 2000, output: 410))
        XCTAssertNil(UsageParsing.anthropic(response: Data(#"{"content":[]}"#.utf8)))
    }

    /// Input arrives in message_start, output in message_delta, and the delta is cumulative.
    func testAnthropicStreamReportsInputThenRunningOutput() {
        let start = #"data: {"type":"message_start","message":{"usage":{"input_tokens":2500,"output_tokens":1}}}"#
        let delta = #"data: {"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":380}}"#
        XCTAssertEqual(UsageParsing.anthropicStream(line: start)?.input, 2500)
        XCTAssertNil(UsageParsing.anthropicStream(line: start)?.output, "the 1-token placeholder isn't the real output count")
        XCTAssertEqual(UsageParsing.anthropicStream(line: delta)?.output, 380)
        XCTAssertNil(UsageParsing.anthropicStream(line: #"data: {"type":"content_block_delta","delta":{"type":"text_delta","text":"hi"}}"#))
        XCTAssertNil(UsageParsing.anthropicStream(line: "event: message_start"))
    }

    func testOpenAIUsage() {
        XCTAssertEqual(UsageParsing.openAI(["usage": ["prompt_tokens": 900, "completion_tokens": 120]]), TokenUsage(input: 900, output: 120))
        XCTAssertNil(UsageParsing.openAI(["choices": []]))
    }

    // MARK: Cost

    func testCostUsesTheModelFamilysPrice() throws {
        let r = UsageRecord(date: .now, feature: .note, provider: "anthropic", model: "claude-sonnet-5",
                            inputTokens: 1_000_000, outputTokens: 100_000)
        XCTAssertEqual(try XCTUnwrap(UsagePricing.cost(r)), 3 + 1.5, accuracy: 0.0001)
        XCTAssertNil(UsagePricing.cost(UsageRecord(date: .now, feature: .chat, provider: "hosted", model: "default",
                                                   inputTokens: 10, outputTokens: 10)),
                     "an unknown model isn't guessed at")
    }

    func testSummaryGroupsByFeatureAndKeepsUnpricedCallsOut() {
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        func r(_ f: UsageFeature, _ model: String, _ i: Int, _ o: Int, daysAgo: Double = 0) -> UsageRecord {
            UsageRecord(date: now.addingTimeInterval(-daysAgo * 86_400), feature: f, provider: "x", model: model,
                        inputTokens: i, outputTokens: o)
        }
        let records = [r(.chat, "claude-sonnet-5", 2000, 300), r(.chat, "claude-sonnet-5", 1000, 200),
                       r(.note, "claude-haiku-5", 4000, 500), r(.planUpdate, "default", 8000, 3000),
                       r(.chat, "claude-sonnet-5", 99_999, 99_999, daysAgo: 40)]
        let s = UsageSummary.make(records, from: now.addingTimeInterval(-30 * 86_400), to: now.addingTimeInterval(1))
        XCTAssertEqual(s.calls, 4, "the call from 40 days ago is outside the period")
        XCTAssertEqual(s.lines.map(\.feature), [.chat, .planUpdate, .note])
        XCTAssertEqual(s.lines.first?.calls, 2)
        XCTAssertEqual(s.tokens, TokenUsage(input: 15_000, output: 4_000))
        XCTAssertEqual(s.unpriced, 1)
        let dollarTokens: Double = 3000 * 3 + 500 * 15 + 4000 * 1 + 500 * 5      // sonnet chat + haiku note
        let expected = dollarTokens / 1_000_000
        XCTAssertEqual(s.cost, expected, accuracy: 0.000001)
        XCTAssertEqual(s.models, ["claude-haiku-5", "claude-sonnet-5", "default"])
    }

    /// What a beta tester shares: counts and dollars, and nothing that says what they asked.
    func testSharedTextIsCountsOnly() {
        let rec = UsageRecord(date: .now, feature: .chat, provider: "anthropic", model: "claude-sonnet-5",
                              inputTokens: 1234, outputTokens: 56)
        let text = UsageSummary.make([rec], from: .distantPast, to: .distantFuture).shareText(period: "this month")
        XCTAssertTrue(text.contains("1234"))
        XCTAssertTrue(text.contains("Coach chat"))
        XCTAssertEqual(UsageSummary.dollars(0.004), "<$0.01")
        XCTAssertEqual(UsageSummary.dollars(1.5), "$1.50")
        // A record has no field that could hold content; this guards against one being added.
        let keys = Set(Mirror(reflecting: rec).children.compactMap(\.label))
        XCTAssertEqual(keys, ["id", "date", "feature", "provider", "model", "inputTokens", "outputTokens"])
    }

    // MARK: Labelling calls

    func testTheFeatureLabelReachesTasksStartedInsideIt() async {
        let seen = await UsageContext.$feature.withValue(.note) {
            await Task { UsageContext.feature }.value
        }
        XCTAssertEqual(seen, .note, "the stream's own task inherits the label")
        XCTAssertEqual(UsageContext.feature, .other)
    }
}
