import Foundation

/// A projected finish time for a race, leg by leg, from the athlete's own recent workouts.
///
/// Workouts carry totals only (distance and time), so this is an estimate, and it says so: every
/// leg names what it was based on, a leg without enough data uses a typical time and is marked
/// as such, and the total is shown as a range. Pure, so it's tested.
///   • Swim: median pace of recent swims of 800 m or more, 3% faster for race effort.
///   • Bike: 75th-percentile speed of recent rides of 45 min or more, adjusted for how hard the
///     distance is raced (an Ironman bike is ridden at training effort, a sprint well above it).
///   • Run: the best recent run of 3 km or more, carried to race distance with Riegel's formula
///     (T₂ = T₁ × (D₂/D₁)^1.06); off the bike, slowed by the usual triathlon run fade.
struct RaceProjection: Equatable, Sendable {
    enum Basis: Equatable, Sendable {
        case yourData(String)
        case typical

        var text: String {
            switch self {
            case .yourData(let s): return s
            case .typical: return "typical time — not enough recent workouts to estimate"
            }
        }
    }

    struct Leg: Equatable, Sendable, Identifiable {
        let sport: SessionKind
        let label: String
        let seconds: TimeInterval
        let basis: Basis
        var id: String { label }
    }

    let legs: [Leg]
    let transitions: TimeInterval

    var total: TimeInterval { legs.reduce(transitions) { $0 + $1.seconds } }
    var legsFromData: Int { legs.filter { if case .yourData = $0.basis { return true } else { return false } }.count }

    /// ±5% when every leg comes from your data, ±10% otherwise.
    var range: ClosedRange<TimeInterval> {
        let spread = legsFromData == legs.count ? 0.05 : 0.10
        return (total * (1 - spread))...(total * (1 + spread))
    }

    // MARK: Race distances

    struct Distances: Equatable, Sendable {
        let swim: Double?, bike: Double?, run: Double?
        let transitions: TimeInterval
        let bikeFactor: Double
        let runFade: Double
    }

    /// Metres, plus how each distance is raced relative to training.
    static func distances(_ e: EventKind) -> Distances? {
        switch e {
        case .ironman: return Distances(swim: 3_800, bike: 180_000, run: 42_195, transitions: 600, bikeFactor: 1.00, runFade: 1.18)
        case .half703: return Distances(swim: 1_900, bike: 90_000, run: 21_097, transitions: 360, bikeFactor: 1.04, runFade: 1.08)
        case .olympic: return Distances(swim: 1_500, bike: 40_000, run: 10_000, transitions: 240, bikeFactor: 1.08, runFade: 1.05)
        case .sprintTri: return Distances(swim: 750, bike: 20_000, run: 5_000, transitions: 180, bikeFactor: 1.10, runFade: 1.04)
        case .marathon: return Distances(swim: nil, bike: nil, run: 42_195, transitions: 0, bikeFactor: 1, runFade: 1)
        case .halfMarathon: return Distances(swim: nil, bike: nil, run: 21_097, transitions: 0, bikeFactor: 1, runFade: 1)
        case .tenK: return Distances(swim: nil, bike: nil, run: 10_000, transitions: 0, bikeFactor: 1, runFade: 1)
        case .ultra: return Distances(swim: nil, bike: nil, run: 50_000, transitions: 0, bikeFactor: 1, runFade: 1)
        case .granFondo: return Distances(swim: nil, bike: 120_000, run: nil, transitions: 0, bikeFactor: 1.02, runFade: 1)
        case .century: return Distances(swim: nil, bike: 160_934, run: nil, transitions: 0, bikeFactor: 1.0, runFade: 1)
        case .general: return nil
        }
    }

    /// Typical age-group paces, for a leg with no data: 2:10/100 m, 28 km/h, 6:00/km.
    static let typicalSwimPer100 = 130.0, typicalBikeMps = 28_000.0 / 3_600, typicalRunPerKm = 360.0

