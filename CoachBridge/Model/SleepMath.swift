import Foundation

/// One "asleep" interval (core, deep, REM or unspecified). In-bed and awake are excluded upstream.
struct SleepInterval: Sendable, Equatable {
    let start: Date
    let end: Date
    let isWatch: Bool
}

enum SleepMath {
    struct Result: Equatable {
        let hours: Double
        let usedWatchOnly: Bool
        let intervalsUsed: Int
        let intervalsIgnored: Int
    }

    /// Hours asleep inside `window`.
    /// - If any Apple Watch intervals exist, only Watch intervals count (iPhone/other sources ignored).
    /// - Overlapping intervals are merged, so stages or duplicate sources are never double-counted.
    /// - Intervals are clipped to the window.
    static func hoursAsleep(_ intervals: [SleepInterval], window: DateInterval) -> Result? {
        let hasWatch = intervals.contains(where: \.isWatch)
        let chosen = hasWatch ? intervals.filter(\.isWatch) : intervals

        let clipped: [(Date, Date)] = chosen.compactMap { i in
            let s = max(i.start, window.start)
            let e = min(i.end, window.end)
            return e > s ? (s, e) : nil
        }.sorted { $0.0 < $1.0 }

        guard !clipped.isEmpty else { return nil }

        var total: TimeInterval = 0
        var curStart = clipped[0].0
        var curEnd = clipped[0].1
        for (s, e) in clipped.dropFirst() {
            if s <= curEnd {
                curEnd = max(curEnd, e)
            } else {
                total += curEnd.timeIntervalSince(curStart)
                curStart = s
                curEnd = e
            }
        }
        total += curEnd.timeIntervalSince(curStart)

        return Result(hours: total / 3600,
                      usedWatchOnly: hasWatch,
                      intervalsUsed: clipped.count,
                      intervalsIgnored: intervals.count - chosen.count)
    }
}

enum Stats {
    static func mean(_ xs: [Double]) -> Double? {
        xs.isEmpty ? nil : xs.reduce(0, +) / Double(xs.count)
    }

    static func median(_ xs: [Double]) -> Double? {
        guard !xs.isEmpty else { return nil }
        let s = xs.sorted()
        let m = s.count / 2
        return s.count % 2 == 0 ? (s[m - 1] + s[m]) / 2 : s[m]
    }

    static func celsiusToFahrenheit(_ c: Double) -> Double { c * 9 / 5 + 32 }
}
