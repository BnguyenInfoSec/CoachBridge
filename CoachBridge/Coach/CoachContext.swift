import Foundation

enum AppSettings {
    static let modelKey = "coach.model"
    static let defaultModel = "claude-sonnet-5"

    /// A web page of the athlete's own plan, if they keep one. Empty by default.
    static let planURLKey = "coach.planURL"
    static let defaultPlanURL = ""

    /// Where "Continue in the Claude app" goes. Empty means the Claude app's home.
    static let projectURLKey = "coach.projectURL"
    static let defaultProjectURL = "https://claude.ai"

    static let includeHealthKey = "coach.includeHealth"
    static let chatCanEditPlanKey = "coach.chatCanEditPlan"
    static let apiKeyAccount = "anthropic-api-key"
    /// Base URL of a shared server, when the provider is `.hosted`.
    static let hostedURLKey = "coach.hostedURL"

    /// Free text the athlete writes about themselves. Empty by default — the structured facts
    /// live in `AthleteProfile`, and this is for everything a form can't hold.
    static let profileKey = "coach.profile"
    static let defaultProfile = ""

    /// Shown as placeholder text in the editor, so an empty box isn't intimidating.
    static let profilePlaceholder = """
    Anything the coach should know that the setup questions didn't cover. For example:

    • What you've raced before, and how it went
    • Your weakest discipline, and what you're trying to fix
    • Injuries or niggles to plan around
    • How you like to be coached — blunt, encouraging, detail-heavy
    • Anything odd about your data ("I don't wear my watch to sleep")
    """
}

enum DistanceFormat {
    static var usesImperial: Bool { Locale.current.measurementSystem == .us }

    static func string(meters: Double, sport: Sport) -> String {
        if sport == .swim {
            return usesImperial ? "\(Int((meters / 0.9144).rounded())) yd" : "\(Int(meters.rounded())) m"
        }
        return usesImperial ? String(format: "%.1f mi", meters / 1609.344) : String(format: "%.1f km", meters / 1000)
    }
}

/// Builds the text Claude sees. Pure, so it's unit-tested and shown to the user verbatim.
enum CoachContext {
    static let yesterdayKeys: Set<MetricKey> = [.activeCal, .exerciseMin, .steps, .walkHR]

    /// The next two weeks as Claude sees them in chat, plus any lasting rules already in force.
    /// Reads `PlanModel`, which is `@MainActor`, so this is too. Its callers (`ChatModel.send`)
    /// are already on the main actor.
    @MainActor
    static func planText(plan: PlanModel) -> String {
        let e = plan.engine
        let today = e.calendar.startOfDay(for: .now)
        var lines: [String] = []
        let ph = e.phase(for: today)
        lines.append("Phase: \(ph.name) (\(ph.start) → \(ph.end), \(ph.hours)/wk). Race \(e.raceName) \(e.raceISO). Days to race: \(e.daysToRace(from: today)).")
        for i in 0..<14 {
            let d = e.add(today, days: i)
            let day = plan.day(d)
            let names = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
            let body = day.sessions.map { s -> String in
                let mins = s.rx?.durationMin.map { " \($0) min" } ?? ""
                return "\(s.kind.rawValue): \(s.title)\(mins)\(s.addedByAthlete ? " [athlete-added, fixed]" : "")"
            }.joined(separator: "; ")
            lines.append("\(day.iso) \(names[e.jsDay(d)]): \(body.isEmpty ? "nothing" : body)")
        }
        if !plan.rules.rules.isEmpty {
            lines.append("Lasting rules already in force: " + plan.rules.rules.map(\.summary).joined(separator: " | "))
        }
        return lines.joined(separator: "\n")
    }

