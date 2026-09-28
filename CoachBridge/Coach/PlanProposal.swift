import Foundation

/// A change to the plan that Claude proposes from the Coach chat. Nothing is applied until
/// the athlete taps Apply.
struct PlanProposal: Identifiable, Equatable, Sendable {
    struct DayChange: Equatable, Sendable {
        let date: String
        let reason: String
        let sessions: [PlanSession]
    }

    let id = UUID()
    let summary: String
    let rules: [PlanRule]
    let days: [DayChange]

    var isEmpty: Bool { rules.isEmpty && days.isEmpty }

    /// Human-readable lines for the confirmation card.
    var bullets: [String] {
        rules.map { "Lasting: \($0.summary) — \($0.note)" }
            + days.map { d in
                let what = d.sessions.filter { $0.kind != .rest }.map(\.title).joined(separator: " + ")
                return "\(d.date): \(what.isEmpty ? "rest" : what) — \(d.reason)"
            }
    }
}

/// The tool the Coach chat can call, and the validation of what comes back.
enum PlanChangeTool {
    static let name = "change_plan"
    static let maxRules = 8
    static let maxDays = 60

    static var schema: [String: Any] {
        let kinds = SessionKind.allCases.map(\.rawValue)
        let rule: [String: Any] = [
            "type": "object",
            "properties": [
                "type": ["type": "string", "enum": ["swap_sport", "move_weekday", "drop_kind", "add_weekly", "scale_duration", "indoor_rides"],
                         "description": "swap_sport: change one sport to another. move_weekday: move a weekday's sessions to another weekday. drop_kind: remove sessions of a kind. add_weekly: add a weekly session. scale_duration: shorten or lengthen everything."],
                "start_date": ["type": "string", "description": "YYYY-MM-DD, first day the rule applies"],
                "end_date": ["type": "string", "description": "YYYY-MM-DD, last day (use the phase end for \"rest of this phase\")"],
                "weekdays": ["type": "array", "items": ["type": "integer"], "description": "0 = Sunday … 6 = Saturday; leave out for every day"],
                "note": ["type": "string", "description": "Short reason, shown to the athlete"],
                "from_kind": ["type": "string", "enum": kinds],
                "to_kind": ["type": "string", "enum": kinds],
                "from_weekday": ["type": "integer"],
                "to_weekday": ["type": "integer"],
                "kind": ["type": "string", "enum": kinds],
                "weekday": ["type": "integer"],
                "duration_min": ["type": "integer"],
                "title": ["type": "string"],
                "detail": ["type": "string"],
                "percent": ["type": "integer", "description": "60 = 60% of planned duration"],
                "indoor": ["type": "boolean", "description": "for indoor_rides: true = trainer, false = back outdoors"],
            ],
            "required": ["type", "start_date", "end_date", "note"],
        ]
        let session: [String: Any] = [
            "type": "object",
            "properties": [
                "kind": ["type": "string", "enum": kinds],
                "title": ["type": "string"],
                "detail": ["type": "string"],
                "duration_min": ["type": "integer"],
                "intensity": ["type": "string"],
                "heart_rate": ["type": "string"],
                "power": ["type": "string"],
                "fuel_during": ["type": "string"],
                "start_time": ["type": "string", "description": "HH:mm"],
                "indoor": ["type": "boolean", "description": "ride on the smart trainer"],
            ],
            "required": ["kind", "title"],
        ]
        return [
            "name": name,
            "description": "Change the athlete's training plan. Use days for one-off changes to specific dates, and rules for anything lasting (the rest of a phase, every Wednesday from now on). Nothing is applied until the athlete approves it.",
            "input_schema": [
                "type": "object",
                "properties": [
                    "summary": ["type": "string", "description": "One or two sentences describing the change and why."],
                    "rules": ["type": "array", "items": rule],
                    "days": [
                        "type": "array",
                        "items": [
                            "type": "object",
                            "properties": [
                                "date": ["type": "string", "description": "YYYY-MM-DD"],
                                "reason": ["type": "string"],
                                "sessions": ["type": "array", "items": session],
                            ],
                            "required": ["date", "reason", "sessions"],
                        ],
                    ],
                ],
                "required": ["summary"],
            ],
        ]
    }

    // MARK: Parsing

    private struct Output: Decodable {
        struct Rule: Decodable {
            let type: String
            let startDate: String
            let endDate: String
            let weekdays: [Int]?
            let note: String
            let fromKind: String?
            let toKind: String?
            let fromWeekday: Int?
            let toWeekday: Int?
            let kind: String?
            let weekday: Int?
            let durationMin: Int?
            let title: String?
            let detail: String?
            let percent: Int?
            let indoor: Bool?
        }
        struct Session: Decodable {
            let kind: String
            let title: String
            let detail: String?
            let durationMin: Int?
            let intensity: String?
            let heartRate: String?
            let power: String?
            let fuelDuring: String?
            let startTime: String?
            let indoor: Bool?
        }
        struct Day: Decodable {
            let date: String
            let reason: String
            let sessions: [Session]
        }
        let summary: String
        let rules: [Rule]?
        let days: [Day]?
    }

