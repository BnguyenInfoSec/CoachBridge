import Foundation

/// Claude's update to the coming week, saved on the phone until it's superseded.
struct PlanUpdate: Codable, Equatable, Sendable {
    struct DayChange: Codable, Hashable, Sendable {
        var sessions: [PlanSession]
        var reason: String
        var changedSessions: Bool
    }

    var createdAt: Date
    var model: String
    var todayCall: String
    var weekNote: String?
    /// "yyyy-MM-dd" → the day as Claude wants it.
    var days: [String: DayChange]
}

/// Builds the request that asks Claude to adjust the next 7 days, and validates the answer.
enum PlanAdjuster {
    static let toolName = "update_week"
    static let windowDays = 7

    static var tool: [String: Any] {
        let session: [String: Any] = [
            "type": "object",
            "properties": [
                "kind": ["type": "string", "enum": SessionKind.allCases.map(\.rawValue)],
                "title": ["type": "string"],
                "detail": ["type": "string", "description": "Short description, e.g. \"45 min, conversational\""],
                "duration_min": ["type": "integer"],
                "distance": ["type": "string"],
                "intensity": ["type": "string"],
                "heart_rate": ["type": "string", "description": "Target HR range with units"],
                "power": ["type": "string", "description": "Bike power target with units, if FTP is known"],
                "pace": ["type": "string"],
                "fuel_before": ["type": "string"],
                "fuel_during": ["type": "string", "description": "Carbs/h, sodium, fluid — specific to this session"],
                "fuel_after": ["type": "string"],
                "notes": ["type": "string"],
                "start_time": ["type": "string", "description": "Local start time HH:mm that fits the athlete's calendar and the weather"],
                "indoor": ["type": "boolean", "description": "true for rides on the smart trainer (rain, wind, darkness, precise intervals)"],
            ],
            "required": ["kind", "title"],
        ]
        return [
            "name": toolName,
            "description": "Return today's coaching call and the days of the coming week that should differ from the plan (sessions or their targets).",
            "input_schema": [
                "type": "object",
                "properties": [
                    "today_call": ["type": "string", "description": "1–3 sentences: go / ease off / rest today, and why, citing the numbers."],
                    "week_note": ["type": "string", "description": "Optional one-sentence note about the week."],
                    "days": [
                        "type": "array",
                        "description": "Only days you change. Omit days where the plan and its targets stand. Empty array if nothing changes.",
                        "items": [
                            "type": "object",
                            "properties": [
                                "date": ["type": "string", "description": "YYYY-MM-DD, one of the dates given"],
                                "reason": ["type": "string", "description": "One short sentence citing the data behind the change."],
                                "changed_sessions": ["type": "boolean", "description": "true if sessions were swapped, shortened or removed; false if only targets or fueling were refined."],
                                "sessions": ["type": "array", "items": session],
                            ],
                            "required": ["date", "reason", "changed_sessions", "sessions"],
                        ],
                    ],
                ],
                "required": ["today_call", "days"],
            ],
        ]
    }

    static func systemPrompt(engine: PlanEngine) -> String {
        let p = engine.profile
        let goal = engine.blueprint.hasEvent
            ? "\(engine.raceName) on \(engine.raceISO)"
            : "general \(p.eventKind.label.lowercased()) — no race date set"
        return """
        You are the endurance coach behind this athlete's training plan (goal: \(PromptSafety.inline(goal))).

        \(PromptSafety.dataRule)
        Each time the athlete refreshes their calendar you review the next 7 days against their latest data and adjust only what the data justifies.

        \(p.goal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "" :
          "What a good race day looks like to them: \(PromptSafety.inline(p.goal, max: 400))\n")
        Equipment they have — never program a session needing anything else:
        \(p.equipmentList.isEmpty ? "nothing listed" : p.equipmentList.map { $0.label.lowercased() }.joined(separator: ", "))
        \(((p.gear?.coachLines ?? []) + (p.fuel?.coachLines ?? [])).map { PromptSafety.inline($0, max: 400) }.joined(separator: "\n"))

        Plan rules (follow them exactly):
        \(engine.lifeRules)

        How to adjust:
        - Sessions marked "addedByAthlete": true are the athlete's own commitments (a group run, a race, a swim with friends). Keep them exactly as given — same day, time, title and length — and rebuild the rest of that week around them: move, shorten or cut plan sessions using the cut order so the week's load still fits the phase. Return the athlete's session unchanged in that day's session list.
        - Default to the plan. If nothing in the data warrants a change, return no days.
        - Never add volume or intensity beyond what the plan already has for that phase; moving a session within the week is fine.
        - Give every session you return concrete targets: duration, intensity, HR and power ranges with units when the athlete's FTP/LTHR are given (otherwise describe the effort), and fueling before/during/after (carbs g/h, sodium mg/h, fluid ml/h for anything over 90 min).
        - Work around the athlete's calendar: never overlap an event, leave ~15 min either side, keep their commitments free. If a day has no room, move the session within the week or drop it using the cut order, and say so in the reason. The app places unchanged sessions in the first free slot itself, so return a day for timing only when the default slot would clash.
        \(p.hasTrainer ? "- The athlete has a smart trainer. Set \"indoor\": true on rides when the weather is bad (rain, wind over ~20 mph, dark) or when the session is precise intervals — the trainer holds the watts. Long endurance rides stay outdoors when the weather allows." : "- The athlete has no indoor trainer, so never set \"indoor\": true; move a ride to another day instead when the weather is bad.")
        - Use the weather: above ~90°F feels-like, move the session to first light; strong wind or rain on a ride day is a reason to swap days or go indoors. Mention weather in the reason when it drove the change.
        - Use the same session kinds as the plan: \(SessionKind.allCases.map(\.rawValue).joined(separator: ", ")).
        - Be specific and brief; this is read on a phone. Not medical advice: for illness signs apply the neck check.
        """
    }

