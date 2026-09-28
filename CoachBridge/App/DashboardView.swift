import Charts
import SwiftUI

/// The first tab. Training comes first — where you are in the season, how this week is going,
/// what's next — then a Today section with recovery and the day's numbers, then the trends.
struct DashboardView: View {
    @EnvironmentObject private var dashboard: DashboardModel
    @EnvironmentObject private var plan: PlanModel
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        // Hoisted: every card below reads the engine, and `day(_:)` for the whole week.
        let engine = plan.engine
        let today = engine.calendar.startOfDay(for: .now)
        let monday = engine.monday(of: today)
        let week = (0..<7).map { plan.day(engine.add(monday, days: $0)) }
        let upcoming = (0..<8).map { plan.day(engine.add(today, days: $0)) }

        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    if plan.needsSetup {
                        SetupPromptCard()
                    } else {
                        SeasonCard(engine: engine, today: today, training: dashboard.data?.recentTraining)
                        ThisWeekCard(days: week, today: today)
                        UpNextCard(days: upcoming, today: today)
                        if let training = dashboard.data?.recentTraining {
                            ProjectionsCard(engine: engine, isoToday: engine.iso(today), training: training)
                        }
                    }
                    if let d = dashboard.data {
                        if let load = d.load, !load.points.isEmpty { FitnessCard(load: load) }
                        WeeklyLoadCard(loads: d.weekly, ignored: d.ignoredLongSessions)
                    }

                    SectionTitle("Today")
                    if !plan.needsSetup, let day = week.first(where: { $0.date == today }) {
                        TodaySessionsCard(day: day)
                    }
                    if let d = dashboard.data {
                        RecoveryCard(signal: d.recovery)
                        StatGrid(record: d.today, rhrBaseline: Stats.mean(d.rhr.dropLast().map(\.value)))

                        SectionTitle("Trends")
                        TrendCard(title: "Resting heart rate", unit: "bpm", points: d.rhr,
                                  rolling: nil, showAverage: true,
                                  caption: "Daily resting HR, last 4 weeks. Dashed line: 4-week average.")
                        TrendCard(title: "Heart rate variability", unit: "ms", points: d.hrv,
                                  rolling: d.hrvRolling, showAverage: false,
                                  caption: "Dots: daily mean (mostly daytime readings). Line: 7-day average.")
                        RecentWorkoutsCard(workouts: d.recent)
                        Text("Updated \(d.generatedAt.formatted(date: .omitted, time: .shortened))")
                            .font(.caption).foregroundStyle(.secondary)
                    } else if dashboard.isLoading {
                        ProgressView("Reading Health…").padding(.top, 40)
                    } else if let err = dashboard.errorText {
                        ContentUnavailableView("Couldn't read Health data", systemImage: "heart.slash",
                                               description: Text(err))
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 24)
            }
            .screenBackground(Palette.Tab.today)
            .softScrollEdges()
            .navigationTitle("Dashboard")
            .navigationDestination(for: PlanRoute.self) { route in
                switch route {
                case .session(let s, let d, let change, let slot): SessionDetailView(session: s, date: d, change: change, slot: slot)
                case .workout(let w): WorkoutDetailView(summary: w)
                }
            }
            .refreshable {
                await dashboard.refresh()
                await plan.loadWorkouts(from: monday, to: engine.add(monday, days: 7))
            }
            .task { await plan.loadWorkouts(from: monday, to: engine.add(monday, days: 7)) }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { Task { await dashboard.ensureLoaded() } }
            }
        }
    }
}

private struct SectionTitle: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.title2.bold())
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 8)
            .accessibilityAddTraits(.isHeader)
    }
}

// MARK: - Training

private struct SetupPromptCard: View {
    var body: some View {
        Card("Set up your plan", icon: "figure.run", tint: Palette.series1) {
            Text("Tell Coach Bridge what you're training for and how much time you have, and this page fills with your season, your week and what's next.")
                .font(.subheadline).foregroundStyle(.secondary)
            NavigationLink {
                ProfileSetupView()
            } label: {
                Label("Set up my plan", systemImage: "arrow.right.circle.fill").font(.headline)
            }
        }
    }
}

/// Where you are in the season: countdown, phase, and the whole plan as one ribbon.
private struct SeasonCard: View {
    let engine: PlanEngine
    let today: Date
    /// Nil until the dashboard has loaded; then projections come from it.
    let training: [WorkoutSummary]?

