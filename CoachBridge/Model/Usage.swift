import Foundation

/// What each AI feature actually costs, measured on the phone. The beta's job is to replace the
/// guess ("$1–3 a month per active user") with real numbers before a subscription is priced.
///
/// Only counts are kept: feature, provider, model and token totals. Never a prompt or a reply.

enum UsageFeature: String, Codable, CaseIterable, Identifiable, Sendable {
    case chat, planUpdate, note, other
    var id: String { rawValue }
    var label: String {
        switch self {
        case .chat: return "Coach chat"
        case .planUpdate: return "Weekly plan updates"
        case .note: return "Coach's notes"
        case .other: return "Other"
        }
    }
}

struct TokenUsage: Equatable, Sendable {
    var input: Int
    var output: Int

    static let zero = TokenUsage(input: 0, output: 0)
    static func + (a: TokenUsage, b: TokenUsage) -> TokenUsage { TokenUsage(input: a.input + b.input, output: a.output + b.output) }
}

struct UsageRecord: Codable, Equatable, Identifiable, Sendable {
    var id = UUID()
    var date: Date
    var feature: UsageFeature
    var provider: String
    var model: String
    var inputTokens: Int
    var outputTokens: Int
}

// MARK: - Prices

/// List prices in US dollars per million tokens, by model family, as of when this was written.
/// An estimate to size a subscription with, not a bill: the provider's console is the truth, and
/// the Settings screen shows which prices it assumed so the numbers can be checked.
enum UsagePricing {
    struct Price: Equatable, Sendable {
        let input: Double
        let output: Double
        let basis: String
    }

    static func price(model: String) -> Price? {
        let m = model.lowercased()
        if m.contains("haiku") { return Price(input: 1, output: 5, basis: "Claude Haiku list price") }
        if m.contains("sonnet") { return Price(input: 3, output: 15, basis: "Claude Sonnet list price") }
        if m.contains("opus") { return Price(input: 5, output: 25, basis: "Claude Opus list price") }
        if m.contains("gpt-5-mini") { return Price(input: 0.25, output: 2, basis: "GPT-5 mini list price") }
        if m.contains("gpt-5") { return Price(input: 1.25, output: 10, basis: "GPT-5 list price") }
        return nil
    }

    /// Dollars for one record, or nil when the model's price isn't known.
    static func cost(_ r: UsageRecord) -> Double? {
        guard let p = price(model: r.model) else { return nil }
        return (Double(r.inputTokens) * p.input + Double(r.outputTokens) * p.output) / 1_000_000
    }
}

// MARK: - Summary

struct UsageSummary: Equatable, Sendable {
    struct Line: Equatable, Sendable, Identifiable {
        let feature: UsageFeature
        var calls: Int
        var tokens: TokenUsage
        var cost: Double
        var id: String { feature.rawValue }
    }

    var lines: [Line]
    var calls: Int
    var tokens: TokenUsage
    /// Estimated dollars for the calls whose model has a known price.
    var cost: Double
    /// Calls on a model with no known price, left out of `cost` rather than guessed.
    var unpriced: Int
    var models: [String]

    static func make(_ records: [UsageRecord], from start: Date, to end: Date) -> UsageSummary {
        let inRange = records.filter { $0.date >= start && $0.date < end }
        var byFeature: [UsageFeature: Line] = [:]
        var unpriced = 0
        for r in inRange {
            var line = byFeature[r.feature] ?? Line(feature: r.feature, calls: 0, tokens: .zero, cost: 0)
            line.calls += 1
            line.tokens = line.tokens + TokenUsage(input: r.inputTokens, output: r.outputTokens)
            if let c = UsagePricing.cost(r) { line.cost += c } else { unpriced += 1 }
            byFeature[r.feature] = line
        }
        let lines = UsageFeature.allCases.compactMap { byFeature[$0] }
        return UsageSummary(lines: lines,
                            calls: lines.reduce(0) { $0 + $1.calls },
                            tokens: lines.reduce(.zero) { $0 + $1.tokens },
                            cost: lines.reduce(0) { $0 + $1.cost },
                            unpriced: unpriced,
                            models: Array(Set(inRange.map(\.model))).sorted())
    }

    /// Plain text a beta tester can send back: counts and dollars, nothing about their training.
    func shareText(period: String) -> String {
        var out = ["Coach Bridge AI usage, \(period)",
                   "Calls: \(calls) · tokens in \(tokens.input) · out \(tokens.output) · est. \(Self.dollars(cost))"]
        for l in lines {
            out.append("- \(l.feature.label): \(l.calls) calls, \(l.tokens.input) in / \(l.tokens.output) out, est. \(Self.dollars(l.cost))")
        }
        if !models.isEmpty { out.append("Models: " + models.joined(separator: ", ")) }
        if unpriced > 0 { out.append("\(unpriced) calls on a model without a known price aren't in the estimate.") }
        return out.joined(separator: "\n")
    }

    static func dollars(_ d: Double) -> String {
        d < 0.01 && d > 0 ? "<$0.01" : String(format: "$%.2f", d)
    }
}

// MARK: - Reading usage out of provider responses (pure, unit-tested)

enum UsageParsing {
    /// Anthropic's non-streamed response: `usage.input_tokens` (plus any cache reads and writes,
    /// which are billed as input too) and `usage.output_tokens`.
    static func anthropic(response data: Data) -> TokenUsage? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let usage = obj["usage"] as? [String: Any] else { return nil }
        return anthropic(usage)
    }

    static func anthropic(_ usage: [String: Any]) -> TokenUsage? {
        func n(_ k: String) -> Int { (usage[k] as? NSNumber)?.intValue ?? 0 }
        let input = n("input_tokens") + n("cache_creation_input_tokens") + n("cache_read_input_tokens")
        let output = n("output_tokens")
        return input == 0 && output == 0 ? nil : TokenUsage(input: input, output: output)
    }

    /// One line of Anthropic's stream. `message_start` carries the input count; `message_delta`
    /// carries the output count so far (cumulative, so the last one wins).
    static func anthropicStream(line: String) -> (input: Int?, output: Int?)? {
        guard line.hasPrefix("data:"),
              let data = line.dropFirst(5).trimmingCharacters(in: .whitespaces).data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        switch obj["type"] as? String {
        case "message_start":
            guard let u = (obj["message"] as? [String: Any])?["usage"] as? [String: Any], let t = anthropic(u) else { return nil }
            return (t.input, nil)
        case "message_delta":
            guard let out = ((obj["usage"] as? [String: Any])?["output_tokens"] as? NSNumber)?.intValue else { return nil }
            return (nil, out)
        default:
            return nil
        }
    }

    /// OpenAI: `usage.prompt_tokens` and `usage.completion_tokens`, in a non-streamed response or
    /// in the final chunk of a stream requested with `include_usage`.
    static func openAI(_ root: [String: Any]) -> TokenUsage? {
        guard let usage = root["usage"] as? [String: Any] else { return nil }
        let input = (usage["prompt_tokens"] as? NSNumber)?.intValue ?? 0
        let output = (usage["completion_tokens"] as? NSNumber)?.intValue ?? 0
        return input == 0 && output == 0 ? nil : TokenUsage(input: input, output: output)
    }
}
