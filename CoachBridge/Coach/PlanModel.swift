import Combine
import Foundation
import os

/// One calendar day: the plan (with Claude's changes applied), what was planned originally,
/// milestones, and the workouts actually recorded.
struct DayPlan: Sendable {
    let date: Date
    let iso: String
    let sessions: [PlanSession]
    let original: [PlanSession]
    let change: PlanUpdate.DayChange?
    let milestones: [Milestone]
    let done: [WorkoutSummary]
}

/// Owns the training calendar: plan settings, Claude's latest weekly update (rate-limited to one
/// request per minute, saved on the phone), and recorded workouts per day.
@MainActor
final class PlanModel: ObservableObject {
    /// Who the athlete is and what they're training for. The engine is built from this.
    @Published private(set) var storedProfile: AthleteProfile { didSet { storedProfile.save() } }

    /// In demo mode, someone with no plan of their own borrows the demo one — otherwise the
    /// Plan tab, the thing you most want to show, is empty.
    var profile: AthleteProfile {
        get { DemoData.isOn && !storedProfile.isComplete ? DemoData.profile : storedProfile }
        set { storedProfile = newValue }
    }
    @Published var settings: PlanSettings { didSet { settings.save() } }
    @Published private(set) var update: PlanUpdate?
    @Published private(set) var isUpdating = false
    @Published private(set) var lastRequestAt: Date?
    @Published var errorText: String?
    @Published var infoText: String?
    @Published private(set) var workoutsByDay: [String: [WorkoutSummary]] = [:]

