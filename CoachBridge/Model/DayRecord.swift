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
    static func dateKey(for day: Date, calendar: Calendar = .current) -> String {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = calendar.timeZone
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: day)
    }
}
