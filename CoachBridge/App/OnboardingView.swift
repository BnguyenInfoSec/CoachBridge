import SwiftUI

/// The first-run walkthrough: a full-screen set of slides that says what the app needs and
/// why, in order, with the two things that actually block it (Health, an API key) reachable
/// from the slide that explains them. Re-openable from Settings.
struct OnboardingView: View {
    /// Bumping this shows the walkthrough again after a release that changes the setup.
    static let version = 3
    static let key = "onboarding.completedVersion"

    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var health: HealthAuthorizer
    @EnvironmentObject private var chat: ChatModel
    @EnvironmentObject private var calendarSync: CalendarSync
    @EnvironmentObject private var watch: WatchScheduler
    @EnvironmentObject private var plan: PlanModel
    @AppStorage(Self.key) private var completed = 0

    @State private var page = 0
    @State private var showSetup = false

    private var steps: [Step] { Step.all }

    var body: some View {
        ZStack {
            AppBackground(accent: steps[min(page, steps.count - 1)].tint)

            VStack(spacing: 0) {
                TabView(selection: $page) {
                    ForEach(Array(steps.enumerated()), id: \.offset) { i, step in
                        SlideView(step: step, action: action(for: step))
                            .tag(i)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .never))

                dots
                controls
            }
        }
        .interactiveDismissDisabled()
        .sheet(isPresented: $showSetup) {
            NavigationStack { ProfileSetupView(isSetup: true) }
        }
    }

    // MARK: Chrome

    private var dots: some View {
        HStack(spacing: 6) {
            ForEach(steps.indices, id: \.self) { i in
                Capsule()
                    .fill(i == page ? Color.primary : Color.secondary.opacity(0.3))
                    .frame(width: i == page ? 18 : 6, height: 6)
                    .animation(.snappy, value: page)
            }
        }
        .padding(.bottom, 14)
        .accessibilityHidden(true)
    }

    private var controls: some View {
        HStack {
            Button("Skip") { finish() }
                .opacity(page == steps.count - 1 ? 0 : 1)
            Spacer()
            Button(page == steps.count - 1 ? "Start training" : "Next") {
                if page == steps.count - 1 {
                    finish()
                } else {
                    withAnimation { page += 1 }
                }
            }
            .glassButton(prominent: true)
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 28)
    }

    private func finish() {
        completed = Self.version
        dismiss()
    }

    /// The inline button a slide offers, when there's something to actually do on it.
    private func action(for step: Step) -> Action? {
        switch step.id {
        case "health":
            return Action(title: health.authorization == .notRun ? "Allow Health access" : "Health access requested",
                          done: health.authorization != .notRun) {
                Task { await health.requestAuthorization() }
            }
        case "key":
            return Action(title: chat.hasAPIKey ? "Key saved" : "I'll add it in Settings",
                          done: chat.hasAPIKey) {}
        case "plan":
            return Action(title: plan.needsSetup ? "Set up my plan" : "Plan is set up",
                          done: false) { showSetup = true }
        case "calendar":
            return Action(title: calendarSync.hasAccess ? "Calendar connected" : "Connect Calendar",
                          done: calendarSync.hasAccess) {
                Task { await calendarSync.requestAccess() }
            }
        default:
            return nil
        }
    }

    // MARK: Content

    struct Action {
        let title: String
        let done: Bool
        let run: () -> Void
    }

    struct Step {
        let id: String
        let symbol: String
        let title: String
        let body: String
        let tint: Color
        /// Shows the venue artwork instead of a symbol, at this time of day.
        var art: (String, TimeOfDay)? = nil