    var body: some View {
        let ph = engine.phase(for: today)
        let days = engine.daysToRace(from: today)
        let named = engine.blueprint.hasEvent || !engine.profile.eventName.isEmpty
        Card(named ? engine.raceName : "Your plan", icon: "flag.checkered",
             tint: Palette.color(forPhase: ph.id)) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("\(days)").font(.system(size: 40, weight: .bold, design: .rounded)).monospacedDigit()
                Text(named ? "days to go" : "days left in the plan")
                    .font(.subheadline).foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
            .accessibilityElement(children: .combine)
            if let pw = engine.phaseWeek(today) { PhaseChip(week: pw) }
            // Shown in its own card below; used here so the race-day fuel follows it.
            let projection = training.flatMap { RaceProjection.make(event: engine.profile.eventKind, recent: $0) }
            PhaseRibbon(engine: engine, date: today)
            Text(ph.focus).font(.subheadline).foregroundStyle(.secondary)
            if named, let race = RaceDayPlan.make(event: engine.profile.eventKind, raceName: engine.raceName,
                                                  ftp: engine.settings.ftpWatts, lthr: engine.settings.lthrBpm,
                                                  projection: projection) {
                NavigationLink {
                    RaceDayView(plan: race, projection: projection)
                } label: {
                    Label("Race-day plan", systemImage: "flag.checkered")
                        .font(.subheadline.weight(.semibold))
                }
            }
        }
    }
}

/// Projected finish times for every race on the calendar with a known distance, split by sport,
/// so you can see which leg is costing time — and which legs are only typical times because
/// there isn't enough recent training to go on.
private struct ProjectionsCard: View {
    let engine: PlanEngine
    let isoToday: String
    let training: [WorkoutSummary]

    private struct Race: Identifiable {
        let id: String
        let name: String
        let dateISO: String?
        let kind: EventKind
        let projection: RaceProjection
    }

