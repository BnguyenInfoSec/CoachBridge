import Foundation

struct DailyPoint: Identifiable, Sendable, Equatable {
    let day: Date
    let value: Double
    var id: Date { day }
}

enum Sport: String, Codable, CaseIterable, Identifiable, Hashable, Sendable {
    case swim = "Swim"
    case bike = "Bike"
    case run = "Run"
    case other = "Strength & other"

    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .swim: return "figure.pool.swim"
        case .bike: return "figure.outdoor.cycle"
        case .run: return "figure.run"
        case .other: return "figure.strengthtraining.traditional"
        }
    }
}

struct WeeklyLoad: Identifiable, Sendable, Equatable {
    let weekStart: Date
    let sport: Sport
    let hours: Double
    var id: String { "\(weekStart.timeIntervalSince1970)-\(sport.rawValue)" }
}

struct WorkoutSummary: Identifiable, Hashable, Sendable {
    let id: UUID
    let sport: Sport
    let name: String
    let start: Date
    let duration: TimeInterval
    let distanceMeters: Double?
    let avgHR: Double?
    /// Which source recorded it. Defaults to Apple Health, the only source before v2.9.
    var origin: Origin = .appleHealth
    /// The activity's own symbol. `sport` is a coarse bucket for load charts, and walks, hikes,
    /// golf and strength all fall into `.other` — whose dumbbell made a walk look like lifting.
    var activitySymbol: String? = nil
    /// The recordings this one was merged from, oldest first, when back-to-back pieces were
    /// joined into one session (run/walk intervals saved as separate workouts). Empty otherwise.
    var segments: [WorkoutSummary] = []

    var icon: String { activitySymbol ?? sport.symbol }
}

/// A rough, transparent recovery read from resting HR and HRV versus the athlete's own baseline.
/// Not a medical signal — the view always shows the reasons behind it.
struct RecoverySignal: Sendable, Equatable {
    enum Level: Sendable, Equatable { case good, normal, caution, unknown }

    let level: Level
    let reasons: [String]

    static let minBaselineDays = 7

    static func evaluate(rhrToday: Double?, rhrBaseline: [Double],
                         hrvRecent: [Double], hrvBaseline: [Double]) -> RecoverySignal {
        var reasons: [String] = []
        var rhrDelta: Double?
        var hrvChange: Double?

        if let today = rhrToday, rhrBaseline.count >= minBaselineDays, let base = Stats.mean(rhrBaseline) {
            let d = today - base
            rhrDelta = d
            let n = Int(abs(d).rounded())
            let rel = n == 0 ? "right at" : "\(n) bpm \(d > 0 ? "above" : "below")"
            reasons.append("Resting HR \(Int(today.rounded())) bpm, \(rel) your 4-week average (\(Int(base.rounded())))")
        }
        if hrvRecent.count >= 3, hrvBaseline.count >= minBaselineDays,
           let recent = Stats.mean(hrvRecent), let base = Stats.mean(hrvBaseline), base > 0 {
            let c = recent / base - 1
            hrvChange = c
            let pct = Int((abs(c) * 100).rounded())
            let rel = pct == 0 ? "in line with" : "\(pct)% \(c > 0 ? "above" : "below")"
            reasons.append("HRV 7-day average \(Int(recent.rounded())) ms, \(rel) your 4-week average")
        }

        guard rhrDelta != nil || hrvChange != nil else {
            return RecoverySignal(level: .unknown, reasons: ["Needs about a week of resting HR or HRV data."])
        }
        let level: Level
        if (rhrDelta ?? 0) >= 5 || (hrvChange ?? 0) <= -0.12 {
            level = .caution
        } else if (rhrDelta ?? 0) <= 0 && (hrvChange ?? 0) >= 0 {
            level = .good
        } else {
            level = .normal
        }
        return RecoverySignal(level: level, reasons: reasons)
    }
}

extension Stats {
    /// Trailing average over the last `days` calendar days (inclusive) for each point.
    static func rollingAverage(_ points: [DailyPoint], days: Int = 7, calendar: Calendar = .current) -> [DailyPoint] {
        let sorted = points.sorted { $0.day < $1.day }
        return sorted.map { p in
            let start = calendar.date(byAdding: .day, value: -(days - 1), to: calendar.startOfDay(for: p.day))!
            let window = sorted.filter { $0.day >= start && $0.day <= p.day }.map(\.value)
            return DailyPoint(day: p.day, value: mean(window) ?? p.value)
        }
    }

    /// Hours per (week, sport), weeks starting per the calendar's locale.
    /// Longer than this and it isn't a session — it's a workout that was started and never
    /// ended, or an import artifact. One of those (900 h in a week) flattens every real week
    /// to nothing, so they're dropped rather than charted. An IRONMAN fits well inside it.
    static let maxSessionHours: Double = 18

    static func isPlausibleSession(_ duration: TimeInterval) -> Bool {
        duration > 0 && duration / 3600 <= maxSessionHours
    }

    /// How many sessions `weeklyLoad` would throw away, so the dashboard can say so out loud
    /// instead of silently dropping the athlete's data.
    static func implausibleCount(_ workouts: [(start: Date, duration: TimeInterval, sport: Sport)]) -> Int {
        workouts.filter { !isPlausibleSession($0.duration) }.count
    }

    static func weeklyLoad(_ workouts: [(start: Date, duration: TimeInterval, sport: Sport)],
                           calendar: Calendar = .current) -> [WeeklyLoad] {
        var buckets: [Date: [Sport: Double]] = [:]
        for w in workouts where isPlausibleSession(w.duration) {
            guard let week = calendar.dateInterval(of: .weekOfYear, for: w.start)?.start else { continue }
            buckets[week, default: [:]][w.sport, default: 0] += w.duration / 3600
        }
        return buckets.keys.sorted().flatMap { week in
            Sport.allCases.compactMap { sport in
                guard let h = buckets[week]?[sport], h > 0 else { return nil }
                return WeeklyLoad(weekStart: week, sport: sport, hours: h)
            }
        }
    }
}
