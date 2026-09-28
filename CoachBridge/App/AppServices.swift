import Foundation

/// One shared set of services for both the UI and background launches
/// (observer queries and BGAppRefreshTask can start the app with no UI).
@MainActor
final class AppServices {
    static let shared = AppServices()

    let health: HealthAuthorizer
    /// The one place data is read from. Models take this, never an `HKHealthStore`.
    let source: any HealthSource
    let fit: FITWorkoutStore
    let google: GoogleAuth
    let exporter: Exporter
    let dashboard: DashboardModel
    let chat: ChatModel
    let plan: PlanModel
    let calendar: CalendarSync
    let weather: WeatherModel
    let watch: WatchScheduler
    let venues: VenueStore
    let review: ReviewModel
    let prompter: FeelPrompter
    let watchLink: WatchLink

    private init() {
        health = HealthAuthorizer()
        google = GoogleAuth()
        fit = FITWorkoutStore()
        source = CombinedSource(health: HealthKitSource(store: health.store), fit: fit)
        exporter = Exporter(source: source, auth: google)
        dashboard = DashboardModel(source: source)
        chat = ChatModel()
        plan = PlanModel(source: source)
        dashboard.lthr = { [unowned plan] in plan.settings.lthrBpm }
        calendar = CalendarSync()
        weather = WeatherModel()
        watch = WatchScheduler()
        venues = VenueStore()
        review = ReviewModel()
        prompter = FeelPrompter()
        watchLink = WatchLink()
        // The journal's prune existed but was never called, so it grew forever.
        let cal = Calendar.current
        let today = cal.startOfDay(for: .now)
        review.journal.prune(before: AthleteProfile.iso(cal.date(byAdding: .year, value: -1, to: today)!))
        fit.prune(before: cal.date(byAdding: .year, value: -2, to: today)!)
    }

    /// Demo mode was turned on or off. Everything derived from Health has to be dropped and
    /// reloaded here, in one place: the dashboard's readings, the calendar's recorded workouts
    /// and the plan itself (a phone with no plan of its own borrows the demo one). Leaving any
    /// of it cached meant real numbers stayed on screen after the toggle.
    func demoModeChanged() async {
        plan.demoModeChanged()
        chat.clearContextCache()
        await dashboard.demoModeChanged()
        let today = Calendar.current.startOfDay(for: .now)
        await plan.loadWorkouts(from: Calendar.current.date(byAdding: .day, value: -45, to: today)!,
                                to: Calendar.current.date(byAdding: .day, value: 45, to: today)!)
        watchLink.push()        // the watch must switch to (or away from) demo data too
    }

    /// Imports FIT files picked in the app or opened from Files / the share sheet. Returns a
    /// line for the user. Each file is size-checked before it's read, and parsed defensively.
    func importFIT(_ urls: [URL]) async -> String {
        var added = 0, duplicates = 0
        var failures: [String] = []
        for url in urls {
            let scoped = url.startAccessingSecurityScopedResource()
            defer {
                if scoped { url.stopAccessingSecurityScopedResource() }
                // "Open in" copies the file into our Inbox; the totals are all we keep.
                if url.pathComponents.contains("Inbox") { try? FileManager.default.removeItem(at: url) }
            }
            do {
                let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                guard size <= FITParser.maxFileBytes else { throw FITParser.Failure.tooLarge }
                switch try fit.importFile(try Data(contentsOf: url)) {
                case .added(let n): added += n
                case .alreadyImported: duplicates += 1
                }
            } catch {
                failures.append("\(url.lastPathComponent): \(error.localizedDescription)")
            }
        }
        if added > 0 {
            plan.invalidateWorkouts()
            await dashboard.refresh(force: true)
            let today = Calendar.current.startOfDay(for: .now)
            await plan.loadWorkouts(from: Calendar.current.date(byAdding: .day, value: -45, to: today)!,
                                    to: Calendar.current.date(byAdding: .day, value: 45, to: today)!)
            watchLink.push()
        }
        var parts: [String] = []
        if added > 0 { parts.append("Imported \(added) session\(added == 1 ? "" : "s").") }
        if duplicates > 0 { parts.append("\(duplicates) file\(duplicates == 1 ? " was" : "s were") already imported.") }
        parts += failures
        return parts.isEmpty ? "Nothing to import." : parts.joined(separator: "\n")
    }

    /// Places sessions (calendar), then mirrors them to the Watch. One place to call after anything changes.
    func syncSchedule() async {
        await calendar.sync(plan: plan, weather: weather)
        await watch.sync(plan: plan, calendar: calendar)
        watchLink.push()
    }
}
