import SwiftUI

struct RootView: View {
    @EnvironmentObject private var health: HealthAuthorizer
    @EnvironmentObject private var dashboard: DashboardModel
    @EnvironmentObject private var prompter: FeelPrompter
    @EnvironmentObject private var review: ReviewModel
    @AppStorage(Appearance.key) private var appearance = Appearance.system.rawValue
    @AppStorage(OnboardingView.key) private var onboarded = 0

    @State private var showOnboarding = false

    var body: some View {
        TabView {
            DashboardView()
                .tabItem { Label("Dashboard", systemImage: "gauge.with.needle") }
            ChatView()
                .tabItem { Label("Coach", systemImage: "bubble.left.and.text.bubble.right") }
            PlanCalendarView()
                .tabItem { Label("Plan", systemImage: "calendar") }
            TodayView()
                .tabItem { Label("Sync", systemImage: "arrow.triangle.2.circlepath") }
            SettingsView()
                .tabItem { Label("Settings", systemImage: "gearshape") }
        }
        .tint(Palette.series1)
        .minimizingTabBar()
        .preferredColorScheme(Appearance(rawValue: appearance)?.colorScheme)
        .fullScreenCover(isPresented: $showOnboarding) { OnboardingView() }
        // The Strava moment: open the app after a workout and it asks how it went.
        .sheet(item: $prompter.pending) { w in
            FeelSheet(workout: w, existing: review.feel(for: w.id)) { feel in
                Task { await review.answer(feel, for: w) }
            }
        }
        .onChange(of: dashboard.data?.generatedAt) { _, _ in
            if !showOnboarding { prompter.offerOnOpen() }
        }
        .task {
            // First run (or after a release that changes setup) gets the walkthrough, which
            // asks for Health itself. Otherwise ask straight away for anything new.
            if onboarded < OnboardingView.version {
                showOnboarding = true
            } else if health.authorization == .notRun {
                await health.requestAuthorization()
            }
            await dashboard.ensureLoaded()
        }
    }
}
