import Foundation

/// One day's check-in, exactly as written to Drive: /Coach/health/<date>.json
struct DayRecord: Equatable, Sendable {
    static let schema = 1
    static let source = "coach-bridge"

    /// Local calendar day the check-in belongs to (the morning), "yyyy-MM-dd".
    let date: String
    let exportedAt: Date
    /// Missing metrics are simply absent — never 0.
    let metrics: [MetricKey: Double]

    var fileName: String { "\(date).json" }

    /// Deterministic JSON: fixed key order, fixed decimals per key, absent keys omitted.
    func jsonString(timeZone: TimeZone = .current) -> String {
        let iso = ISO8601DateFormatter()
        iso.timeZone = timeZone
        iso.formatOptions = [.withInternetDateTime]

        let metricLines = MetricKey.allCases.compactMap { key -> String? in
            guard let v = metrics[key], v.isFinite else { return nil }
            return "    \"\(key.rawValue)\": \(key.format(v))"
        }
        let metricsBlock = metricLines.isEmpty
            ? "{}"
            : "{\n" + metricLines.joined(separator: ",\n") + "\n  }"

        let lines = [
            "{",
            "  \"schema\": \(Self.schema),",
            "  \"source\": \"\(Self.source)\",",
            "  \"date\": \"\(date)\",",
            "  \"exportedAt\": \"\(iso.string(from: exportedAt))\",",
            "  \"metrics\": \(metricsBlock)",
            "}",
        ]
        return lines.joined(separator: "\n") + "\n"
    }

    func jsonData(timeZone: TimeZone = .current) -> Data {
        Data(jsonString(timeZone: timeZone).utf8)
    }

    /// "yyyy-MM-dd" for a local day.
    /// This names the Drive files and keys every plan lookup, so it runs hundreds of times per
    /// calendar redraw. It used to build a DateFormatter each call (~160 µs on the simulator);
    /// plain Gregorian components give the same string (ContractTests sweeps both) in a
    /// fraction of that.
    static func dateKey(for day: Date, calendar: Calendar = .current) -> String {
        var g = calendar
        if g.identifier != .gregorian {
            g = Calendar(identifier: .gregorian)
            g.timeZone = calendar.timeZone
        }
        let c = g.dateComponents([.year, .month, .day], from: day)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }
}
