import Foundation

/// The structure of a session on the Watch, independent of WorkoutKit so it can be unit-tested:
/// warm-up, repeated work/recovery intervals, steady blocks, cool-down, each with a target range.
struct WorkoutShape: Equatable, Sendable {
    enum Metric: Equatable, Sendable { case heartRate, power }

    struct Target: Equatable, Sendable {
        let metric: Metric
        let range: ClosedRange<Double>
    }

    struct Step: Equatable, Sendable {
        let minutes: Double
        let target: Target?
        let label: String
    }

    struct Block: Equatable, Sendable {
        let work: Step
        let recovery: Step?
        let iterations: Int
    }

    var warmup: Step?
    var blocks: [Block]
    var cooldown: Step?

    var totalMinutes: Double {
        (warmup?.minutes ?? 0) + (cooldown?.minutes ?? 0)
            + blocks.reduce(0) { $0 + Double($1.iterations) * ($1.work.minutes + ($1.recovery?.minutes ?? 0)) }
    }
}

enum WorkoutShaper {
    /// First "A–B unit" range in a target string ("138–151 bpm (Z2)", "176–186 W intervals").
    static func range(in text: String?, unit: String) -> ClosedRange<Double>? {
        guard let text else { return nil }
        let pattern = #"(\d{2,4})\s*[–-]\s*(\d{2,4})\s*"# + NSRegularExpression.escapedPattern(for: unit)
        guard let re = try? NSRegularExpression(pattern: pattern),
              let m = re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let a = Range(m.range(at: 1), in: text), let b = Range(m.range(at: 2), in: text),
              let lo = Double(text[a]), let hi = Double(text[b]), lo < hi else { return nil }
        return lo...hi
    }

    /// "3×12 → 2×20": the interval set for this point in the phase (first half → first set).
    static func intervals(in detail: String, fraction: Double) -> (reps: Int, minutes: Int)? {
        guard let re = try? NSRegularExpression(pattern: #"(\d+)\s*×\s*(\d+)"#) else { return nil }
        let ns = detail as NSString
        let sets = re.matches(in: detail, range: NSRange(location: 0, length: ns.length)).compactMap { m -> (Int, Int)? in
            guard let r = Int(ns.substring(with: m.range(at: 1))), let mm = Int(ns.substring(with: m.range(at: 2))),
                  (2...10).contains(r), (3...40).contains(mm) else { return nil }
            return (r, mm)
        }
        guard let first = sets.first else { return nil }
        let pick = (fraction >= 0.5 && sets.count > 1) ? sets[1] : first
        return (pick.0, pick.1)
    }

    /// Builds the Watch structure for a session. `hr` / `power` are the easy-effort targets; `work*` the hard ones.
    static func shape(for s: PlanSession, fraction: Double) -> WorkoutShape {
        let total = Double(max(15, s.rx?.durationMin ?? 45))
        let hr = range(in: s.rx?.heartRate, unit: "bpm")
        let power = range(in: s.rx?.power, unit: "W")
        let easyTarget: WorkoutShape.Target? = {
            if s.kind == .bike, let power { return .init(metric: .power, range: power) }
            if let hr { return .init(metric: .heartRate, range: hr) }
            return nil
        }()
        let text = (s.title + " " + s.detail).lowercased()

        // Sweet spot / interval sessions: 10 min warm-up, reps with 5 min easy between, cool-down with what's left.
        if text.contains("sweet spot") || text.contains("intervals"),
           let set = intervals(in: s.detail, fraction: fraction) {
            let ftpWork = s.rx?.power.flatMap { p -> ClosedRange<Double>? in
                // The work range is the one labelled "intervals" when present.
                let parts = p.components(separatedBy: "·")
                return range(in: parts.last, unit: "W") ?? range(in: p, unit: "W")
            }
            let workTarget = ftpWork.map { WorkoutShape.Target(metric: .power, range: $0) }
            let work = WorkoutShape.Step(minutes: Double(set.minutes), target: workTarget, label: "Work")
            let rec = WorkoutShape.Step(minutes: 5, target: nil, label: "Easy spin")
            let warm = WorkoutShape.Step(minutes: 10, target: nil, label: "Warm-up")
            let used = 10 + Double(set.reps) * Double(set.minutes + 5)
            let cool = WorkoutShape.Step(minutes: max(5, total - used), target: nil, label: "Cool-down")
            return WorkoutShape(warmup: warm, blocks: [.init(work: work, recovery: rec, iterations: set.reps)], cooldown: cool)
        }

        // Key run: easy, then the last 15–20 min steady.
        if text.contains("steady") && s.title.lowercased().contains("key") {
            let steady = min(18, total / 3)
            let steadyHR = s.rx?.heartRate.flatMap { h in range(in: h.components(separatedBy: "·").last, unit: "bpm") }
            return WorkoutShape(warmup: nil, blocks: [
                .init(work: .init(minutes: total - steady, target: easyTarget, label: "Easy"), recovery: nil, iterations: 1),
                .init(work: .init(minutes: steady, target: steadyHR.map { .init(metric: .heartRate, range: $0) }, label: "Steady"),
                      recovery: nil, iterations: 1),
            ], cooldown: nil)
        }

        // Everything else: one steady block at the easy target.
        return WorkoutShape(warmup: nil,
                            blocks: [.init(work: .init(minutes: total, target: easyTarget, label: s.title), recovery: nil, iterations: 1)],
                            cooldown: nil)
    }

    /// Stable ID for a scheduled session: changes when the session's content changes, so the Watch copy is replaced.
    static func identity(key: String, session: PlanSession, start: Date) -> String {
        let enc = JSONEncoder()
        enc.outputFormatting = .sortedKeys
        let body = (try? enc.encode(session)).map { String(decoding: $0, as: UTF8.self) } ?? session.title
        return "\(key)|\(Int(start.timeIntervalSince1970))|\(body)"
    }
}
