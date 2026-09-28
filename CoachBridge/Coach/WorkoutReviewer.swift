import Foundation

/// Asks the coach to react to one finished session, in the context of the athlete's goal, the
/// block they're in and how the session actually felt. One forced tool call, generated once and
/// cached in `WorkoutJournal` — reopening a workout never costs another request.
enum WorkoutReviewer {
    static let toolName = "review_workout"
    static let maxTokens = 700

    static var tool: [String: Any] {
        [
            "name": toolName,
            "description": "React to the session the athlete just finished, as their coach.",
            "input_schema": [
                "type": "object",
                "properties": [
                    "headline": [
                        "type": "string",
                        "description": "One short line, under about 60 characters. The thing to take away. No greeting.",
                    ],
                    "body": [
                        "type": "string",
                        "description": "Two or three sentences on what happened: the effort, how it compares to the plan and to their recent sessions, and what their reported feel adds. Cite the actual numbers. Never invent data you weren't given.",
                    ],
                    "toward_goal": [
                        "type": "string",
                        "description": "One sentence connecting this session to the athlete's stated goal and the block they're in. Omit if the session says nothing about the goal.",
                    ],
                    "watch_for": [
                        "type": "string",
                        "description": "Only when something genuinely warrants attention — effort far above what the session asked for, a heart rate that doesn't match the reported feel, a pattern across recent sessions. Omit it entirely otherwise; do not invent a concern to fill the field.",
                    ],
                ],
                "required": ["headline", "body"],
            ],
        ]
    }

    static func systemPrompt(engine: PlanEngine, demo: Bool) -> String {
        let p = engine.profile
        let want = p.goal.trimmingCharacters(in: .whitespacesAndNewlines)
        return """
        You are the endurance coach inside this athlete's Coach Bridge app, writing the short note \
        that appears under a session they just finished.

        \(PromptSafety.dataRule)

        Who they are:
        \(PromptSafety.block(.athleteProfile, CoachContext.athleteText(p, engine: engine), max: 8_000))

        \(want.isEmpty ? "" : "What a good race day looks like to them: \(PromptSafety.inline(want, max: 400))")

        How to write it:
        - Talk to them, not about them. Second person, no greeting, no sign-off.
        - Be specific and cite the numbers you were given. Never invent a number, a comparison or a \
        history you weren't handed — if something isn't in the data, say you can't see it or leave it out.
        - Their reported effort is evidence, not noise. An easy ride that felt like an 8 is worth more \
        attention than one that felt like a 3, whatever the heart rate says.
        - Being off the plan is not automatically a failure. A short session on a hard week can be the \
        right call; say so when it is.
        - Praise has to be earned and specific, or it's worthless. No cheerleading.
        - This is a training note, not medical advice. If something sounds medically concerning \
        (chest pain, fainting, an unusual heart rhythm), tell them to stop and get it checked.
        - Keep it to what fits on a phone screen.
        \(demo ? "\n        IMPORTANT: this is demo data, generated to show the app. Write the note normally, but do not treat these numbers as facts about a real person's training." : "")
        """
    }

