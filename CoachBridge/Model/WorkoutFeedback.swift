import Combine
import Foundation

/// How the session actually felt, in the athlete's own words and numbers. Asked once after every
/// recorded workout, because the numbers don't say whether 140 bpm was easy that day or a fight.
struct WorkoutFeel: Codable, Hashable, Sendable {
    /// How long after a workout the app asks how it felt, on the phone and on the watch. A guess.
    static let askWindow: TimeInterval = 48 * 3600

    /// Borg CR10 perceived exertion. 1 is barely moving, 10 is everything you had.
    var rpe: Int
    var mood: Mood
    /// Anything the athlete wants to add. Optional, and usually empty.
    var note: String = ""
    var answeredAt: Date = .now

    enum Mood: String, Codable, CaseIterable, Identifiable, Sendable {
        case great, good, okay, tough, awful

        var id: String { rawValue }

        var label: String {
            switch self {
            case .great: return "Felt great"
            case .good: return "Good"
            case .okay: return "Okay"
            case .tough: return "Tough"
            case .awful: return "Awful"
            }
        }

        var symbol: String {
            switch self {
            case .great: return "face.smiling.inverse"
            case .good: return "face.smiling"
            case .okay: return "face.dashed"
            case .tough: return "exclamationmark.triangle"
            case .awful: return "xmark.octagon"
            }
        }
    }

    /// The scale, described the way it's described to the athlete.
    static func rpeLabel(_ v: Int) -> String {
        switch v {
        case ...2: return "Very easy — recovery pace"
        case 3: return "Easy — could do this all day"
        case 4: return "Steady — full sentences"
        case 5: return "Moderate — short sentences"
        case 6: return "Somewhat hard — breathing noticeably"
        case 7: return "Hard — a few words at a time"
        case 8: return "Very hard — holding on"
        case 9: return "Near maximal"
        default: return "Everything I had"
        }
    }

    var summary: String {
        var s = "RPE \(rpe)/10, \(mood.label.lowercased())"
        let n = note.trimmingCharacters(in: .whitespacesAndNewlines)
        if !n.isEmpty { s += " — \"\(n)\"" }
        return s
    }
}

/// The coach's written reaction to one session. Generated once and kept, so reopening a workout
/// costs nothing and the note doesn't quietly change under the athlete.
struct CoachNote: Codable, Hashable, Sendable {
    /// One line, the thing to take away.
    var headline: String
    /// What actually happened, in two or three sentences.
    var body: String
    /// How this session moves them toward the goal they wrote down.
    var towardGoal: String?
    /// Only set when something is worth watching — a spike, a mismatch, a pattern.
    var watchFor: String?
    var model: String
    var createdAt: Date
}

/// One workout's record: how it felt, and what the coach said about it.
struct WorkoutEntry: Codable, Hashable, Sendable, Identifiable {
    /// The HealthKit workout UUID.
    var id: UUID
    /// Kept so the entry still means something after the workout leaves the 8-week window.
    var dateISO: String
    var sport: Sport
    var feel: WorkoutFeel?
    var note: CoachNote?

    var isAnswered: Bool { feel != nil }
}

// MARK: - Planned versus actual

/// The objective comparison between what the plan asked for and what the watch recorded.
/// Pure and local: no API key, no network, always available — the coach's note sits on top of it.
struct SessionCompare: Sendable, Equatable {
    enum Status: String, Sendable, Equatable { case onTarget, under, over, unknown }

    struct Line: Identifiable, Sendable, Equatable {
        let label: String
        let planned: String
        let actual: String
        /// "12 min short", "8 bpm over", or "" when it landed in the window.
        let delta: String
        let status: Status
        var id: String { label }
    }

    let lines: [Line]
    let headline: String
    /// True when there was a planned session of this sport to compare against at all.
    let hadPlan: Bool

    static let unplanned = SessionCompare(
        lines: [], headline: "Not on the plan — an extra session.", hadPlan: false)

    /// Anything outside its window, worst first, for the coach prompt.
    var misses: [Line] { lines.filter { $0.status == .under || $0.status == .over } }

    /// Builds the comparison. `planned` is the plan's session for that day and sport, if there was
    /// one; `avgHR` and `avgPower` come from the workout's own samples.
    static func make(planned: PlanSession?,
                     actualSeconds: TimeInterval,
                     avgHR: Double?,
                     avgPower: Double?) -> SessionCompare {
        guard let planned, let rx = planned.rx else { return .unplanned }
        var lines: [Line] = []

        if let want = rx.durationMin, want > 0 {
            let got = actualSeconds / 60
            // Within 10% either way is the session as prescribed — nobody rides to the second.
            let tolerance = max(5.0, Double(want) * 0.10)
            let diff = got - Double(want)
            let status: Status = abs(diff) <= tolerance ? .onTarget : (diff < 0 ? .under : .over)
            lines.append(Line(
                label: "Duration",
                planned: "\(want) min",
                actual: "\(Int(got.rounded())) min",
                delta: status == .onTarget ? "" : "\(Int(abs(diff).rounded())) min \(diff < 0 ? "short" : "long")",
                status: status))
        }

        if let window = WorkoutShaper.range(in: rx.heartRate, unit: "bpm") {
            lines.append(metric(label: "Avg heart rate", window: window, actual: avgHR, unit: "bpm"))
        }
        if let window = WorkoutShaper.range(in: rx.power, unit: "W") {
            lines.append(metric(label: "Avg power", window: window, actual: avgPower, unit: "W"))
        }

        return SessionCompare(lines: lines, headline: headline(for: lines), hadPlan: true)
    }