    static func systemPrompt(profile: String, healthSummary: String?, now: Date,
                             athlete: String? = nil,
                             planText: String? = nil, canEditPlan: Bool = false) -> String {
        """
        You are the endurance coach inside the athlete's Coach Bridge iPhone app.
        Today is \(now.formatted(date: .complete, time: .omitted)).

        About the athlete:
        \(athlete ?? "They haven't set up a plan yet.")

        In their own words:
        \(profile.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "(nothing added yet — ask about their background if it would change your advice)"
            : profile.trimmingCharacters(in: .whitespacesAndNewlines))

        How to coach:
        - Base advice on the data below. Say plainly when something is missing or too sparse to judge; never invent numbers.
        - Keep answers short and scannable; they're read on a phone.
        - The recovery signal is a rough heuristic from resting HR and HRV, not a diagnosis.
        - You are not a doctor. If something sounds medically concerning (chest pain, fainting, unusual heart rhythm), tell them to stop and get checked.
        - Coach the athlete in front of you. Don't assume a sport, a race or a schedule they haven't told you about.

        Apple Health data from the athlete's iPhone:
        \(healthSummary ?? "Not shared for this conversation.")

        \(planText.map { "The plan as it stands:\n" + $0 } ?? "")

        \(canEditPlan ? editingRules : "You can't change the plan from this chat; describe what you'd do instead.")
        """
    }

