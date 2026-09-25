import Foundation

/// A lasting change to the plan, made from the Coach chat ("move the long ride to Sunday for the
/// rest of Base 1", "one lift a week through December"). Rules apply to a date range, optionally
/// only on certain weekdays, and are listed — and removable — in Plan settings.
struct PlanRule: Codable, Identifiable, Hashable, Sendable {
    enum Action: Codable, Hashable, Sendable {
        /// Ride instead of run, swim instead of ride, …
        case swapSport(from: SessionKind, to: SessionKind)
        /// Move a weekday's sessions to another weekday of the same week (0 = Sun … 6 = Sat).
        case moveWeekday(from: Int, to: Int)
        /// Remove sessions of a kind (the second lift, the optional spin, …).
        case dropKind(SessionKind)
        /// Add a session every week.
        case addWeekly(kind: SessionKind, weekday: Int, durationMin: Int, title: String, detail: String)
        /// Shorten or lengthen everything (60 = 60% of planned).
        case scaleDuration(percent: Int)
        /// Put rides on the trainer (or back outside).
        case indoorRides(Bool)
    }

    var id: UUID = UUID()
    var action: Action
    /// Inclusive "yyyy-MM-dd" bounds.
    var startDate: String
    var endDate: String
    /// Limit to these weekdays (0 = Sun … 6 = Sat). nil = every day in range.
    var weekdays: [Int]?
    /// Why, in Claude's words — shown in the plan and in settings.
    var note: String
    var createdAt: Date = .now

    func covers(_ iso: String, jsDay: Int) -> Bool {
        guard iso >= startDate, iso <= endDate else { return false }
        if let w = weekdays, !w.contains(jsDay) { return false }
        return true
    }

    /// One line for the rules list and for Claude's context.
    var summary: String {
        let names = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
        let what: String
        switch action {
        case .swapSport(let f, let t): what = "\(f.label) → \(t.label)"
        case .moveWeekday(let f, let t): what = "move \(names[f]) sessions to \(names[t])"
        case .dropKind(let k): what = "no \(k.label.lowercased()) sessions"
        case .addWeekly(let k, let wd, let m, let title, _): what = "add \(names[wd]) \(k.label.lowercased()) — \(title), \(m) min"
        case .scaleDuration(let p): what = "\(p)% of planned duration"
        case .indoorRides(let on): what = on ? "rides on the trainer" : "rides outdoors"
        }
        let days = weekdays.map { " (\($0.map { names[$0] }.joined(separator: "/")))" } ?? ""
        return "\(what)\(days) · \(startDate) → \(endDate)"
    }
}

/// Applies rules to a week of planned sessions. Pure, so it's unit-tested.
enum RuleEngine {
    /// `days` is Monday-first. `isoFor` and `jsDayFor` map an index to that day's date info.
    static func apply(_ rules: [PlanRule], to days: [[PlanSession]],
                      isoFor: (Int) -> String, jsDayFor: (Int) -> Int) -> [[PlanSession]] {
        var out = days
        for rule in rules.sorted(by: { $0.createdAt < $1.createdAt }) {
            switch rule.action {
            case .moveWeekday(let from, let to):
                for i in 0..<out.count where jsDayFor(i) == from && rule.covers(isoFor(i), jsDay: from) {
                    guard let target = (0..<out.count).first(where: { jsDayFor($0) == to }) else { continue }
                    let moving = out[i].filter { $0.kind != .rest && !$0.addedByAthlete }
                    guard !moving.isEmpty else { continue }
                    out[i] = out[i].filter { $0.kind == .rest || $0.addedByAthlete }
                    if out[i].isEmpty { out[i] = [PlanSession(kind: .rest, title: "Off", detail: rule.note)] }
                    out[target] += moving.map { note($0, rule) }
                }

            case .addWeekly(let kind, let weekday, let minutes, let title, let detail):
                for i in 0..<out.count where jsDayFor(i) == weekday && rule.covers(isoFor(i), jsDay: weekday) {
                    var s = PlanSession(kind: kind, title: title, detail: detail)
                    s.rx = Prescription(durationMin: minutes)
                    out[i] = out[i].filter { $0.kind != .rest } + [note(s, rule)]
                }

            default:
                for i in 0..<out.count where rule.covers(isoFor(i), jsDay: jsDayFor(i)) {
                    out[i] = transform(out[i], rule)
                }
            }
        }
        return out
    }

    private static func transform(_ sessions: [PlanSession], _ rule: PlanRule) -> [PlanSession] {
        switch rule.action {
        case .swapSport(let from, let to):
            return sessions.map { s in
                guard s.kind == from, !s.addedByAthlete else { return s }
                var out = s
                out.kind = to
                out.rx?.heartRate = nil      // targets are re-derived for the new sport
                out.rx?.power = nil
                out.rx?.pace = nil
                out.rx?.intensity = nil
                return note(out, rule)
            }
        case .dropKind(let kind):
            let kept = sessions.filter { $0.kind != kind || $0.addedByAthlete }
            return kept.isEmpty ? [PlanSession(kind: .rest, title: "Off", detail: rule.note)] : kept
        case .scaleDuration(let percent):
            let f = Double(max(10, min(200, percent))) / 100
            return sessions.map { s in
                guard !s.addedByAthlete, let m = s.rx?.durationMin else { return s }
                var out = s
                out.rx?.durationMin = max(10, Int((Double(m) * f).rounded()))
                out.rx?.distance = nil
                return note(out, rule)
            }
        case .indoorRides(let on):
            return sessions.map { s in
                guard s.kind == .bike, !s.addedByAthlete else { return s }
                var out = s
                out.indoor = on
                out.rx = nil          // targets are rebuilt for the trainer
                return note(out, rule)
            }
        case .moveWeekday, .addWeekly:
            return sessions
        }
    }

    private static func note(_ s: PlanSession, _ rule: PlanRule) -> PlanSession {
        var out = s
        let mark = "Coach rule: \(rule.note)"
        out.detail = out.detail.isEmpty ? mark : out.detail + " · " + mark
        return out
    }
}

/// Stores the rules on the phone.
@MainActor
final class RuleStore: ObservableObject {
    @Published private(set) var rules: [PlanRule] = []

    private static var url: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("plan-rules.json")
    }

    init() { load() }

    func add(_ list: [PlanRule]) {
        rules += list
        persist()
    }

    func delete(_ rule: PlanRule) {
        rules.removeAll { $0.id == rule.id }
        persist()
    }

    func removeAll() {
        rules = []
        persist()
    }

    /// Drops rules whose range has passed.
    func prune(before iso: String) {
        let before = rules.count
        rules.removeAll { $0.endDate < iso }
        if rules.count != before { persist() }
    }

    private func load() {
        guard let data = try? Data(contentsOf: Self.url) else { return }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        rules = (try? dec.decode([PlanRule].self, from: data)) ?? []
    }

    private func persist() {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        guard let data = try? enc.encode(rules) else { return }
        try? FileManager.default.createDirectory(at: Self.url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: Self.url, options: [.atomic, .completeFileProtection])
    }
}
