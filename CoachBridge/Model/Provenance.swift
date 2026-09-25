import Foundation

/// Where a workout came from. With more than one source (Apple Health, FIT files), the same
/// ride can arrive twice — the bike computer's file and the copy Garmin Connect synced into
/// Health — and every total that counts it twice is wrong.
struct Origin: Hashable, Sendable {
    enum Kind: String, Codable, Sendable {
        case appleHealth, fitFile, demo
    }

    var kind: Kind
    /// What recorded it, when known: "Apple Watch", "Garmin Connect", "Edge 540".
    var name: String?

    static let appleHealth = Origin(kind: .appleHealth)
    static let demo = Origin(kind: .demo)

    var label: String {
        switch kind {
        case .appleHealth: return name.map { "Apple Health · \($0)" } ?? "Apple Health"
        case .fitFile: return name.map { "FIT file · \($0)" } ?? "FIT file"
        case .demo: return "Demo"
        }
    }
}

/// How an HRV number was computed. Apple Health stores SDNN; Whoop, Garmin and Oura report
/// RMSSD. The two aren't interchangeable — the same night gives different numbers — so a
/// baseline must only ever be built from one, and whoever reads the number must know which.
enum HRVMethod: String, Codable, Sendable {
    case sdnn, rmssd

    var label: String { self == .sdnn ? "SDNN" : "RMSSD" }
}

/// Merges workouts from several sources into one list with each session counted once.
enum WorkoutReconciler {
    /// Two records are one session when they're the same sport (or one side couldn't tell),
    /// start within 10 minutes of each other, and last about as long — within 15%, or 10
    /// minutes for short sessions. Loose enough for clock drift and auto-pause differences
    /// between devices; tight enough that a morning run and an evening run stay apart.
    static func isSameSession(_ a: WorkoutSummary, _ b: WorkoutSummary) -> Bool {
        guard a.sport == b.sport || a.sport == .other || b.sport == .other else { return false }
        guard abs(a.start.timeIntervalSince(b.start)) <= 10 * 60 else { return false }
        let tolerance = max(10 * 60, 0.15 * max(a.duration, b.duration))
        return abs(a.duration - b.duration) <= tolerance
    }

    /// The copy to keep: the one that says more (distance, heart rate, a real sport), and on a
    /// tie the FIT file, which is the device's own recording rather than a synced copy.
    static func richer(_ a: WorkoutSummary, _ b: WorkoutSummary) -> WorkoutSummary {
        func score(_ w: WorkoutSummary) -> Int {
            (w.distanceMeters != nil ? 2 : 0) + (w.avgHR != nil ? 2 : 0) + (w.sport != .other ? 1 : 0)
                + (w.origin.kind == .fitFile ? 1 : 0)
        }
        return score(b) > score(a) ? b : a
    }

    /// All sources together, newest first, each session once.
    static func merged(_ lists: [[WorkoutSummary]]) -> [WorkoutSummary] {
        var out: [WorkoutSummary] = []
        for w in lists.joined().sorted(by: { $0.start < $1.start }) {
            if let i = out.lastIndex(where: { isSameSession($0, w) }) {
                out[i] = richer(out[i], w)
            } else {
                out.append(w)
            }
        }
        return out.sorted { $0.start > $1.start }
    }
}
