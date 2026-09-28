import ActivityKit
import SwiftUI
import WidgetKit

@main
struct CoachBridgePhoneWidgets: WidgetBundle {
    var body: some Widget {
        TodayWidget()
        SessionLiveActivity()
    }
}

// MARK: - Today's workout, go / no-go

struct TodayEntry: TimelineEntry {
    let date: Date
    let glance: PhoneGlance?
}

struct TodayProvider: TimelineProvider {
    func placeholder(in context: Context) -> TodayEntry { TodayEntry(date: .now, glance: .placeholder) }

    func getSnapshot(in context: Context, completion: @escaping (TodayEntry) -> Void) {
        completion(TodayEntry(date: .now, glance: context.isPreview ? .placeholder : PhoneGlanceStore.read()))
    }

    /// The app reloads the widget whenever the plan or recovery changes. Otherwise refresh just
    /// after midnight, when "today" moves on.
    func getTimeline(in context: Context, completion: @escaping (Timeline<TodayEntry>) -> Void) {
        let midnight = Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: .now))!
        completion(Timeline(entries: [TodayEntry(date: .now, glance: PhoneGlanceStore.read())],
                            policy: .after(midnight.addingTimeInterval(60))))
    }
}

struct TodayWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: PhoneGlanceStore.widgetKind, provider: TodayProvider()) { entry in
            TodayWidgetView(glance: entry.glance)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Today's training")
        .description("Today's session, and whether to go as planned.")
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryRectangular, .accessoryInline, .accessoryCircular])
    }
}

struct TodayWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let glance: PhoneGlance?

    /// A glance from an earlier day is stale; say so instead of showing yesterday's plan.
    private var current: PhoneGlance? {
        guard let g = glance, Calendar.current.isDateInToday(g.generatedAt) else { return nil }
        return g
    }

    var body: some View {
        switch family {
        case .accessoryInline:
            if let g = current {
                Label("\(g.goNoGo.title)\(g.sessions.first.map { " · \($0.title)" } ?? "")", systemImage: g.goNoGo.symbol)
            } else {
                Label("Open Coach Bridge", systemImage: "figure.run")
            }
        case .accessoryCircular:
            ZStack {
                AccessoryWidgetBackground()
                Image(systemName: current?.goNoGo.symbol ?? "questionmark.circle")
                    .font(.title2)
                    .widgetAccentable()
            }
            .accessibilityLabel(current?.goNoGo.title ?? "Open Coach Bridge")
        case .accessoryRectangular:
            VStack(alignment: .leading, spacing: 1) {
                if let g = current {
                    Label(g.goNoGo.title, systemImage: g.goNoGo.symbol).font(.headline).widgetAccentable()
                    ForEach(Array(g.sessions.prefix(2).enumerated()), id: \.offset) { _, s in
                        Text(line(s)).font(.caption2).lineLimit(1)
                    }
                } else {
                    Text("Open Coach Bridge").font(.headline)
                    Text("to load today's plan").font(.caption2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        default:
            home
        }
    }

    @ViewBuilder
    private var home: some View {
        if let g = current {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: g.goNoGo.symbol).foregroundStyle(color(g.goNoGo))
                    Text(g.goNoGo.title).font(.headline).foregroundStyle(color(g.goNoGo))
                    Spacer(minLength: 0)
                    if g.isDemo { Text("Demo").font(.caption2.bold()).foregroundStyle(.orange) }
                }
                if g.sessions.isEmpty {
                    Text("Rest day").font(.subheadline.weight(.semibold))
                } else {
                    ForEach(Array(g.sessions.prefix(family == .systemSmall ? 1 : 2).enumerated()), id: \.offset) { _, s in
                        VStack(alignment: .leading, spacing: 1) {
                            Label(s.title, systemImage: s.symbol).font(.subheadline.weight(.semibold)).lineLimit(2)
                            Text(line(s)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            if family == .systemMedium, let i = s.intensity {
                                Text(i).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                    }
                }
                Spacer(minLength: 0)
                if family == .systemMedium {
                    Text(g.goNoGo.detail).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                } else if let phase = g.phaseLabel {
                    Text(phase).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
            }
        } else {
            VStack(alignment: .leading, spacing: 4) {
                Image(systemName: "figure.run").font(.title2)
                Text("Open Coach Bridge to load today's plan.").font(.caption)
            }
        }
    }

    private func line(_ s: PhoneGlance.Session) -> String {
        [s.start.map { $0.formatted(date: .omitted, time: .shortened) },
         s.minutes.map { $0 < 60 ? "\($0) min" : String(format: "%d:%02d h", $0 / 60, $0 % 60) }]
            .compactMap { $0 }.joined(separator: " · ")
    }

    private func color(_ v: GoNoGo) -> Color {
        switch v {
        case .go: return .green
        case .goEasy, .swapToEasy: return .orange
        default: return .secondary
        }
    }
}

// MARK: - Live Activity

struct SessionLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: SessionActivityAttributes.self) { context in
            LockScreenActivityView(context: context)
                .padding(14)
                .activityBackgroundTint(Color.black.opacity(0.25))
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Label(context.attributes.title, systemImage: context.attributes.symbol)
                        .font(.headline).lineLimit(1)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    ElapsedText(state: context.state).font(.title3.monospacedDigit().bold())
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(context.attributes.target).font(.caption).lineLimit(1)
                        if let every = context.attributes.fuelEveryMinutes {
                            Text("Fuel every \(every) min\(context.attributes.fuelText.map { " — \($0)" } ?? "")")
                                .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            } compactLeading: {
                Image(systemName: context.attributes.symbol)
            } compactTrailing: {
                ElapsedText(state: context.state).monospacedDigit().frame(maxWidth: 52)
            } minimal: {
                Image(systemName: context.attributes.symbol)
            }
        }
    }
}

/// Counts up from the start on its own — the system redraws a timer text without the app.
private struct ElapsedText: View {
    let state: SessionActivityAttributes.ContentState

    var body: some View {
        if let end = state.endedAt {
            Text(Duration.seconds(end.timeIntervalSince(state.startedAt)).formatted(.time(pattern: .hourMinuteSecond)))
        } else {
            Text(timerInterval: state.startedAt...Date.distantFuture, countsDown: false)
        }
    }
}

private struct LockScreenActivityView: View {
    let context: ActivityViewContext<SessionActivityAttributes>

    var body: some View {
        let a = context.attributes
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label(a.title, systemImage: a.symbol).font(.headline).lineLimit(1)
                Spacer()
                ElapsedText(state: context.state).font(.title2.monospacedDigit().bold())
            }
            Text(a.target).font(.subheadline).lineLimit(2)
            HStack(spacing: 12) {
                if let planned = a.plannedMinutes {
                    Label(planned < 60 ? "\(planned) min planned" : String(format: "%d:%02d h planned", planned / 60, planned % 60),
                          systemImage: "clock")
                }
                if let every = a.fuelEveryMinutes {
                    Label("Fuel every \(every) min", systemImage: "fork.knife")
                }
            }
            .font(.caption).foregroundStyle(.secondary)
            if let fuel = a.fuelText {
                Text(fuel).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
        }
    }
}