    enum ParseError: LocalizedError {
        case unreadable
        var errorDescription: String? { "Couldn't read Claude's proposed change." }
    }

    /// Decodes and sanity-checks a proposal: dates inside `bounds` (the athlete's own plan) and
    /// not in the past,
    /// sane weekdays, durations and percentages.
    static func parse(_ data: Data, todayISO: String, bounds: ClosedRange<String>,
                      now: Date = .now) throws -> PlanProposal {
        let dec = JSONDecoder()
        dec.keyDecodingStrategy = .convertFromSnakeCase
        guard let out = try? dec.decode(Output.self, from: data) else { throw ParseError.unreadable }

        // Model output is untrusted too (OWASP LLM05): it's shown, written to the calendar and
        // Watch, and fed back into later prompts. One clean line, no hidden characters or tags.
        func clip(_ s: String?, _ n: Int) -> String? {
            guard let s else { return nil }
            let c = PromptSafety.inline(s, max: n - 1)
            return c.isEmpty ? nil : c
        }
        func valid(_ iso: String?) -> String? {
            guard let iso, iso.count == 10, iso >= bounds.lowerBound, iso <= bounds.upperBound else { return nil }
            return iso
        }
        func weekday(_ i: Int?) -> Int? { (i.map { (0...6).contains($0) } ?? false) ? i : nil }

        let rules: [PlanRule] = (out.rules ?? []).prefix(maxRules).compactMap { r in
            guard let start = valid(max(r.startDate, todayISO)), let end = valid(r.endDate), end >= start,
                  let note = clip(r.note, 160) else { return nil }
            let action: PlanRule.Action?
            switch r.type {
            case "swap_sport":
                if let f = r.fromKind.flatMap(SessionKind.init(rawValue:)), let t = r.toKind.flatMap(SessionKind.init(rawValue:)) {
                    action = .swapSport(from: f, to: t)
                } else { action = nil }
            case "move_weekday":
                if let f = weekday(r.fromWeekday), let t = weekday(r.toWeekday), f != t {
                    action = .moveWeekday(from: f, to: t)
                } else { action = nil }
            case "drop_kind":
                action = r.kind.flatMap(SessionKind.init(rawValue:)).map { .dropKind($0) }
            case "add_weekly":
                if let k = r.kind.flatMap(SessionKind.init(rawValue:)), let wd = weekday(r.weekday) {
                    action = .addWeekly(kind: k, weekday: wd, durationMin: min(max(r.durationMin ?? 45, 10), 480),
                                        title: clip(r.title, 60) ?? k.label, detail: clip(r.detail, 140) ?? "")
                } else { action = nil }
            case "scale_duration":
                action = r.percent.map { .scaleDuration(percent: min(max($0, 10), 200)) }
            case "indoor_rides":
                action = .indoorRides(r.indoor ?? true)
            default:
                action = nil
            }
            guard let action else { return nil }
            return PlanRule(action: action, startDate: start, endDate: end,
                            weekdays: r.weekdays?.compactMap(weekday).sorted().nilIfEmpty(),
                            note: note, createdAt: now)
        }

        let days: [PlanProposal.DayChange] = (out.days ?? []).prefix(maxDays).compactMap { d in
            guard let date = valid(d.date), date >= todayISO else { return nil }
            let sessions = d.sessions.prefix(4).map { s -> PlanSession in
                var rx = Prescription()
                rx.durationMin = s.durationMin.map { min(max($0, 5), 720) }
                rx.intensity = clip(s.intensity, 160)
                rx.heartRate = clip(s.heartRate, 120)
                rx.power = clip(s.power, 120)
                rx.fuelDuring = clip(s.fuelDuring, 320)
                return PlanSession(kind: SessionKind(rawValue: s.kind) ?? .flex,
                                   title: clip(s.title, 60) ?? "Session",
                                   detail: clip(s.detail, 140) ?? "",
                                   rx: rx,
                                   startTime: s.startTime,
                                   indoor: s.indoor)
            }
            return PlanProposal.DayChange(date: date, reason: clip(d.reason, 220) ?? "Changed in chat",
                                          sessions: Array(sessions))
        }

        return PlanProposal(summary: clip(out.summary, 400) ?? "Plan change", rules: rules, days: days)
    }
}

extension Array {
    func nilIfEmpty() -> [Element]? { isEmpty ? nil : self }
}
