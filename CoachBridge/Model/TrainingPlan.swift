import Foundation

// Native port of the Road to Sacramento plan engine (phases, weekly templates, class nights,
// snowboard weekends, events, milestones). Keep in step with the coach page if the plan changes.

enum SessionKind: String, Codable, CaseIterable, Sendable {
    case swim, bike, run, lift, rest, flex, snow, fun
    /// A round of golf: something the athlete adds, never generated. Walking 18 holes is a few
    /// hours on your feet, so it counts toward the week's load like any other session.
    case golf

    var symbol: String {
        switch self {
        case .swim: return "figure.pool.swim"
        case .bike: return "figure.outdoor.cycle"
        case .run: return "figure.run"
        case .lift: return "dumbbell.fill"
        case .rest: return "bed.double.fill"
        case .flex: return "sparkles"
        case .snow: return "figure.snowboarding"
        case .fun: return "party.popper.fill"
        case .golf: return "figure.golf"
        }
    }

    var label: String {
        switch self {
        case .swim: return "Swim"
        case .bike: return "Bike"
        case .run: return "Run"
        case .lift: return "Lift"
        case .rest: return "Rest"
        case .flex: return "Optional"
        case .snow: return "Snowboard"
        case .fun: return "Event"
        case .golf: return "Golf"
        }
    }
}

/// Targets and fueling for one session. Filled from the plan's rules (Prescriber) and
/// refined by Claude for the coming week.
struct Prescription: Codable, Hashable, Sendable {
    var durationMin: Int?
    var distance: String?
    var intensity: String?
    var heartRate: String?
    var power: String?
    var pace: String?
    var fuelBefore: String?
    var fuelDuring: String?
    var fuelAfter: String?
    var notes: String?

    /// This prescription with anything left blank taken from `base` — how a session from Claude
    /// or the athlete gets the plan's own targets and fuelling for whatever they didn't specify.
    func filling(from base: Prescription) -> Prescription {
        var r = self
        r.durationMin = r.durationMin ?? base.durationMin
        r.distance = r.distance ?? base.distance
        r.intensity = r.intensity ?? base.intensity
        r.heartRate = r.heartRate ?? base.heartRate
        r.power = r.power ?? base.power
        r.pace = r.pace ?? base.pace
        r.fuelBefore = r.fuelBefore ?? base.fuelBefore
        r.fuelDuring = r.fuelDuring ?? base.fuelDuring
        r.fuelAfter = r.fuelAfter ?? base.fuelAfter
        return r
    }
}

struct PlanSession: Codable, Hashable, Sendable {
    var kind: SessionKind
    var title: String
    var detail: String = ""
    var rx: Prescription? = nil
    /// Local "HH:mm" chosen by Claude around the athlete's calendar, if any.
    var startTime: String? = nil
    /// Set when the athlete added this session themselves; then the time is fixed.
    var customID: UUID? = nil
    /// Rides on the smart trainer instead of the road.
    var indoor: Bool? = nil

    var addedByAthlete: Bool { customID != nil }
}

struct PlanPhase: Sendable, Equatable {
    let id: String
    let name: String
    let short: String
    let start: String
    let end: String
    let hours: String
    let goal: String
    let focus: String
}

/// A day's place in the season, for labelling calendars: "Base 1 · week 3 of 10".
struct PhaseWeek: Sendable, Equatable {
    let phase: PlanPhase
    /// Position of the phase in the plan, for a stable color.
    let index: Int
    let week: Int
    let weeks: Int
    let isRecovery: Bool

    /// "Base 1 · week 3 of 10", plus "· easier week" on a recovery week. The taper already says
    /// what it is, so it isn't also called an easier week.
    var label: String {
        var s = "\(phase.name) · week \(week) of \(weeks)"
        if isRecovery && phase.id != "taper" && phase.id != "rec" { s += " · easier week" }
        return s
    }
}

/// One phase as an all-day banner across its dates in the athlete's Training calendar, so the
/// season's shape shows in Apple Calendar and not just in the app.
struct PhaseBanner: Sendable, Equatable {
    let id: String
    let title: String
    /// First day, "yyyy-MM-dd".
    let startISO: String
    /// Last day, inclusive.
    let endISO: String
    let notes: String

    init(_ p: PlanPhase, weeks: Int) {
        id = p.id
        title = "\(p.name) · \(weeks) week\(weeks == 1 ? "" : "s")"
        startISO = p.start
        endISO = p.end
        notes = """
        \(p.goal)

        Focus: \(p.focus)
        Volume: \(p.hours) a week

        Coach Bridge writes this banner from your plan and rewrites it on each sync.
        """
    }

    static func all(_ e: PlanEngine) -> [PhaseBanner] {
        e.phases.map { PhaseBanner($0, weeks: e.calendarWeeks($0)) }
    }
}

struct Milestone: Sendable, Equatable {
    enum Kind: String, Sendable { case test, deadline, fun, recovery, race, check }
    let date: String
    let when: String
    let title: String
    let detail: String
    let kind: Kind
}