    /// The structured profile as prose, so the model gets the facts without reading JSON.
    static func athleteText(_ p: AthleteProfile, engine: PlanEngine) -> String {
        let names = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
        var lines: [String] = []
        if !p.name.isEmpty { lines.append("Name: \(p.name).") }
        if engine.blueprint.hasEvent {
            lines.append("Training for \(engine.raceName) on \(engine.raceISO) — \(p.eventKind.label).")
        } else {
            lines.append("Training for \(p.eventKind.label.lowercased()); no race date set.")
        }
        if !p.goal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            lines.append("What a good day looks like to them: \(p.goal.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        lines.append("Currently around \(String(format: "%.1f", p.currentWeeklyHours)) h a week, aiming for up to \(String(format: "%.1f", p.peakHours)) h at peak.")
        lines.append("Blocks: " + engine.phases.map { "\($0.name) \($0.start)→\($0.end) (\($0.hours)/wk)" }.joined(separator: "; ") + ".")
        lines.append("Sports in the plan: " + p.sports.map { $0.label.lowercased() }.joined(separator: ", ") + ".")
        lines.append("Trains on: " + p.availableDays.sorted().map { names[$0] }.joined(separator: ", ") + ". Long day: \(names[p.longDay]).")
        if !p.work.weekdays.isEmpty { lines.append("Work/school: \(p.work.summary).") }
        for c in p.commitments { lines.append("Commitment: \(c.summary).") }
        for b in p.blackouts { lines.append("Away: \(b.summary).") }
        for e in p.events { lines.append("\(e.isRace ? "Race" : "Event"): \(e.title) on \(e.dateISO). \(e.detail)") }
        let kit = p.equipmentList
        lines.append(kit.isEmpty
            ? "Equipment: nothing listed — ask before programming anything that needs kit."
            : "Equipment: " + kit.map { $0.label.lowercased() }.joined(separator: ", ")
              + ". Don't program a session that needs something not on this list.")
        lines.append("Lifting \(p.liftsPerWeek)× a week.")
        if !p.preferredSports.isEmpty {
            lines.append("Enjoys: " + p.preferredSports.map { $0.label.lowercased() }.joined(separator: ", ") + ".")
        }
        if !p.avoidedSports.isEmpty {
            lines.append("Would rather avoid: " + p.avoidedSports.map { $0.label.lowercased() }.joined(separator: ", ") + ".")
        }
        return lines.joined(separator: "\n")
    }

    static let editingRules = """
    Changing the plan:
    - You can change the plan with the change_plan tool. Use it only when the athlete asks for a change or clearly agrees to one you suggested. Nothing is applied until they tap Apply, so say in your reply what you're proposing.
    - Use `days` for one-off changes to specific dates (this Saturday's ride becomes a run).
    - Use `rules` for anything lasting — "for the rest of Base 1", "every Wednesday from now on", "one lift a week through December". Give the exact date range; the phase's end date is in the plan above.
    - Keep changes as small as the request: swapping one session this week is a day change, not a rule. Don't rewrite the season for a one-off.
    - Never move or delete sessions marked [athlete-added, fixed]; plan around them.
    - Respect the phase's weekly hours and the plan's cut order. Say plainly if a request would undercut race preparation.
    """

    static func healthSummary(_ d: DashboardData, calendar: Calendar = .current) -> String {
        var lines: [String] = []

        let metrics = MetricKey.allCases.compactMap { key -> String? in
            guard let v = d.today.metrics[key] else { return nil }
            let when = yesterdayKeys.contains(key) ? " (yesterday)" : ""
            return "\(key.title)\(when) \(key.format(v)) \(key.unitLabel)"
        }
        lines.append("Today's check-in (\(d.today.date)): " + (metrics.isEmpty ? "no data yet" : metrics.joined(separator: "; ")))

        lines.append("Recovery signal: \(label(d.recovery.level)). " + d.recovery.reasons.joined(separator: ". "))

        if !d.rhr.isEmpty {
            lines.append("Resting HR by day, oldest to newest (bpm): " + d.rhr.suffix(14).map { "\(Int($0.value.rounded()))" }.joined(separator: ", "))
        }
        if !d.hrv.isEmpty {
            lines.append("HRV daily mean, mostly daytime readings, oldest to newest (ms): " + d.hrv.suffix(14).map { "\(Int($0.value.rounded()))" }.joined(separator: ", "))
        }

        let weeks = Dictionary(grouping: d.weekly, by: \.weekStart).sorted { $0.key < $1.key }
        if weeks.isEmpty {
            lines.append("No workouts in the last 8 weeks.")
        } else {
            lines.append("Training hours by week:")
            for (week, loads) in weeks {
                let parts = Sport.allCases.compactMap { s in
                    loads.first { $0.sport == s }.map { "\(s.rawValue) \(String(format: "%.1f", $0.hours))" }
                }
                let total = loads.reduce(0) { $0 + $1.hours }
                lines.append("- week of \(week.formatted(.dateTime.month(.abbreviated).day())): " + parts.joined(separator: ", ") + String(format: " (total %.1f h)", total))
            }
        }

        if !d.recent.isEmpty {
            lines.append("Recent workouts:")
            for w in d.recent {
                lines.append("- " + workoutLine(w))
            }
        }
        return lines.joined(separator: "\n")
    }

    /// Short version copied to the clipboard for the Claude app handoff.
    static func handoffText(_ d: DashboardData) -> String {
        var lines = ["Coach Bridge check-in \(d.today.date)"]
        let metrics = MetricKey.allCases.compactMap { key -> String? in
            guard let v = d.today.metrics[key] else { return nil }
            return "\(key.title)\(yesterdayKeys.contains(key) ? " (yday)" : "") \(key.format(v)) \(key.unitLabel)"
        }
        if !metrics.isEmpty { lines.append(metrics.joined(separator: " · ")) }
        lines.append("Recovery: \(label(d.recovery.level)). " + d.recovery.reasons.joined(separator: ". "))
        if let week = d.weekly.map(\.weekStart).max() {
            let loads = d.weekly.filter { $0.weekStart == week }
            lines.append("This week: " + loads.map { "\($0.sport.rawValue) \(String(format: "%.1f", $0.hours)) h" }.joined(separator: ", "))
        }
        for w in d.recent.prefix(3) { lines.append(workoutLine(w)) }
        return lines.joined(separator: "\n")
    }

    static func workoutLine(_ w: WorkoutSummary) -> String {
        var parts = [w.start.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()), w.name,
                     "\(Int((w.duration / 60).rounded())) min"]
        if let m = w.distanceMeters, m > 0 { parts.append(DistanceFormat.string(meters: m, sport: w.sport)) }
        if let hr = w.avgHR { parts.append("avg HR \(Int(hr.rounded()))") }
        return parts.joined(separator: ", ")
    }

    static func label(_ level: RecoverySignal.Level) -> String {
        switch level {
        case .good: return "Recovered"
        case .normal: return "Normal"
        case .caution: return "Go easy"
        case .unknown: return "Not enough data"
        }
    }
}
