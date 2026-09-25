import Foundation

/// One shared set of services for both the UI and background launches
/// (observer queries and BGAppRefreshTask can start the app with no UI).
@MainActor
final class AppServices {
    static let shared = AppServices()

    let health: HealthAuthorizer
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

    private init() {
        health = HealthAuthorizer()
        google = GoogleAuth()
        exporter = Exporter(store: health.store, auth: google)
        dashboard = DashboardModel(store: health.store)
        chat = ChatModel()
        plan = PlanModel(store: health.store)
        calendar = CalendarSync()
        weather = WeatherModel()
        watch = WatchScheduler()
        venues = VenueStore()
        review = ReviewModel()
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
    }

    /// Places sessions (calendar), then mirrors them to the Watch. One place to call after anything changes.
    func syncSchedule() async {
        await calendar.sync(plan: plan, weather: weather)
        await watch.sync(plan: plan, calendar: calendar)
    }
}