/// User-editable schedule constraints (the coach page's "Schedule" section).
struct PlanSettings: Codable, Equatable, Sendable {
    /// Legacy: class nights and snowboard weekends moved to `AthleteProfile.commitments` and
    /// `.blackouts` in v2. Kept only so old saved settings still decode and can be migrated.
    var classDays: [Int] = []
    var classUntil: String = ""
    var snowSaturdays: [String] = []
    /// Optional numbers that turn "by feel" targets into watts and bpm.
    var ftpWatts: Int? = nil
    var lthrBpm: Int? = nil
    /// Wahoo KICKR CORE 2 or similar; enables indoor ride targets and ERG notes.
    var hasTrainer: Bool? = nil
    /// Default venue per session kind (photos and names shown on the day screen).
    var venueByKind: [String: String]? = nil

    var trainer: Bool { hasTrainer ?? true }

    static let storageKey = "plan.settings"

    static func load(_ defaults: UserDefaults = .standard) -> PlanSettings {
        guard let data = defaults.data(forKey: storageKey),
              let s = try? JSONDecoder().decode(PlanSettings.self, from: data) else { return PlanSettings() }
        return s
    }

    func save(_ defaults: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(self) { defaults.set(data, forKey: Self.storageKey) }
    }
}

struct PlanEngine: Sendable {
    /// The athlete's plan, derived from their profile. Nothing about the season is hardcoded
    /// any more — dates, phases, sports and volume all come from here.
    var blueprint: PlanBlueprint
    var settings: PlanSettings
    var calendar: Calendar
    /// Lasting changes from the Coach chat.
    var rules: [PlanRule]

    init(profile: AthleteProfile = AthleteProfile(), settings: PlanSettings = PlanSettings(),
         calendar: Calendar = .current, rules: [PlanRule] = []) {
        self.blueprint = PlanBlueprint.make(profile, calendar: calendar)
        self.settings = settings
        self.calendar = calendar
        self.rules = rules
    }

    var startISO: String { blueprint.startISO }
    var endISO: String { blueprint.endISO }
    var raceISO: String { blueprint.raceISO }
    var raceName: String { blueprint.raceName }
    var profile: AthleteProfile { blueprint.profile }

    // MARK: Dates

    func date(_ iso: String) -> Date {
        let p = iso.split(separator: "-").compactMap { Int($0) }
        return calendar.date(from: DateComponents(year: p[0], month: p[1], day: p[2]))!
    }

    func iso(_ d: Date) -> String { DayRecord.dateKey(for: d, calendar: calendar) }

    func add(_ d: Date, days: Int) -> Date { calendar.date(byAdding: .day, value: days, to: d)! }

    /// 0 = Sun … 6 = Sat (matches the page's JavaScript getDay()).
    func jsDay(_ d: Date) -> Int { calendar.component(.weekday, from: d) - 1 }

    func monday(of d: Date) -> Date {
        let day = calendar.startOfDay(for: d)
        return add(day, days: -((jsDay(day) + 6) % 7))
    }

    func inPlan(_ d: Date) -> Bool {
        let s = iso(d)
        return s >= startISO && s <= endISO
    }

    func daysToRace(from d: Date) -> Int {
        max(0, calendar.dateComponents([.day], from: calendar.startOfDay(for: d), to: date(raceISO)).day ?? 0)
    }

    // MARK: Phases

    var phases: [PlanPhase] { blueprint.phases }

    func phase(for d: Date) -> PlanPhase { blueprint.phase(for: iso(d)) }

    /// Where a day sits in the season: its phase, which week of that phase, and whether the
    /// plan eases off that week. Nil outside the plan, where "week 3 of Base 1" would be a lie.
    func phaseWeek(_ d: Date) -> PhaseWeek? {
        guard inPlan(d) else { return nil }
        let iso = iso(d)
        guard let i = phases.firstIndex(where: { iso >= $0.start && iso <= $0.end }) else { return nil }
        let p = phases[i]
        return PhaseWeek(phase: p, index: i,
                         week: mondaysBetween(date(p.start), d) + 1,
                         weeks: calendarWeeks(p),
                         isRecovery: WeekBuilder.isRecoveryWeek(weekIndex(monday(of: d))))
    }

    /// Weeks are counted Monday to Sunday, like the week view and recovery weeks, not from the
    /// phase's first day: a phase starting on a Friday otherwise called Mon–Thu "week 1" and
    /// Fri–Sun "week 2" of the same calendar week.
    func calendarWeeks(_ p: PlanPhase) -> Int { mondaysBetween(date(p.start), date(p.end)) + 1 }

    private func mondaysBetween(_ a: Date, _ b: Date) -> Int {
        let days = calendar.dateComponents([.day], from: monday(of: a), to: monday(of: b)).day ?? 0
        return max(0, Int((Double(days) / 7).rounded()))
    }

    static func mk(_ k: SessionKind, _ t: String, _ d: String = "") -> PlanSession {
        PlanSession(kind: k, title: t, detail: d)
    }

    // MARK: Weekly build

