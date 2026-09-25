import SwiftUI
import WidgetKit

/// Complications. They read only `WatchGlance` — the next session and the race countdown — and
/// never health numbers, because they draw on a locked watch face.
@main
struct CoachBridgeWidgets: WidgetBundle {
    var body: some Widget {
        NextSessionWidget()
        CountdownWidget()
    }
}

struct GlanceEntry: TimelineEntry {
    let date: Date
    let glance: WatchGlance?
}

struct GlanceProvider: TimelineProvider {
    func placeholder(in context: Context) -> GlanceEntry { GlanceEntry(date: .now, glance: .placeholder) }

    func getSnapshot(in context: Context, completion: @escaping (GlanceEntry) -> Void) {
        completion(GlanceEntry(date: .now, glance: context.isPreview ? .placeholder : GlanceStore.read()))
    }

    /// The app reloads timelines whenever a new snapshot arrives. Between those, refresh after
    /// the next session starts (so it rolls on) or in an hour, whichever is sooner.
    func getTimeline(in context: Context, completion: @escaping (Timeline<GlanceEntry>) -> Void) {
        let g = GlanceStore.read()
        let hour = Date.now.addingTimeInterval(3600)
        let next = g?.nextStart.map { min($0.addingTimeInterval(60), hour) } ?? hour
        completion(Timeline(entries: [GlanceEntry(date: .now, glance: g)], policy: .after(max(next, .now.addingTimeInterval(300)))))
    }
}

struct NextSessionWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "next-session", provider: GlanceProvider()) { entry in
            NextSessionView(glance: entry.glance)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Next session")
        .description("Your next planned session and when it starts.")
        .supportedFamilies([.accessoryRectangular, .accessoryInline])
    }
}

struct NextSessionView: View {
    @Environment(\.widgetFamily) private var family
    let glance: WatchGlance?

    var body: some View {
        switch family {
        case .accessoryInline:
            if let t = glance?.nextTitle {
                Label("\(t)\(time.map { " · \($0)" } ?? "")", systemImage: glance?.nextSymbol ?? "figure.run")
            } else {
                Label("Rest day", systemImage: "bed.double.fill")
            }
        default:
            VStack(alignment: .leading, spacing: 1) {
                if let phase = glance?.phaseLabel {
                    Text(phase).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
                if let t = glance?.nextTitle {
                    Label(t, systemImage: glance?.nextSymbol ?? "figure.run")
                        .font(.headline).lineLimit(1).widgetAccentable()
                    Text([time, glance?.nextMinutes.map { "\($0) min" }].compactMap { $0 }.joined(separator: " · "))
                        .font(.caption2)
                } else {
                    Text(glance == nil ? "Open Coach Bridge" : "Rest day").font(.headline)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var time: String? {
        guard let start = glance?.nextStart else { return nil }
        return Calendar.current.isDateInToday(start)
            ? start.formatted(date: .omitted, time: .shortened)
            : start.formatted(.dateTime.weekday(.abbreviated).hour().minute())
    }
}

struct CountdownWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "race-countdown", provider: GlanceProvider()) { entry in
            CountdownView(glance: entry.glance)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Race countdown")
        .description("Days to your race.")
        .supportedFamilies([.accessoryCircular, .accessoryCorner])
    }
}

struct CountdownView: View {
    let glance: WatchGlance?

    var body: some View {
        ZStack {
            AccessoryWidgetBackground()
            VStack(spacing: -2) {
                Text(glance?.daysToRace.map(String.init) ?? "–")
                    .font(.system(.title3, design: .rounded).bold())
                    .minimumScaleFactor(0.6)
                    .widgetAccentable()
                Text("days").font(.system(size: 9))
            }
        }
        .accessibilityLabel(glance?.daysToRace.map { "\($0) days to \(glance?.raceName ?? "race day")" } ?? "No race set")
    }
}
