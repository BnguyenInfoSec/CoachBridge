import Foundation

/// Joins back-to-back recordings of one outing into a single workout.
///
/// Run/walk intervals recorded on the watch as separate workouts (Sat Sep 26: run, walk, run,
/// walk…) showed up as four sessions: four rows, four "how did it feel?" prompts, and a plan
/// comparison that matched a 20-minute piece against a 60-minute run.
enum WorkoutSegments {
    /// Longest pause between one piece ending and the next starting that still counts as the
    /// same outing. Long enough to stop at a light or switch the watch's workout type; short
    /// enough that a run and an evening walk stay apart.
    static let maxGap: TimeInterval = 10 * 60

    private static let onFoot: Set<String> = ["figure.run", "figure.walk", "figure.hiking"]

    /// Running, walking and hiking join each other. Anything else joins only its own kind, so a
    /// brick (bike then run) stays two sessions — the transition is the point of it.
    static func canJoin(_ a: WorkoutSummary, _ b: WorkoutSummary) -> Bool {
        if isOnFoot(a) && isOnFoot(b) { return true }
        return a.sport == b.sport && a.icon == b.icon
    }

    static func isOnFoot(_ w: WorkoutSummary) -> Bool {
        w.sport == .run || onFoot.contains(w.icon)
    }

    /// Newest first in, newest first out, with each run of joinable pieces merged into one.
    static func consolidated(_ workouts: [WorkoutSummary]) -> [WorkoutSummary] {
        var groups: [[WorkoutSummary]] = []
        for w in workouts.sorted(by: { $0.start < $1.start }) {
            if let last = groups.last?.last,
               canJoin(last, w),
               w.start.timeIntervalSince(last.start.addingTimeInterval(last.duration)) <= maxGap,
               w.start >= last.start {
                groups[groups.count - 1].append(w)
            } else {
                groups.append([w])
            }
        }
        return groups.map { $0.count == 1 ? $0[0] : merge($0) }.sorted { $0.start > $1.start }
    }

    /// One workout from several pieces, oldest first. Keeps the first piece's id, so a feel or
    /// coach's note already saved against it still belongs to the merged session.
    static func merge(_ pieces: [WorkoutSummary]) -> WorkoutSummary {
        let parts = pieces.flatMap { $0.segments.isEmpty ? [$0] : $0.segments }
        let first = parts[0]
        let duration = parts.reduce(0) { $0 + $1.duration }

        // The sport and symbol are whatever took the most time: a run with walk breaks is a run.
        var bySport: [Sport: TimeInterval] = [:]
        var bySymbol: [String: TimeInterval] = [:]
        for p in parts {
            bySport[p.sport, default: 0] += p.duration
            bySymbol[p.icon, default: 0] += p.duration
        }
        let sport = bySport.max { $0.value < $1.value || ($0.value == $1.value && $0.key.rawValue > $1.key.rawValue) }!.key
        let symbol = bySymbol.max { $0.value < $1.value || ($0.value == $1.value && $0.key > $1.key) }!.key

        let distances = parts.compactMap(\.distanceMeters)
        let hrWeighted = parts.compactMap { p in p.avgHR.map { ($0, p.duration) } }
        let hrTime = hrWeighted.reduce(0) { $0 + $1.1 }
        let avgHR = hrTime > 0 ? hrWeighted.reduce(0) { $0 + $1.0 * $1.1 } / hrTime : nil

        return WorkoutSummary(id: first.id, sport: sport, name: name(for: parts),
                              start: first.start, duration: duration,
                              distanceMeters: distances.isEmpty ? nil : distances.reduce(0, +),
                              avgHR: avgHR, origin: first.origin, activitySymbol: symbol,
                              segments: parts)
    }

    /// "Run/walk" for the common case; otherwise the pieces' own names, deduplicated in order.
    static func name(for parts: [WorkoutSummary]) -> String {
        var names: [String] = []
        for p in parts where !names.contains(p.name) { names.append(p.name) }
        if names.count == 1 { return names[0] }
        let hasRun = parts.contains { $0.icon == "figure.run" || $0.sport == .run }
        let hasWalk = parts.contains { $0.icon == "figure.walk" || $0.icon == "figure.hiking" }
        if hasRun && hasWalk { return "Run/walk" }
        return names.prefix(3).joined(separator: " + ")
    }

    /// One line per piece for the coach, so run/walk intervals read as intervals.
    static func describe(_ w: WorkoutSummary) -> String? {
        guard w.segments.count > 1 else { return nil }
        let pieces = w.segments.map { p in "\(p.name.lowercased()) \(Int((p.duration / 60).rounded())) min" }
        return "Recorded as \(w.segments.count) back-to-back pieces: " + pieces.joined(separator: ", ")
    }
}