    /// Everything the model gets about this one session.
    static func userText(workout: WorkoutSummary,
                         detail: WorkoutDetail?,
                         compare: SessionCompare,
                         feel: WorkoutFeel?,
                         planned: PlanSession?,
                         engine: PlanEngine,
                         recovery: RecoverySignal?,
                         recentSameSport: [WorkoutSummary],
                         recentFeel: String?) -> String {
        var lines: [String] = []
        let today = engine.calendar.startOfDay(for: workout.start)
        let phase = engine.phase(for: today)

        lines.append("Session just finished: \(CoachContext.workoutLine(workout))")
        if let d = detail {
            var extra: [String] = []
            if let v = d.maxHR { extra.append("max HR \(Int(v.rounded()))") }
            if let v = d.avgPower { extra.append("avg power \(Int(v.rounded())) W") }
            if let v = d.maxPower { extra.append("max power \(Int(v.rounded())) W") }
            if let v = d.avgCadence { extra.append("cadence \(Int(v.rounded())) rpm") }
            if let v = d.elevationGainMeters, v > 0 { extra.append("climbing \(Int((v * 3.28084).rounded())) ft") }
            if !extra.isEmpty { lines.append("Also recorded: " + extra.joined(separator: ", ") + ".") }
            if let zones = d.zones, zones.contains(where: { $0.minutes > 0 }) {
                let z = zones.filter { $0.minutes > 0 }
                    .map { "Z\($0.zone) \(Int($0.minutes.rounded())) min" }.joined(separator: ", ")
                lines.append("Time in heart-rate zones: \(z).")
            }
        }

        lines.append("")
        lines.append("Where they are: \(phase.name) block (\(phase.start) → \(phase.end), \(phase.hours) a week). \(phase.goal)")
        if engine.blueprint.hasEvent {
            lines.append("\(engine.daysToRace(from: today)) days to \(PromptSafety.inline(engine.raceName)) on \(engine.raceISO).")
        }

        lines.append("")
        if let planned {
            lines.append("The plan called for: \(PromptSafety.inline(planned.title))\(planned.detail.isEmpty ? "" : " — \(PromptSafety.inline(planned.detail, max: 400))")")
        }
        lines.append("Planned versus actual:")
        lines.append(compare.promptText)

        lines.append("")
        if let feel {
            lines.append("How they said it felt: RPE \(feel.rpe)/10, \(feel.mood.label.lowercased()).")
            let note = feel.note.trimmingCharacters(in: .whitespacesAndNewlines)
            if !note.isEmpty { lines.append("Their note:\n" + PromptSafety.block(.workoutNote, note, max: 1_000)) }
            lines.append("(RPE is Borg CR10: \(feel.rpe)/10 means \"\(WorkoutFeel.rpeLabel(feel.rpe).lowercased())\".)")
        } else {
            lines.append("They haven't said how it felt — don't guess, and don't ask them in the note.")
        }

        if let recovery, recovery.level != .unknown {
            lines.append("Recovery signal that morning: \(CoachContext.label(recovery.level)). \(recovery.reasons.joined(separator: ". "))")
        }
        if let recentFeel { lines.append(recentFeel) }

        let others = recentSameSport.filter { $0.id != workout.id }.prefix(5)
        if !others.isEmpty {
            lines.append("")
            lines.append("Their recent \(workout.sport.rawValue.lowercased()) sessions for comparison:")
            for w in others { lines.append("- " + CoachContext.workoutLine(w)) }
        }

        return lines.joined(separator: "\n")
    }

    // MARK: - Parsing

    /// Reads the tool arguments into a note, clipping anything overlong and dropping empty
    /// optional fields rather than showing a blank row.
    static func parse(_ data: Data, model: String, now: Date = .now) -> CoachNote? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let headline = text(obj["headline"], max: 120)
        let body = text(obj["body"], max: 900)
        guard !headline.isEmpty, !body.isEmpty else { return nil }
        return CoachNote(
            headline: headline,
            body: body,
            towardGoal: optional(obj["toward_goal"], max: 320),
            watchFor: optional(obj["watch_for"], max: 320),
            model: model,
            createdAt: now)
    }

    /// Model output is untrusted (OWASP LLM05): cleaned of hidden characters and tag look-alikes
    /// before it's shown or saved, and capped.
    private static func text(_ v: Any?, max: Int) -> String {
        PromptSafety.clean(v as? String ?? "", max: max)
    }

    private static func optional(_ v: Any?, max: Int) -> String? {
        let s = text(v, max: max)
        guard !s.isEmpty else { return nil }
        // Models sometimes fill an optional field with a non-answer rather than omitting it.
        // Strip punctuation first, so a bare dash reduces to nothing and is dropped too.
        let core = s.lowercased()
            .trimmingCharacters(in: CharacterSet.punctuationCharacters.union(.whitespaces))
        let nonAnswers: Set<String> = ["none", "n/a", "na", "nothing", "no concerns",
                                       "nothing to flag", "nothing of note", "no issues"]
        return core.isEmpty || nonAnswers.contains(core) ? nil : s
    }
}