    private static func metric(label: String, window: ClosedRange<Double>,
                               actual: Double?, unit: String) -> Line {
        let planned = "\(Int(window.lowerBound))–\(Int(window.upperBound)) \(unit)"
        guard let actual else {
            return Line(label: label, planned: planned, actual: "not recorded", delta: "", status: .unknown)
        }
        let shown = "\(Int(actual.rounded())) \(unit)"
        if window.contains(actual) {
            return Line(label: label, planned: planned, actual: shown, delta: "", status: .onTarget)
        }
        let off = actual < window.lowerBound ? window.lowerBound - actual : actual - window.upperBound
        return Line(label: label, planned: planned, actual: shown,
                    delta: "\(Int(off.rounded())) \(unit) \(actual < window.lowerBound ? "under" : "over")",
                    status: actual < window.lowerBound ? .under : .over)
    }

    private static func headline(for lines: [Line]) -> String {
        let judged = lines.filter { $0.status != .unknown }
        guard !judged.isEmpty else {
            // Having no targets and having targets nothing was recorded for are different
            // problems, and the second one is the athlete's watch, not their plan.
            return lines.isEmpty
                ? "Nothing to compare — the session had no targets."
                : "Nothing to compare — none of those targets were recorded."
        }
        let off = judged.filter { $0.status != .onTarget }
        if off.isEmpty { return "On plan." }
        if off.count == judged.count { return "Off plan on every target." }
        return "On plan apart from \(off.map { $0.label.lowercased() }.joined(separator: " and "))."
    }

    /// Flat text for the model, so the coach reacts to the same numbers the athlete is looking at.
    var promptText: String {
        guard hadPlan else { return "This session wasn't on the plan — the athlete added it." }
        guard !lines.isEmpty else { return "The planned session had no numeric targets to compare against." }
        return lines.map { l in
            "- \(l.label): planned \(l.planned), actual \(l.actual)\(l.delta.isEmpty ? " (in the window)" : " (\(l.delta))")"
        }.joined(separator: "\n")
    }
}

// MARK: - Storage

/// Every workout's feel and coach note, kept on the phone. Keyed by the HealthKit workout UUID,
/// so it survives the workout dropping out of the dashboard's 8-week window.
@MainActor
final class WorkoutJournal: ObservableObject {
    @Published private(set) var entries: [UUID: WorkoutEntry] = [:]

    private static var url: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("workout-journal.json")
    }

    init() { load() }

    func entry(for id: UUID) -> WorkoutEntry? { entries[id] }
    func feel(for id: UUID) -> WorkoutFeel? { entries[id]?.feel }
    func note(for id: UUID) -> CoachNote? { entries[id]?.note }

    func save(feel: WorkoutFeel, for w: WorkoutSummary, dateISO: String) {
        var e = entries[w.id] ?? WorkoutEntry(id: w.id, dateISO: dateISO, sport: w.sport)
        e.feel = feel
        entries[w.id] = e
        persist()
    }

    func save(note: CoachNote, for w: WorkoutSummary, dateISO: String) {
        var e = entries[w.id] ?? WorkoutEntry(id: w.id, dateISO: dateISO, sport: w.sport)
        e.note = note
        entries[w.id] = e
        persist()
    }

    func clearNote(for id: UUID) {
        entries[id]?.note = nil
        persist()
    }

    /// The most recent answered sessions, newest first — what the weekly adjustment should see.
    func recent(limit: Int = 10) -> [WorkoutEntry] {
        entries.values
            .filter { $0.feel != nil }
            .sorted { ($0.feel?.answeredAt ?? .distantPast) > ($1.feel?.answeredAt ?? .distantPast) }
            .prefix(limit)
            .map { $0 }
    }

    /// Recent perceived effort as a line for the coach: the numbers alone hide a hard week.
    func effortSummary(limit: Int = 8) -> String? {
        let recent = recent(limit: limit)
        guard !recent.isEmpty else { return nil }
        let parts = recent.compactMap { e -> String? in
            guard let f = e.feel else { return nil }
            return "\(e.dateISO) \(e.sport.rawValue): RPE \(f.rpe), \(f.mood.rawValue)"
        }
        return "How recent sessions felt, newest first: " + parts.joined(separator: "; ")
    }

    /// Drops entries older than a year so the file can't grow without bound.
    func prune(before iso: String) {
        let before = entries.count
        entries = entries.filter { $0.value.dateISO >= iso }
        if entries.count != before { persist() }
    }

    private func load() {
        guard let data = try? Data(contentsOf: Self.url) else { return }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        let list = (try? dec.decode([WorkoutEntry].self, from: data)) ?? []
        entries = Dictionary(uniqueKeysWithValues: list.map { ($0.id, $0) })
    }

    private func persist() {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        guard let data = try? enc.encode(Array(entries.values)) else { return }
        try? FileManager.default.createDirectory(at: Self.url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        try? data.write(to: Self.url, options: [.atomic, .completeFileProtection])
    }
}