    // MARK: Projection

    static func make(event: EventKind, recent: [WorkoutSummary]) -> RaceProjection? {
        guard let d = distances(event) else { return nil }
        var legs: [Leg] = []
        let triathlon = d.swim != nil && d.run != nil

        if let swim = d.swim {
            let samples = recent.filter { $0.sport == .swim && ($0.distanceMeters ?? 0) >= 800 && $0.duration > 0 }
                .map { $0.duration / ($0.distanceMeters! / 100) }
                .filter { (60...300).contains($0) }                              // 1:00–5:00 per 100 m
            if let median = Self.median(samples) {
                let per100 = median * 0.97
                legs.append(Leg(sport: .swim, label: "Swim", seconds: per100 * swim / 100,
                                basis: .yourData("\(samples.count) recent swim\(samples.count == 1 ? "" : "s"), \(Self.pace(per100))/100 m")))
            } else {
                legs.append(Leg(sport: .swim, label: "Swim", seconds: typicalSwimPer100 * swim / 100, basis: .typical))
            }
        }

        if let bike = d.bike {
            let speeds = recent.filter { $0.sport == .bike && $0.duration >= 45 * 60 && ($0.distanceMeters ?? 0) > 0 }
                .map { $0.distanceMeters! / $0.duration }
                .filter { (4...14).contains($0) }                                // 14–50 km/h
            if let p75 = Self.percentile(speeds, 0.75) {
                let mps = p75 * d.bikeFactor
                legs.append(Leg(sport: .bike, label: "Bike", seconds: bike / mps,
                                basis: .yourData("\(speeds.count) recent ride\(speeds.count == 1 ? "" : "s"), \(String(format: "%.1f", mps * 3.6)) km/h")))
            } else {
                legs.append(Leg(sport: .bike, label: "Bike", seconds: bike / typicalBikeMps, basis: .typical))
            }
        }

        if let run = d.run {
            let efforts = recent.filter { $0.sport == .run && ($0.distanceMeters ?? 0) >= 3_000 && $0.duration > 0 }
                .compactMap { w -> TimeInterval? in
                    let perKm = w.duration / (w.distanceMeters! / 1_000)
                    guard (150...600).contains(perKm) else { return nil }         // 2:30–10:00 per km
                    return w.duration * pow(run / w.distanceMeters!, 1.06)
                }
            if let best = efforts.min() {
                let t = best * (triathlon ? d.runFade : 1)
                legs.append(Leg(sport: .run, label: "Run", seconds: t,
                                basis: .yourData("best of \(efforts.count) recent run\(efforts.count == 1 ? "" : "s")"
                                                 + (triathlon ? ", slowed for running off the bike" : "")
                                                 + ", \(Self.pace(t / (run / 1_000)))/km")))
            } else {
                legs.append(Leg(sport: .run, label: "Run", seconds: typicalRunPerKm * run / 1_000 * (triathlon ? d.runFade : 1), basis: .typical))
            }
        }
        return RaceProjection(legs: legs, transitions: d.transitions)
    }

    // MARK: Helpers

    static func median(_ xs: [Double]) -> Double? { percentile(xs, 0.5) }

    static func percentile(_ xs: [Double], _ p: Double) -> Double? {
        guard !xs.isEmpty else { return nil }
        let s = xs.sorted()
        let i = Int((Double(s.count - 1) * p).rounded())
        return s[min(max(i, 0), s.count - 1)]
    }

    /// "1:52" from seconds.
    static func pace(_ seconds: Double) -> String {
        let s = Int(seconds.rounded())
        return "\(s / 60):" + String(format: "%02d", s % 60)
    }

    /// "5:42" or "0:58" (hours:minutes) from seconds.
    static func clock(_ seconds: TimeInterval) -> String {
        let m = Int((seconds / 60).rounded())
        return "\(m / 60):" + String(format: "%02d", m % 60)
    }
}