    struct DayInput: Encodable {
        let date: String
        let day: String
        let sessions: [PlanSession]

        private enum Keys: String, CodingKey { case date, day, sessions }

        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: Keys.self)
            try c.encode(date, forKey: .date)
            try c.encode(day, forKey: .day)
            try c.encode(sessions.map(Session.init), forKey: .sessions)
        }

        /// Same shape as a plan session, plus the flag that marks the athlete's own entries.
        private struct Session: Encodable {
            let kind: SessionKind
            let title: String
            let detail: String
            let rx: Prescription?
            let startTime: String?
            let addedByAthlete: Bool
            let indoor: Bool?

            init(_ s: PlanSession) {
                kind = s.kind; title = PromptSafety.inline(s.title); detail = PromptSafety.inline(s.detail, max: 400)
                // Targets can be athlete-typed; the prompt cleans them rather than trusting storage did.
                rx = s.rx.map { r in
                    var c = r
                    func t(_ v: String?) -> String? { v.map { PromptSafety.inline($0, max: 200) } }
                    c.distance = t(r.distance); c.intensity = t(r.intensity); c.heartRate = t(r.heartRate)
                    c.power = t(r.power); c.pace = t(r.pace); c.fuelBefore = t(r.fuelBefore)
                    c.fuelDuring = t(r.fuelDuring); c.fuelAfter = t(r.fuelAfter); c.notes = t(r.notes)
                    return c
                }
                startTime = s.startTime; addedByAthlete = s.addedByAthlete; indoor = s.indoor
            }
        }
    }

    static func userMessage(engine: PlanEngine, today: Date, planned: [DayInput],
                            profile: String, healthSummary: String?, recentWork: [String],
                            calendarText: String? = nil, weatherText: String? = nil,
                            added: [String]? = nil, effortText: String? = nil) -> String {
        let ph = engine.phase(for: today)
        let enc = JSONEncoder()
        enc.outputFormatting = [.withoutEscapingSlashes]
        let planJSON = (try? String(data: enc.encode(planned), encoding: .utf8)) ?? "[]"
        let names = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
        let s = engine.settings
        var lines: [String] = []
        lines.append("Today: \(engine.iso(today)) (\(names[engine.jsDay(today)])). Phase: \(ph.name) (\(ph.start) → \(ph.end), \(ph.hours)/wk). Phase goal: \(ph.goal)")
        lines.append("Days to race: \(engine.daysToRace(from: today)).")
        lines.append("Schedule: " + engine.profile.work.summary
                     + (engine.profile.commitments.isEmpty ? ""
                        : ". Commitments: " + engine.profile.commitments.prefix(20).map { PromptSafety.inline($0.summary, max: 160) }.joined(separator: "; "))
                     + (engine.profile.blackouts.isEmpty ? ""
                        : ". Away: " + engine.profile.blackouts.prefix(20).map { PromptSafety.inline($0.summary, max: 160) }.joined(separator: "; ")))
        lines.append("Zones: FTP \(s.ftpWatts.map { "\($0) W" } ?? "not tested yet"); LTHR \(s.lthrBpm.map { "\($0) bpm" } ?? "unknown").")
        lines.append("")
        lines.append("About the athlete:\n" + PromptSafety.block(.athleteProfile, CoachContext.athleteText(engine.profile, engine: engine), max: 8_000))
        let own = profile.trimmingCharacters(in: .whitespacesAndNewlines)
        if !own.isEmpty { lines.append("In their own words:\n" + PromptSafety.block(.athleteNotes, own, max: 4_000)) }
        lines.append("")
        lines.append("PLAN FOR THE NEXT \(windowDays) DAYS (with current targets):\n\(planJSON)")
        lines.append("")
        lines.append("APPLE HEALTH:\n\(healthSummary ?? "Not shared — adjust only for the schedule; do not guess recovery.")")
        if !recentWork.isEmpty {
            lines.append("")
            lines.append("WORKOUTS IN THE LAST 7 DAYS:\n" + recentWork.joined(separator: "\n"))
        }
        if let effortText, !effortText.isEmpty {
            lines.append("")
            lines.append("""
            HOW THOSE SESSIONS FELT (the athlete's own rating, Borg CR10 — 1 is barely moving, 10 is \
            everything they had). Trust this over heart rate when the two disagree: a rising RPE at \
            the same pace or power is fatigue arriving before the numbers show it.
            \(effortText)
            """)
        }
        lines.append("")
        // Event titles can be written by anyone who sends the athlete an invite: the classic
        // indirect prompt-injection route. Fenced, and the system prompt says it's data.
        lines.append("CALENDAR (times and titles from the athlete's own calendars):\n"
                     + (calendarText.map { PromptSafety.block(.calendar, $0, max: 4_000) } ?? "Not connected — assume the usual windows."))
        if let weatherText, !weatherText.isEmpty {
            lines.append("")
            lines.append("WEATHER FORECAST (training location):\n\(weatherText)")
        }
        lines.append("")
        if let added, !added.isEmpty {
            lines.append("")
            lines.append("SESSIONS THE ATHLETE ADDED (fixed — plan around them):\n"
                         + PromptSafety.block(.athleteSessions, added.prefix(12).map { PromptSafety.inline($0, max: 400) }.joined(separator: "\n"), max: 5_000))
        }
        lines.append("")
        lines.append("Call \(toolName) with today's call and any days you change.")
        return lines.joined(separator: "\n")
    }

    // MARK: - Parsing + validation

    private struct Output: Decodable {
        struct S: Decodable {
            let kind: String
            let title: String
            let detail: String?
            let durationMin: Int?
            let distance: String?
            let intensity: String?
            let heartRate: String?
            let power: String?
            let pace: String?
            let fuelBefore: String?
            let fuelDuring: String?
            let fuelAfter: String?
            let notes: String?
            let startTime: String?
            let indoor: Bool?
        }
        struct Day: Decodable {
            let date: String
            let reason: String
            let changedSessions: Bool?
            let sessions: [S]
        }
        let todayCall: String
        let weekNote: String?
        let days: [Day]
    }

    enum ParseError: LocalizedError {
        case unreadable
        var errorDescription: String? { "Couldn't read Claude's plan update. Try again in a minute." }
    }

    /// Decodes Claude's tool input and keeps only sane changes inside the window.
    static func parse(_ data: Data, window: Set<String>, model: String, now: Date) throws -> PlanUpdate {
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

        var days: [String: PlanUpdate.DayChange] = [:]
        for d in out.days where window.contains(d.date) {
            let sessions = d.sessions.prefix(4).map { s -> PlanSession in
                let rx = Prescription(
                    durationMin: s.durationMin.map { min(max($0, 0), 720) },
                    distance: clip(s.distance, 40), intensity: clip(s.intensity, 160),
                    heartRate: clip(s.heartRate, 120), power: clip(s.power, 120), pace: clip(s.pace, 120),
                    fuelBefore: clip(s.fuelBefore, 240), fuelDuring: clip(s.fuelDuring, 320),
                    fuelAfter: clip(s.fuelAfter, 240), notes: clip(s.notes, 300))
                return PlanSession(kind: SessionKind(rawValue: s.kind) ?? .flex,
                                   title: clip(s.title, 60) ?? "Session",
                                   detail: clip(s.detail, 140) ?? "",
                                   rx: rx,
                                   startTime: s.startTime.flatMap { Scheduler.time($0, on: .now, calendar: .current) != nil ? $0 : nil },
                                   indoor: s.indoor)
            }
            days[d.date] = PlanUpdate.DayChange(sessions: Array(sessions),
                                                reason: clip(d.reason, 220) ?? "Adjusted by Claude",
                                                changedSessions: d.changedSessions ?? true)
        }
        return PlanUpdate(createdAt: now, model: model,
                          todayCall: clip(out.todayCall, 500) ?? "",
                          weekNote: clip(out.weekNote, 240),
                          days: days)
    }
}

/// Pure rate-limit math, so the one-per-minute rule is testable.
enum RateLimit {
    static let interval: TimeInterval = 60

    /// Whole seconds until the next request is allowed (0 = allowed now).
    static func secondsRemaining(last: Date?, now: Date, interval: TimeInterval = interval) -> Int {
        guard let last else { return 0 }
        let left = interval - now.timeIntervalSince(last)
        return left > 0 ? Int(left.rounded(.up)) : 0
    }
}