        static let all: [Step] = [
            Step(id: "welcome", symbol: "figure.run.circle.fill",
                 title: "Coach Bridge",
                 body: """
                 Your Apple Health data, your training plan, and a coach that can see both.

                 Five tabs: Today is your numbers, Coach is the chat, Plan is the calendar, Sync sends your data to Drive, Settings is everything else.
                 """,
                 tint: Palette.series1,
                 art: ("venue-bayshore-run", .morning)),

            Step(id: "health", symbol: "heart.text.square.fill",
                 title: "Read from Apple Health",
                 body: """
                 Resting heart rate, HRV, sleep, workouts — read only. The app never writes to Health and never deletes anything.

                 Say yes to everything on the next screen; anything you withhold simply shows as "not logged".
                 """,
                 tint: Palette.series5),

            Step(id: "key", symbol: "key.fill",
                 title: "Bring your own API key",
                 body: """
                 The coach runs on your own account, not a subscription to this app. Make a key at console.anthropic.com (or platform.openai.com), then paste it into Settings → Model provider.

                 Set a spend limit there too. A chat message runs about a cent.
                 """,
                 tint: Palette.series4),

            Step(id: "plan", symbol: "calendar",
                 title: "Tell it what you're training for",
                 body: """
                 A race and a date, the hours you train now, the days you can train, and what else is in your week — classes, shifts, trips.

                 From that it builds the whole season: phases counted back from race day, volume that ramps from where you actually are, a long day where you want it.
                 """,
                 tint: Palette.series3,
                 art: ("venue-mountain-road", .day)),

            Step(id: "yours", symbol: "person.fill.checkmark",
                 title: "Your sessions come first",
                 body: """
                 Tap + on the Plan tab to add your own — a 6 am group run, a race, anything. Those are fixed: the coach plans around them and never moves them.

                 Ask in Coach for a change ("swap Saturday's ride for a run") and you get a proposal to approve. Nothing changes until you tap Apply.
                 """,
                 tint: Palette.series7),

            Step(id: "calendar", symbol: "calendar.badge.clock",
                 title: "Book it in your calendar",
                 body: """
                 Sessions land in free time around what's already on your calendar, in their own Training calendar. Move one in Calendar and the app keeps your time.

                 With an Apple Watch, the next 7 days show up in the Workout app under Scheduled, with intervals and heart-rate or power alerts.
                 """,
                 tint: Palette.series2),

            Step(id: "places", symbol: "photo.stack",
                 title: "It looks like where you train",
                 body: """
                 Each day shows the place that session happens, lit for the actual time of day. Swap in your own photos under Plan settings → Places — they stay on your phone.
                 """,
                 tint: Palette.series3,
                 art: ("venue-la-jolla", .evening)),

            Step(id: "privacy", symbol: "lock.fill",
                 title: "Where your data goes",
                 body: """
                 Health data stays on the phone except for the summary sent with each coach message, and only while sharing is on — the chat menu shows exactly what was sent.

                 Chats and photos are stored on this iPhone with full file protection. The Drive export writes only to its own folder.
                 """,
                 tint: Palette.neutral),
        ]
    }
}

private struct SlideView: View {
    @EnvironmentObject private var weather: WeatherModel
    let step: OnboardingView.Step
    let action: OnboardingView.Action?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Spacer(minLength: 20)

            Group {
                if let (art, phase) = step.art {
                    VenueArtwork(venue: Venue(slot: VenueSlot.run, name: "", art: art),
                                 slot: VenueSlot.run, height: 220, phase: phase)
                        .frame(height: 220)
                        .frame(maxWidth: .infinity)
                        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                } else {
                    ZStack {
                        Circle().fill(step.tint.opacity(0.18)).frame(width: 150, height: 150)
                        Image(systemName: step.symbol)
                            .font(.system(size: 62, weight: .semibold))
                            .foregroundStyle(step.tint)
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 220)
                }
            }
            .padding(.bottom, 26)

            Text(step.title).font(.largeTitle.bold())
            Text(step.body)
                .font(.callout)
                .foregroundStyle(.secondary)
                .padding(.top, 10)
                .fixedSize(horizontal: false, vertical: true)

            if let action {
                Button {
                    action.run()
                } label: {
                    Label(action.title, systemImage: action.done ? "checkmark.circle.fill" : "arrow.right.circle")
                        .font(.subheadline.weight(.semibold))
                }
                .glassButton()
                .disabled(action.done)
                .padding(.top, 18)
            }

            Spacer(minLength: 20)
        }
        .padding(.horizontal, 28)
    }
}