    /// Week number since the plan started, used for progression and the long-session rotation.
    func weekIndex(_ monday: Date) -> Int {
        // `self.` because the parameter shadows the monday(of:) method.
        let planStart = self.monday(of: date(startISO))
        let days = calendar.dateComponents([.day], from: planStart, to: monday).day ?? 0
        return max(0, Int((Double(days) / 7).rounded()))
    }

    /// The plan for the 7 days starting `monday`, before schedule adjustments.
    func rawWeek(_ monday: Date) -> [[PlanSession]] {
        let ph = phase(for: monday)
        let w = weekIndex(monday)
        return WeekBuilder.week(blueprint: blueprint, phase: ph, weekIndex: w,
                                isRecoveryWeek: WeekBuilder.isRecoveryWeek(w))
    }

    /// The week after the athlete's commitments, time away and their own events are applied.
    func week(_ monday: Date) -> [[PlanSession]] {
        var days = rawWeek(monday)
        let p = profile

        for i in 0..<7 {
            let d = add(monday, days: i)
            let dayISO = iso(d)
            let js = jsDay(d)

            // A standing commitment (class, a shift) takes the evening. Anything scheduled that
            // day survives — the Scheduler places it around the commitment — but the day is
            // marked so the athlete and Claude both see why it's tight.
            for c in p.commitments where c.applies(dayISO, jsDay: js) {
                days[i].append(Self.mk(.rest, "\(c.title) \(c.startHour):00–\(c.endHour):00",
                                       "Train before it or let the day go easy"))
            }

            // Time away.
            if let b = p.blackouts.first(where: { $0.covers(dayISO) }) {
                switch b.mode {
                case .off:
                    days[i] = [Self.mk(.rest, b.title, "Away — no session planned")]
                case .easy:
                    days[i] = [Self.mk(.flex, "Optional easy session", "\(b.title) — 30–45 min if you feel like it")]
                case .crossTraining:
                    days[i] = [Self.mk(.snow, b.title, "Counts as this week's long session. Eat and drink like it's one.")]
                }
            }
        }

        for ev in p.events {
            let i = calendar.dateComponents([.day], from: monday, to: date(ev.dateISO)).day ?? -1
            if (0..<7).contains(i) { days[i] = [Self.mk(.fun, ev.title, ev.detail)] }
        }

        guard !rules.isEmpty else { return days }
        return RuleEngine.apply(rules, to: days,
                                isoFor: { self.iso(self.add(monday, days: $0)) },
                                jsDayFor: { self.jsDay(self.add(monday, days: $0)) })
    }

    /// The sessions on one day, after the whole week is assembled — the app's main entry point.
    func sessions(on d: Date) -> [PlanSession] {
        guard inPlan(d) else { return [] }
        return week(monday(of: d))[(jsDay(d) + 6) % 7]
    }

    // MARK: Milestones

    var milestones: [Milestone] {
        blueprint.milestones + profile.events.map {
            Milestone(date: $0.dateISO, when: $0.dateISO, title: $0.title, detail: $0.detail, kind: .race)
        }
    }

    func milestones(on d: Date) -> [Milestone] {
        let s = iso(d)
        return milestones.filter { $0.date == s }
    }

    /// The coaching rules given to Claude verbatim, written from this athlete's own setup.
    var lifeRules: String {
        let p = profile
        var lines = [
            "- The minimum week is three sessions. A week of three is normal, not failed.",
            "- What gets cut first: the optional session → the second lift → the midweek quality session → the long session. Never cut two long sessions in a row.",
            "- Missed a long session: let it go. Never double the next one or bolt it onto a weekday.",
            "- Travel, exam and holiday weeks are recovery weeks: three sessions, no long day.",
            "- Neck check: symptoms above the neck → easy sessions only. Chest, cough, fever → stop until they clear.",
            "- Heat above ~90°F: move the long session to first light, or indoors.",
            "- Readiness: green = do it as written; amber = keep duration, drop intensity; red = rest or 30 min very easy. Two red mornings in a row and the long session waits.",
            "- Alcohol spikes resting HR; one high reading after drinks isn't fatigue.",
        ]
        if !p.work.weekdays.isEmpty {
            lines.append("- Work/school: \(p.work.summary). Sessions go before or after, never during.")
        }
        for c in p.commitments {
            lines.append("- \(PromptSafety.inline(c.summary, max: 160)) stays a rest evening; train before it or let it go.")
        }
        for b in p.blackouts {
            lines.append("- \(PromptSafety.inline(b.summary, max: 160)).")
        }
        if p.liftsPerWeek == 0 { lines.append("- No lifting in this plan.") }
        if !p.avoidedSports.isEmpty {
            lines.append("- Don't program: " + p.avoidedSports.map { $0.label.lowercased() }.joined(separator: ", ") + ".")
        }
        if !p.notes.isEmpty {
            lines.append("- In the athlete's own words:\n" + PromptSafety.block(.athleteNotes, p.notes, max: 2_000))
        }
        return lines.joined(separator: "\n")
    }
}
