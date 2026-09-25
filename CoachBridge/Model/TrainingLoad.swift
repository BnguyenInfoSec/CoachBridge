import Foundation

/// Fitness, fatigue and form — the performance-management model (CTL, ATL, TSB) used by
/// TrainingPeaks and intervals.icu — from the workouts the app already has.
///
/// Each workout gets a training-stress score. Workouts carry only totals (no second-by-second
/// data), so stress comes from average heart rate against threshold (hrTSS). That's an
/// estimate — intervals average out — and the app always says how it was computed:
///   • average HR and a threshold HR: hours × (avgHR / LTHR)² × 100
///   • average HR, no threshold: the same against a typical 165 bpm, and the app says so
///   • no heart rate at all: a flat 50 per hour, what a steady endurance hour scores
///
/// Fitness is the 42-day exponentially weighted average of daily stress, fatigue the 7-day one,
/// and form is yesterday's fitness minus yesterday's fatigue — how fresh you are coming into
/// today. Pure, so it's tested.
enum TrainingLoad {
    static let fitnessDays = 42.0
    static let fatigueDays = 7.0
    /// Enough history for the 42-day average to mean something before the first day shown.
    static let warmupDays = 90

    enum Method: String, Sendable {
        case heartRateWithThreshold, heartRateEstimatedThreshold, durationOnly

        var label: String {
            switch self {
            case .heartRateWithThreshold: return "from heart rate against your threshold"
            case .heartRateEstimatedThreshold: return "from heart rate; add your LTHR in Plan settings for a better estimate"
            case .durationOnly: return "from duration only; no heart rate was recorded"
            }
        }
    }

    struct Point: Identifiable, Sendable, Equatable {
        let day: Date
        let stress: Double
        let fitness: Double
        let fatigue: Double
        let form: Double
        var id: Date { day }
    }

    struct Summary: Sendable, Equatable {
        let points: [Point]
        /// The least precise method any counted workout needed.
        let method: Method

        var today: Point? { points.last }

        /// A plain reading of form, in the terms coaches use.
        var formLabel: String {
            guard let f = today?.form else { return "Not enough data" }
            switch f {
            case ..<(-30): return "Very fatigued"
            case -30 ..< -10: return "Building fitness"
            case -10 ..< 5: return "Balanced"
            case 5 ..< 25: return "Fresh"
            default: return "Very fresh — fitness may be slipping"
            }
        }
    }

    /// Training stress for one workout, and how it was worked out.
    static func stress(_ w: WorkoutSummary, lthr: Int?) -> (Double, Method) {
        let hours = max(0, w.duration) / 3600
        guard Stats.isPlausibleSession(w.duration) else { return (0, .durationOnly) }   // a watch left running
        guard let hr = w.avgHR, hr > 0 else { return (hours * 50, .durationOnly) }
        let threshold = Double(lthr ?? 0) > 0 ? Double(lthr!) : 165
        let intensity = min(hr / threshold, 1.2)                     // cap: a bad sensor can't claim 300 TSS/h
        return (hours * intensity * intensity * 100, lthr != nil ? .heartRateWithThreshold : .heartRateEstimatedThreshold)
    }

    /// Daily fitness, fatigue and form from `from` to `to` (inclusive, local days). Pass
    /// workouts from at least `warmupDays` earlier so the averages have settled.
    static func summary(_ workouts: [WorkoutSummary], lthr: Int?, from: Date, to: Date,
                        calendar: Calendar) -> Summary {
        var byDay: [Date: Double] = [:]
        var worst = Method.heartRateWithThreshold
        let order: [Method] = [.heartRateWithThreshold, .heartRateEstimatedThreshold, .durationOnly]
        for w in workouts {
            let (s, m) = stress(w, lthr: lthr)
            byDay[calendar.startOfDay(for: w.start), default: 0] += s
            if order.firstIndex(of: m)! > order.firstIndex(of: worst)! { worst = m }
        }
        guard let first = byDay.keys.min() else { return Summary(points: [], method: worst) }

        var ctl = 0.0, atl = 0.0
        var points: [Point] = []
        var day = min(first, calendar.startOfDay(for: from))
        let last = calendar.startOfDay(for: to)
        let showFrom = calendar.startOfDay(for: from)
        while day <= last {
            let stress = byDay[day] ?? 0
            let form = ctl - atl                                     // coming into today
            ctl += (stress - ctl) / fitnessDays
            atl += (stress - atl) / fatigueDays
            if day >= showFrom {
                points.append(Point(day: day, stress: stress, fitness: ctl, fatigue: atl, form: form))
            }
            day = calendar.date(byAdding: .day, value: 1, to: day)!
        }
        return Summary(points: points, method: worst)
    }
}