    let custom = CustomSessionStore()
    let rules = RuleStore()
    /// One-off day changes made from the Coach chat, kept until the day passes.
    @Published private(set) var chatDays: [String: PlanUpdate.DayChange] = [:]
    private let source: any HealthSource
    private let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "CoachBridge", category: "plan")
    private var loadedRanges: Set<String> = []
    private var bag: Set<AnyCancellable> = []
    private static let lastRequestKey = "plan.lastClaudeRequest"

    var engine: PlanEngine { PlanEngine(profile: profile, settings: settings, rules: rules.rules) }
    var blueprint: PlanBlueprint { engine.blueprint }
    /// False until the athlete has told us what they're training for.
    var needsSetup: Bool { !profile.isComplete }
    var prescriber: Prescriber { Prescriber(engine: engine) }

    init(source: any HealthSource) {
        self.source = source
        // A local, because Swift won't let us read `self.settings` until every stored
        // property has a value.
        let loaded = PlanSettings.load()
        settings = loaded
        storedProfile = AthleteProfile.migrated(from: loaded)
        lastRequestAt = UserDefaults.standard.object(forKey: Self.lastRequestKey) as? Date
        update = Self.loadUpdate()
        pruneUpdate()
        // Redraw the calendar when the athlete adds or edits their own session.
        custom.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }.store(in: &bag)
        rules.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }.store(in: &bag)
        chatDays = Self.loadChatDays()
        let today = engine.iso(.now)
        chatDays = chatDays.filter { $0.key >= today }
        rules.prune(before: today)
        custom.prune(before: engine.iso(engine.add(engine.calendar.startOfDay(for: .now), days: -60)))
    }

    // MARK: - Calendar data

    func day(_ date: Date) -> DayPlan {
        let e = engine
        let d = e.calendar.startOfDay(for: date)
        let iso = e.iso(d)
        let rx = prescriber
        let original = e.sessions(on: d).map { rx.prescribe($0, on: d) }
        let change = chatDays[iso] ?? update?.days[iso]
        let mine = custom.forDay(iso)
        var sessions = (change?.sessions.map { merged($0, on: d, rx: rx) } ?? original)
            .filter { !$0.addedByAthlete }
        // A planned session the athlete edited is now one of theirs; drop the original.
        sessions = CustomSession.remaining(planned: sessions, replacedBy: mine)
        // The athlete's own sessions always stand, exactly as entered.
        sessions += mine.map { merged($0.planSession(), on: d, rx: rx) }
        return DayPlan(date: d, iso: iso, sessions: sessions, original: original, change: change,
                       milestones: e.milestones(on: d), done: workoutsByDay[iso] ?? [])
    }

    /// Fills anything left blank (by Claude or by a hand-entered session) from the plan's own rules.
    private func merged(_ s: PlanSession, on d: Date, rx: Prescriber) -> PlanSession {
        guard let base = rx.prescription(for: s, on: d) else { return s }
        var r = s.rx ?? Prescription()
        r.durationMin = r.durationMin ?? base.durationMin
        r.distance = r.distance ?? base.distance
        r.intensity = r.intensity ?? base.intensity
        r.heartRate = r.heartRate ?? base.heartRate
        r.power = r.power ?? base.power
        r.pace = r.pace ?? base.pace
        r.fuelBefore = r.fuelBefore ?? base.fuelBefore
        r.fuelDuring = r.fuelDuring ?? base.fuelDuring
        r.fuelAfter = r.fuelAfter ?? base.fuelAfter
        var out = s
        out.rx = r
        return out
    }

    /// Loads recorded workouts for the given range (cached per month).
    func loadWorkouts(from start: Date, to end: Date) async {
        let key = "\(engine.iso(start))…\(engine.iso(end))"
        guard !loadedRanges.contains(key) else { return }
        do {
            let list = DemoData.isOn
                ? DemoData.workouts(from: start, to: end, calendar: engine.calendar)
                : try await source.workouts(from: start, to: end)
            var byDay = workoutsByDay
            // Replace the whole range so deleted workouts disappear.
            var d = engine.calendar.startOfDay(for: start)
            while d < end { byDay[engine.iso(d)] = nil; d = engine.add(d, days: 1) }
            for w in list { byDay[engine.iso(w.start), default: []].append(w) }
            for k in byDay.keys { byDay[k]?.sort { $0.start < $1.start } }
            workoutsByDay = byDay
            loadedRanges.insert(key)
        } catch {
            log.error("Workout load failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Forgets every recorded workout, not just which ranges were loaded. Clearing only the
    /// range list left the old workouts drawn on the calendar until something happened to
    /// reload that month — which, switching into demo mode, meant real sessions on screen.
    func invalidateWorkouts() {
        loadedRanges.removeAll()
        workoutsByDay = [:]
    }

    /// Demo mode was turned on or off: the plan itself may swap (someone with no plan of their
    /// own borrows the demo one) and every recorded workout belongs to the other mode.
    func demoModeChanged() {
        invalidateWorkouts()
        objectWillChange.send()
    }

    // MARK: - Changes from the Coach chat

    /// Applies an approved proposal: lasting rules plus any one-off day changes.
    func apply(_ proposal: PlanProposal) {
        if !proposal.rules.isEmpty { rules.add(proposal.rules) }
        for d in proposal.days { chatDays[d.date] = PlanUpdate.DayChange(sessions: d.sessions, reason: d.reason, changedSessions: true) }
        Self.saveChatDays(chatDays)
        log.info("Applied chat proposal: \(proposal.rules.count, privacy: .public) rules, \(proposal.days.count, privacy: .public) days")
    }

    func clearChatDays() {
        chatDays = [:]
        Self.saveChatDays(chatDays)
    }

    private static var chatDaysURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("chat-days.json")
    }

    private static func loadChatDays() -> [String: PlanUpdate.DayChange] {
        guard let data = try? Data(contentsOf: chatDaysURL) else { return [:] }
        return (try? JSONDecoder().decode([String: PlanUpdate.DayChange].self, from: data)) ?? [:]
    }

    private static func saveChatDays(_ d: [String: PlanUpdate.DayChange]) {
        guard let data = try? JSONEncoder().encode(d) else { return }
        try? FileManager.default.createDirectory(at: chatDaysURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: chatDaysURL, options: [.atomic, .completeFileProtection])
    }

    // MARK: - Claude update (max one request per minute)

    func secondsUntilNextUpdate(now: Date = .now) -> Int {
        RateLimit.secondsRemaining(last: lastRequestAt, now: now)
    }

    func requestUpdate(dashboard: DashboardModel, calendar: CalendarSync? = nil, weather: WeatherModel? = nil) async {
        errorText = nil
        infoText = nil
        let wait = secondsUntilNextUpdate()
        guard wait == 0 else {
            infoText = "Claude updated less than a minute ago — next update in \(wait) s."
            return
        }
        guard !isUpdating else { return }
        guard let setup = LLMFactory.current(maxTokens: 4000) else {
            errorText = "Add your API key in Settings to get plan updates."
            return
        }

        // Count the attempt before calling, so failures can't be retried faster than once a minute.
        let now = Date.now
        lastRequestAt = now
        UserDefaults.standard.set(now, forKey: Self.lastRequestKey)
        isUpdating = true
        defer { isUpdating = false }

        let defaults = UserDefaults.standard
        let includeHealth = defaults.object(forKey: AppSettings.includeHealthKey) as? Bool ?? true
        let profile = defaults.string(forKey: AppSettings.profileKey) ?? AppSettings.defaultProfile
        let e = engine
        let rx = prescriber
        let today = e.calendar.startOfDay(for: now)
        let names = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
        let planned = (0..<PlanAdjuster.windowDays).map { i -> PlanAdjuster.DayInput in
            let d = e.add(today, days: i)
            var list = e.sessions(on: d).map { rx.prescribe($0, on: d) }
            list += custom.forDay(e.iso(d)).map { merged($0.planSession(), on: d, rx: rx) }
            return .init(date: e.iso(d), day: names[e.jsDay(d)], sessions: list)
        }

        var summary: String?
        var recent: [String] = []
        if includeHealth {
            await dashboard.ensureLoaded()
            summary = dashboard.data.map { CoachContext.healthSummary($0) }
            let weekAgo = e.add(today, days: -7)
            if let list = try? await source.workouts(from: weekAgo, to: e.add(today, days: 1)) {
                recent = list.reversed().map(CoachContext.workoutLine)
            }
        }

        await weather?.refresh()
        let days = (0..<PlanAdjuster.windowDays).map { e.add(today, days: $0) }
        let calendarText = calendar?.describe(days: PlanAdjuster.windowDays, from: today, calendar: e.calendar)
        let weatherText = weather?.forecast?.describe(days: days, calendar: e.calendar)
        let addedLines = custom.upcoming(from: e.iso(today)).prefix(12).map { $0.line() }
        let user = PlanAdjuster.userMessage(engine: e, today: today, planned: planned, profile: profile,
                                            healthSummary: summary, recentWork: recent,
                                            calendarText: calendarText, weatherText: weatherText,
                                            added: Array(addedLines),
                                            effortText: AppServices.shared.review.journal.effortSummary())
        do {
            let data = try await setup.client.runTool(system: PlanAdjuster.systemPrompt(engine: e),
                                                      user: user, tool: PlanAdjuster.tool)
            let parsed = try PlanAdjuster.parse(data, window: Set(planned.map(\.date)), model: setup.model, now: now)
            update = parsed
            Self.saveUpdate(parsed)
            log.info("Plan update: \(parsed.days.count, privacy: .public) days changed")
        } catch {
            errorText = error.localizedDescription
            log.error("Plan update failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Removes Claude's changes, back to the plan as written.
    func clearUpdate() {
        update = nil
        try? FileManager.default.removeItem(at: Self.updateURL)
    }

    // MARK: - Persistence (Application Support, complete file protection)

    private static var updateURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return dir.appendingPathComponent("plan-update.json")
    }

    private static func loadUpdate() -> PlanUpdate? {
        guard let data = try? Data(contentsOf: updateURL) else { return nil }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return try? dec.decode(PlanUpdate.self, from: data)
    }

    private static func saveUpdate(_ u: PlanUpdate) {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        guard let data = try? enc.encode(u) else { return }
        let url = updateURL
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: [.atomic, .completeFileProtection])
    }

    /// Past days drop out of Claude's update; the plan itself never changes history.
    private func pruneUpdate() {
        guard var u = update else { return }
        let today = engine.iso(.now)
        u.days = u.days.filter { $0.key >= today }
        update = u
    }
}