    var body: some View {
        let p = engine.profile
        let named = engine.blueprint.hasEvent || !p.eventName.isEmpty
        var races: [Race] = []
        if p.eventKind != .general, let proj = RaceProjection.make(event: p.eventKind, recent: training) {
            races.append(Race(id: "goal", name: named ? engine.raceName : p.eventKind.label,
                              dateISO: engine.blueprint.hasEvent ? engine.raceISO : nil, kind: p.eventKind, projection: proj))
        }
        let others = p.events.filter { $0.isRace && $0.dateISO >= isoToday }.sorted { $0.dateISO < $1.dateISO }
        for e in others {
            if let k = e.kind, let proj = RaceProjection.make(event: k, recent: training) {
                races.append(Race(id: e.id.uuidString, name: e.title, dateISO: e.dateISO, kind: k, projection: proj))
            }
        }
        let missing = others.filter { $0.kind == nil }

        return Group {
            if !races.isEmpty || !missing.isEmpty {
                Card("Projected times", icon: "stopwatch", tint: Palette.series7) {
                    ForEach(races) { race in
                        raceBlock(race)
                        if race.id != races.last?.id || !missing.isEmpty { Divider() }
                    }
                    ForEach(missing) { e in
                        HStack {
                            Text(e.title).font(.subheadline.weight(.semibold))
                            Spacer()
                            Text("Add a distance in Your training").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Text("From your last eight weeks: median swim pace, your quicker rides, and your best run carried to race distance, slowed for running off the bike. \"Typical\" legs don't have enough recent workouts yet.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func raceBlock(_ race: Race) -> some View {
        let proj = race.projection
        let r = proj.range
        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(race.name).font(.subheadline.weight(.semibold))
                    Text([race.dateISO.map { AthleteProfile.date($0).formatted(.dateTime.month(.abbreviated).day().year()) },
                          race.kind.label].compactMap { $0 }.joined(separator: " · "))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 1) {
                    Text(RaceProjection.clock(proj.total)).font(.title3.bold().monospacedDigit())
                    Text("\(RaceProjection.clock(r.lowerBound))–\(RaceProjection.clock(r.upperBound))")
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
            }
            .accessibilityElement(children: .combine)
            ForEach(proj.legs) { leg in
                HStack(spacing: 8) {
                    Image(systemName: leg.sport.symbol)
                        .foregroundStyle(Palette.color(for: leg.sport))
                        .frame(width: 22)
                    Text(leg.label).font(.subheadline)
                    if leg.basis == .typical {
                        Text("typical").font(.caption2.weight(.semibold))
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(Color.secondary.opacity(0.15), in: Capsule())
                    }
                    Spacer()
                    Text(RaceProjection.clock(leg.seconds)).font(.subheadline.monospacedDigit())
                }
                .accessibilityElement(children: .combine)
            }
            if proj.transitions > 0 {
                HStack(spacing: 8) {
                    Image(systemName: "arrow.left.arrow.right").foregroundStyle(.secondary).frame(width: 22)
                    Text("Transitions").font(.subheadline)
                    Spacer()
                    Text(RaceProjection.clock(proj.transitions)).font(.subheadline.monospacedDigit()).foregroundStyle(.secondary)
                }
            }
        }
    }
}

/// This week against the plan: hours, and a day-by-day strip of what's done.
private struct ThisWeekCard: View {
    let days: [DayPlan]
    let today: Date

    private struct Day: Identifiable {
        let id: String
        let letter: String
        let planned: Bool
        let done: Bool
        let isToday: Bool
        let isPast: Bool
        let label: String
    }

    var body: some View {
        let training = { (d: DayPlan) in d.sessions.filter { $0.kind != .rest } }
        let plannedMin = days.flatMap(training).compactMap { $0.rx?.durationMin }.reduce(0, +)
        let doneMin = days.flatMap(\.done).reduce(0) { $0 + Int($1.duration / 60) }
        let left = days.filter { $0.date >= today && $0.done.isEmpty }.flatMap(training).count
        let strip = days.map { d in
            Day(id: d.iso,
                letter: String(d.date.formatted(.dateTime.weekday(.narrow))),
                planned: !training(d).isEmpty, done: !d.done.isEmpty,
                isToday: d.date == today, isPast: d.date < today,
                label: d.date.formatted(.dateTime.weekday(.wide)) + ": "
                    + (!d.done.isEmpty ? "done" : training(d).isEmpty ? "rest" : d.date < today ? "missed" : "planned"))
        }

        Card("This week", icon: "chart.bar.fill", tint: Palette.series1) {
            HStack(alignment: .firstTextBaseline) {
                Text(Fmt.hours(doneMin)).font(.title2.bold()).monospacedDigit()
                Text("of \(Fmt.hours(plannedMin)) planned").font(.subheadline).foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
            .accessibilityElement(children: .combine)
            ProgressView(value: Double(min(doneMin, max(plannedMin, 1))), total: Double(max(plannedMin, 1)))
                .tint(Palette.series1)
                .accessibilityLabel("Hours done this week")
            HStack(spacing: 0) {
                ForEach(strip) { d in
                    VStack(spacing: 5) {
                        Text(d.letter)
                            .font(.caption2.weight(d.isToday ? .bold : .regular))
                            .foregroundStyle(d.isToday ? Palette.series1 : .secondary)
                        ZStack {
                            if d.done {
                                Circle().fill(Palette.good)
                                Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundStyle(.white)
                            } else if d.planned {
                                Circle().strokeBorder(d.isPast ? Color.secondary.opacity(0.4) : Palette.series1, lineWidth: 2)
                            } else {
                                Circle().fill(Color.secondary.opacity(0.15))
                            }
                        }
                        .frame(width: 22, height: 22)
                    }
                    .frame(maxWidth: .infinity)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(d.label)
                }
            }
            Text(left == 0 ? "Nothing left planned this week." : "\(left) session\(left == 1 ? "" : "s") left this week.")
                .font(.footnote).foregroundStyle(.secondary)
        }
    }
}

/// The next few sessions, each opening the editor.
private struct UpNextCard: View {
    @EnvironmentObject private var calendarSync: CalendarSync
    let days: [DayPlan]
    let today: Date

    private struct Item: Identifiable {
        let id: String
        let session: PlanSession
        let day: DayPlan
        let slot: DateInterval?
    }

    var body: some View {
        let items = days.flatMap { day in
            day.sessions.enumerated()
                .filter { $0.element.kind != .rest && !(day.date == today && !day.done.isEmpty) }
                .map { Item(id: "\(day.iso)#\($0.offset)", session: $0.element, day: day,
                            slot: calendarSync.slot(for: day, index: $0.offset)) }
        }
        .filter { $0.day.date > today || ($0.slot?.end ?? .distantFuture) > .now }
        .prefix(3)

        Card("Coming up", icon: "calendar", tint: Palette.series3) {
            if items.isEmpty {
                Text("Nothing planned in the next week.").font(.subheadline).foregroundStyle(.secondary)
            }
            ForEach(Array(items)) { item in
                NavigationLink(value: PlanRoute.session(item.session, item.day.date, item.day.change, item.slot)) {
                    HStack(spacing: 12) {
                        Image(systemName: item.session.kind.symbol)
                            .font(.title3)
                            .foregroundStyle(Palette.color(for: item.session.kind))
                            .frame(width: 30)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.session.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                            Text(when(item)).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                        if let m = item.session.rx?.durationMin {
                            Text(Fmt.hours(m)).font(.subheadline.monospacedDigit()).foregroundStyle(.secondary)
                        }
                        Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func when(_ item: Item) -> String {
        let cal = Calendar.current
        let day = cal.isDate(item.day.date, inSameDayAs: today) ? "Today"
            : cal.isDate(item.day.date, inSameDayAs: cal.date(byAdding: .day, value: 1, to: today)!) ? "Tomorrow"
            : item.day.date.formatted(.dateTime.weekday(.wide))
        guard let slot = item.slot else { return day }
        return "\(day) · \(slot.start.formatted(date: .omitted, time: .shortened))"
    }
}

/// Fitness, fatigue and form over six weeks, with today's form in words.
private struct FitnessCard: View {
    let load: TrainingLoad.Summary

    var body: some View {
        let today = load.today
        Card("Fitness & form", icon: "chart.line.uptrend.xyaxis", tint: Palette.series3) {
            HStack(alignment: .firstTextBaseline, spacing: 16) {
                stat("Fitness", today?.fitness, Palette.series1)
                stat("Fatigue", today?.fatigue, Palette.series5)
                stat("Form", today?.form, Palette.series3, signed: true)
                Spacer(minLength: 0)
            }
            Text(load.formLabel).font(.subheadline.weight(.semibold))
            Chart(load.points) { p in
                LineMark(x: .value("Day", p.day), y: .value("Load", p.fitness), series: .value("", "Fitness"))
                    .foregroundStyle(Palette.series1)
                LineMark(x: .value("Day", p.day), y: .value("Load", p.fatigue), series: .value("", "Fatigue"))
                    .foregroundStyle(Palette.series5.opacity(0.8))
            }
            .chartLegend(.hidden)
            .chartXAxis { AxisMarks(values: .stride(by: .weekOfYear)) { _ in AxisGridLine(); AxisValueLabel(format: .dateTime.month(.abbreviated).day()) } }
            .frame(height: 120)
            .accessibilityLabel("Fitness and fatigue over six weeks")
            Text("Fitness is your 6-week training load, fatigue the last week's; form is the difference going into today. Estimated \(load.method.label).")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func stat(_ label: String, _ v: Double?, _ color: Color, signed: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(v.map { signed ? String(format: "%+.0f", $0) : String(format: "%.0f", $0) } ?? "—")
                .font(.title3.bold().monospacedDigit()).foregroundStyle(color)
        }
        .accessibilityElement(children: .combine)
    }
}

/// Today's plan, and whether it's done.
private struct TodaySessionsCard: View {
    @EnvironmentObject private var calendarSync: CalendarSync
    let day: DayPlan

    var body: some View {
        let training = day.sessions.enumerated().filter { $0.element.kind != .rest }
        Card("Today's training", icon: "figure.mixed.cardio", tint: Palette.series2) {
            if training.isEmpty {
                Text("Rest day. Recovery is training too.").font(.subheadline).foregroundStyle(.secondary)
            }
            ForEach(training, id: \.offset) { i, s in
                NavigationLink(value: PlanRoute.session(s, day.date, day.change, calendarSync.slot(for: day, index: i))) {
                    SessionLine(session: s, slot: calendarSync.slot(for: day, index: i),
                                unplaced: calendarSync.isUnplaced(day, index: i))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            ForEach(day.done) { w in
                NavigationLink(value: PlanRoute.workout(w)) {
                    Label("\(w.name) · \(Fmt.minutes(w.duration))", systemImage: "checkmark.circle.fill")
                        .font(.subheadline).foregroundStyle(Palette.good)
                }
                .buttonStyle(.plain)
            }
        }
    }
}

// MARK: - Cards

private struct Card<Content: View>: View {
    let title: String?
    var icon: String? = nil
    var tint: Color? = nil
    let content: Content

    init(_ title: String? = nil, icon: String? = nil, tint: Color? = nil,
         @ViewBuilder content: () -> Content) {
        self.title = title
        self.icon = icon
        self.tint = tint
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let title {
                HStack(spacing: 8) {
                    if let icon {
                        Image(systemName: icon)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(tint ?? Palette.series1)
                    }
                    Text(title).font(.headline)
                }
            }
            content
        }
        .glassCard()
        .overlay(alignment: .topLeading) {
            // A short colored rule instead of a full wash of the panel.
            if let tint {
                Capsule().fill(tint).frame(width: 3, height: 22)
                    .padding(.leading, 5).padding(.top, 15)
            }
        }
    }
}

private struct RecoveryCard: View {
    let signal: RecoverySignal

    var body: some View {
        Card(tint: color) {
            HStack(spacing: 10) {
                Image(systemName: icon).font(.title2).foregroundStyle(color)
                Text(CoachContext.label(signal.level)).font(.title2.bold())
                Spacer()
                Text("Recovery").font(.subheadline).foregroundStyle(.secondary)
            }
            ForEach(signal.reasons, id: \.self) { r in
                Text(r).font(.subheadline).foregroundStyle(.secondary)
            }
            Text("A rough guide from resting HR and HRV against your own baseline, not a diagnosis.")
                .font(.caption2).foregroundStyle(.tertiary)
        }
    }

    private var icon: String {
        switch signal.level {
        case .good: return "checkmark.circle.fill"
        case .normal: return "minus.circle.fill"
        case .caution: return "exclamationmark.triangle.fill"
        case .unknown: return "questionmark.circle"
        }
    }

    private var color: Color { Palette.color(for: signal.level) }
}

private struct StatGrid: View {
    let record: DayRecord
    let rhrBaseline: Double?

    private let keys: [MetricKey] = [.rhr, .hrv, .sleep, .vo2, .steps, .exerciseMin, .activeCal, .weight]

    var body: some View {
        let present = keys.filter { record.metrics[$0] != nil }
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
            ForEach(present, id: \.self) { key in
                StatTile(key: key, value: record.metrics[key]!, note: note(for: key))
            }
        }
    }

    private func note(for key: MetricKey) -> String? {
        switch key {
        case .rhr:
            guard let base = rhrBaseline, let v = record.metrics[.rhr] else { return nil }
            let d = Int((v - base).rounded())
            return d == 0 ? "at 4-wk avg" : "\(d > 0 ? "+" : "−")\(abs(d)) vs 4-wk avg"
        case .steps, .exerciseMin, .activeCal: return "yesterday"
        case .hrv: return "overnight to noon"
        case .vo2, .weight: return "latest"
        default: return nil
        }
    }
}

private struct StatTile: View {
    let key: MetricKey
    let value: Double
    let note: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(key.title).font(.caption).foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(display).font(.title2.bold()).monospacedDigit()
                Text(key.unitLabel).font(.caption).foregroundStyle(.secondary)
            }
            if let note { Text(note).font(.caption2).foregroundStyle(.tertiary) }
        }
        .glassCard(radius: 14, padding: 12)
        .overlay(alignment: .leading) {
            Capsule().fill(Palette.color(for: key)).frame(width: 3, height: 20).padding(.leading, 5)
        }
    }

    private var display: String {
        key == .steps ? Int(value).formatted() : key.format(value)
    }
}

private struct TrendCard: View {
    let title: String
    let unit: String
    let points: [DailyPoint]
    let rolling: [DailyPoint]?
    let showAverage: Bool
    let caption: String

    @State private var selected: Date?

    private var average: Double? { Stats.mean(points.map(\.value)) }

    private var icon: String { showAverage ? "heart.fill" : "waveform.path.ecg" }
    private var tint: Color { showAverage ? Palette.series5 : Palette.series3 }

    private var selectedPoint: DailyPoint? {
        guard let selected else { return nil }
        return points.min { abs($0.day.timeIntervalSince(selected)) < abs($1.day.timeIntervalSince(selected)) }
    }

    var body: some View {
        Card(title, icon: icon, tint: tint) {
            if points.count < 2 {
                Text("Not enough data yet.").foregroundStyle(.secondary)
            } else {
                readout
                Chart {
                    if showAverage, let average {
                        RuleMark(y: .value("4-week average", average))
                            .foregroundStyle(Palette.muted.opacity(0.6))
                            .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
                    }
                    if let rolling {
                        ForEach(points) { p in
                            PointMark(x: .value("Day", p.day, unit: .day), y: .value(title, p.value))
                                .foregroundStyle(Palette.series1.opacity(0.45))
                                .symbolSize(28)
                        }
                        ForEach(rolling) { p in
                            LineMark(x: .value("Day", p.day, unit: .day), y: .value("7-day average", p.value))
                                .foregroundStyle(Palette.series1)
                                .lineStyle(StrokeStyle(lineWidth: 2))
                                .interpolationMethod(.monotone)
                        }
                    } else {
                        ForEach(points) { p in
                            LineMark(x: .value("Day", p.day, unit: .day), y: .value(title, p.value))
                                .foregroundStyle(Palette.series1)
                                .lineStyle(StrokeStyle(lineWidth: 2))
                                .interpolationMethod(.monotone)
                            PointMark(x: .value("Day", p.day, unit: .day), y: .value(title, p.value))
                                .foregroundStyle(Palette.series1)
                                .symbolSize(18)
                        }
                    }
                    if let s = selectedPoint {
                        RuleMark(x: .value("Selected", s.day, unit: .day))
                            .foregroundStyle(Palette.muted.opacity(0.4))
                    }
                }
                .chartYScale(domain: .automatic(includesZero: false))
                .chartXAxis {
                    AxisMarks(values: .stride(by: .day, count: 7)) { _ in
                        AxisGridLine().foregroundStyle(Color(.separator).opacity(0.5))
                        AxisValueLabel(format: .dateTime.month(.abbreviated).day())
                    }
                }
                .chartYAxis {
                    AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { _ in
                        AxisGridLine().foregroundStyle(Color(.separator).opacity(0.5))
                        AxisValueLabel()
                    }
                }
                .chartXSelection(value: $selected)
                .frame(height: 170)
                .accessibilityLabel(Text("\(title), last \(points.count) days"))
                Text(caption).font(.caption2).foregroundStyle(.tertiary)
            }
        }
    }

    @ViewBuilder private var readout: some View {
        if let s = selectedPoint {
            Text("\(s.day.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())): \(Int(s.value.rounded())) \(unit)")
                .font(.subheadline.monospacedDigit())
        } else if let last = points.last {
            Text("Latest \(Int(last.value.rounded())) \(unit)" + (average.map { " · 4-wk avg \(Int($0.rounded()))" } ?? ""))
                .font(.subheadline.monospacedDigit()).foregroundStyle(.secondary)
        }
    }
}

private struct WeeklyLoadCard: View {
    let loads: [WeeklyLoad]
    var ignored: Int = 0
    @Environment(\.calendar) private var calendar

    /// One bar per week for the whole window, including weeks with nothing in them, and a plain
    /// string category on the x axis. A date axis with a `.weekOfYear` unit sizes its bars from
    /// the data's own spread, so a sparse window drew one bar the width of the chart.
    private struct Column: Identifiable {
        let label: String
        let weekStart: Date
        let slices: [WeeklyLoad]
        var id: Date { weekStart }
        var total: Double { slices.reduce(0) { $0 + $1.hours } }
    }

    private var columns: [Column] {
        guard let first = loads.map(\.weekStart).min(), let last = loads.map(\.weekStart).max() else { return [] }
        let byWeek = Dictionary(grouping: loads, by: \.weekStart)
        var out: [Column] = []
        var w = calendar.startOfDay(for: first)
        while w <= last, out.count < 26 {
            let slices = (byWeek[w] ?? [])
                .filter { $0.hours > 0 }
                .sorted { sportOrder($0.sport) < sportOrder($1.sport) }
            out.append(Column(label: w.formatted(.dateTime.month(.defaultDigits).day()),
                              weekStart: w, slices: slices))
            guard let next = calendar.date(byAdding: .weekOfYear, value: 1, to: w) else { break }
            w = next
        }
        return out
    }

    private func sportOrder(_ s: Sport) -> Int { Sport.allCases.firstIndex(of: s) ?? 99 }

    private var thisWeek: Column? { columns.last }
    private var peak: Double { max(columns.map(\.total).max() ?? 0, 1) }

    /// Eight labels don't fit across a phone, so past six weeks show every other one.
    private var labelStride: Int { columns.count > 6 ? 2 : 1 }

    var body: some View {
        Card("Training hours per week", icon: "chart.bar.fill", tint: Palette.series2) {
            if columns.isEmpty {
                Text("No workouts in the last 8 weeks.").foregroundStyle(.secondary)
            } else {
                Chart {
                    ForEach(columns) { col in
                        ForEach(col.slices) { l in
                            BarMark(x: .value("Week", col.label),
                                    y: .value("Hours", l.hours),
                                    width: .ratio(0.62))
                                .foregroundStyle(by: .value("Sport", l.sport.rawValue))
                                .cornerRadius(3)
                        }
                    }
                }
                .chartForegroundStyleScale(domain: Sport.allCases.map(\.rawValue),
                                           range: Sport.allCases.map { Palette.color(for: $0) })
                .chartLegend(position: .top, alignment: .leading, spacing: 8)
                .chartXAxis {
                    AxisMarks(values: columns.map(\.label)) { value in
                        if let label = value.as(String.self),
                           let i = columns.firstIndex(where: { $0.label == label }),
                           i % labelStride == 0 || i == columns.count - 1 {
                            AxisValueLabel {
                                Text(label).font(.caption2)
                            }
                        }
                    }
                }
                .chartYAxis {
                    AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { _ in
                        AxisGridLine().foregroundStyle(Color(.separator).opacity(0.4))
                        AxisValueLabel()
                    }
                }
                .chartYScale(domain: 0...(peak * 1.15))
                .frame(height: 200)

                // Text table: the colors alone never carry the numbers.
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("This week").font(.caption.bold()).foregroundStyle(.secondary)
                        Spacer()
                        if let t = thisWeek, t.total > 0 {
                            Text(String(format: "%.1f h total", t.total))
                                .font(.caption.monospacedDigit().bold())
                        }
                    }
                    if let t = thisWeek, !t.slices.isEmpty {
                        ForEach(t.slices) { l in
                            HStack(spacing: 6) {
                                Circle().fill(Palette.color(for: l.sport)).frame(width: 8, height: 8)
                                Text(l.sport.rawValue).font(.caption)
                                Spacer()
                                Text(String(format: "%.1f h", l.hours)).font(.caption.monospacedDigit())
                            }
                        }
                    } else {
                        Text("No workouts yet").font(.caption).foregroundStyle(.secondary)
                    }
                }
                .padding(.top, 2)

                if ignored > 0 {
                    Label("\(ignored) session\(ignored == 1 ? "" : "s") longer than \(Int(Stats.maxSessionHours)) h left out — almost certainly a workout that was never ended in Health.",
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.caption2).foregroundStyle(Palette.warning)
                        .padding(.top, 4)
                }
            }
        }
    }
}

private struct RecentWorkoutsCard: View {
    let workouts: [WorkoutSummary]

    var body: some View {
        Card("Recent workouts", icon: "list.bullet.rectangle", tint: Palette.series7) {
            if workouts.isEmpty {
                Text("No recent workouts.").foregroundStyle(.secondary)
            }
            ForEach(workouts) { w in
                HStack(spacing: 12) {
                    Image(systemName: w.icon)
                        .frame(width: 28)
                        .foregroundStyle(Palette.color(for: w.sport))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(w.name).font(.subheadline.bold())
                        Text(w.start.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day().hour().minute()))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(detail(w)).font(.caption.monospacedDigit())
                        if let hr = w.avgHR {
                            Text("avg \(Int(hr.rounded())) bpm").font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }
                if w.id != workouts.last?.id { Divider() }
            }
        }
    }

    private func detail(_ w: WorkoutSummary) -> String {
        var parts = ["\(Int((w.duration / 60).rounded())) min"]
        if let m = w.distanceMeters, m > 0 { parts.append(DistanceFormat.string(meters: m, sport: w.sport)) }
        return parts.joined(separator: " · ")
    }
}
