import Charts
import SwiftUI
import WorkoutKit

// MARK: - Planned session

/// One session, editable in place. Every field is a live control: on the athlete's own session
/// it edits that session; on a planned one the first change adopts it as theirs (fixed, and
/// planned around by Claude — the same rule as a session they add).
///
/// Edits save on the phone as you go and never call Claude on their own. The week is reworked
/// only when the athlete taps "Rework my week", so a string of small edits costs one request.
struct SessionDetailView: View {
    @EnvironmentObject private var weather: WeatherModel
    @EnvironmentObject private var watch: WatchScheduler
    @EnvironmentObject private var plan: PlanModel
    @EnvironmentObject private var dashboard: DashboardModel
    @EnvironmentObject private var calendarSync: CalendarSync
    @Environment(\.dismiss) private var dismiss
    let session: PlanSession
    let date: Date
    let change: PlanUpdate.DayChange?
    var slot: DateInterval? = nil

    /// The athlete's version. Nil while a planned session is untouched.
    @State private var draft: CustomSession?
    /// Edited since Claude last saw it — shows the rework button.
    @State private var unsent = false
    @State private var preview: WorkoutPlan?
    @State private var showPreview = false
    @State private var confirmDelete = false

    var body: some View {
        // Hoisted: `plan.engine` rebuilds the engine on every access.
        let engine = plan.engine
        let shown = displayed(engine: engine)
        let rx = shown.rx ?? Prescription()
        List {
            Section {
                if let c = change, draft == nil, !session.addedByAthlete {
                    Label(c.reason, systemImage: "sparkles").font(.subheadline).foregroundStyle(Palette.series7)
                }
                if let d = draft {
                    Label(d.replaces == nil
                          ? "Your session — Claude plans the week around it."
                          : "You edited this planned session, so it's yours now — Claude plans around it.",
                          systemImage: "person.fill.checkmark")
                        .font(.subheadline).foregroundStyle(Palette.series4)
                } else {
                    Label("Tap any field to change it. The session becomes yours and stays as you set it.",
                          systemImage: "hand.tap")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
            }

            SessionFields(session: editable(engine: engine), defaults: rx, calendar: engine.calendar)

            if unsent {
                Section {
                    Button {
                        Task { await rework() }
                    } label: {
                        HStack {
                            Label("Rework my week around this", systemImage: "sparkles")
                            Spacer()
                            if plan.isUpdating { ProgressView() }
                        }
                    }
                    .disabled(plan.isUpdating)
                } footer: {
                    Text("Your changes are saved. Claude only reworks the rest of the week when you ask — one request, at most once a minute.")
                }
            }

            if let slot, draft == nil {
                Section("When") {
                    row("Scheduled", "\(slot.start.formatted(date: .omitted, time: .shortened))–\(slot.end.formatted(date: .omitted, time: .shortened)) · in your Training calendar", "calendar")
                    forecast(at: slot.start)
                }
            } else if let d = draft, let start = Scheduler.time(d.startTime, on: engine.date(d.date), calendar: engine.calendar) {
                if weather.forecast?.at(start) != nil {
                    Section("Weather") { forecast(at: start) }
                }
            }

            if let tire = rideTirePressure(shown, engine: engine) {
                Section {
                    row("Tire pressure", "\(Int(tire.front)) psi front / \(Int(tire.rear)) psi rear  (\(String(format: "%.1f / %.1f bar", tire.front / TirePressure.psiPerBar, tire.rear / TirePressure.psiPerBar)))", "gauge.with.needle")
                    if let note = tire.note {
                        Label(note, systemImage: "cloud.rain").font(.caption).foregroundStyle(Palette.warning)
                    }
                } footer: {
                    Text(plan.profile.gear?.pressuresCustom == true
                         ? "Your pressures from Your training → Your bike."
                         : "Recommended from your weight, tires and rims — set your own in Your training → Your bike.")
                }
            }

            Section {
                row("Before", rx.fuelBefore, "sunrise")
                row("During", rx.fuelDuring, "drop.fill")
                row("After", rx.fuelAfter, "fork.knife")
            } header: {
                Text("Fueling")
            } footer: {
                Text("From the plan's gut-training table: 60 g/h in Base 1, 70–80 in Base 2, 80–90 in the build. One savory bite an hour, the Santa Cruz lesson.")
            }

            if let notes = rx.notes {
                Section("Plan notes") { Text(notes) }
            }

            if watch.isSupported, WatchScheduler.mapping(for: shown) != nil {
                Section {
                    Button {
                        preview = watch.previewPlan(shown, on: engine.date(draft?.date ?? engine.iso(date)), plan: plan)
                        showPreview = preview != nil
                    } label: {
                        Label("Preview & send to Apple Watch", systemImage: "applewatch")
                    }
                } footer: {
                    Text("Shows the session's steps and alerts, with an option to send it to the Workout app now. The week's sessions are already on your Watch under Workout → Scheduled.")
                }
            }

            if shown.kind != .rest {
                Section {
                    LiveActivityButton(title: shown.title, attributes: LiveSession.attributes(for: shown))
                } footer: {
                    Text("Shows this session, a running clock and your fuel stops on the Lock Screen and in the Dynamic Island, and on your Watch's Smart Stack.")
                }
            }

            if let d = draft {
                Section {
                    Button(d.replaces == nil ? "Delete session" : "Go back to the planned session", role: .destructive) {
                        confirmDelete = true
                    }
                } footer: {
                    if d.replaces != nil {
                        Text("Removes your edits and brings back the session the plan had for this day.")
                    }
                }
            }
        }
        .glassRows()
        .venueBackground(session: shown, iso: draft?.date ?? engine.iso(date),
                         accent: Palette.color(for: shown.kind))
        .navigationTitle(shown.kind.label)
        .keyboardDismissible()
        .navigationBarTitleDisplayMode(.inline)
        .modifier(WorkoutPreviewModifier(plan: preview, isPresented: $showPreview))
        .confirmationDialog("Remove your version of this session?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button(draft?.replaces == nil ? "Delete session" : "Go back to the plan", role: .destructive) { remove() }
        }
        .onAppear {
            if draft == nil, let id = session.customID {
                draft = plan.custom.sessions.first { $0.id == id }
            }
        }
        // Debounced save: typing a title writes once it pauses, not on every keystroke, which
        // would redraw the whole calendar behind this screen each time.
        .task(id: draft) {
            guard let d = draft, plan.custom.sessions.first(where: { $0.id == d.id }) != d.sanitized() else { return }
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            plan.custom.save(d)
        }
        .onDisappear {
            guard unsent, let d = draft else { return }
            plan.custom.save(d)                                     // flush a pending debounce
            Task { await AppServices.shared.syncSchedule() }        // free: calendar and Watch only
        }
    }

    // MARK: Editing

    /// The planned session as it would look once adopted — built on demand, stored only on the
    /// first real change.
    private func editable(engine: PlanEngine) -> Binding<CustomSession> {
        Binding {
            draft ?? CustomSession.adopting(session, on: engine.iso(date), startTime: slotTime(engine))
        } set: { new in
            draft = new
            unsent = true
        }
    }

    private func slotTime(_ engine: PlanEngine) -> String? {
        guard let s = slot?.start else { return nil }
        let c = engine.calendar.dateComponents([.hour, .minute], from: s)
        return String(format: "%02d:%02d", c.hour ?? 6, c.minute ?? 0)
    }

    /// What to show: the athlete's version with the plan's defaults filled in, or the planned session.
    private func displayed(engine: PlanEngine) -> PlanSession {
        guard let d = draft else { return session }
        return plan.merged(d.planSession(), on: engine.date(d.date), rx: Prescriber(engine: engine))
    }

    /// Pressure for this ride, eased if rain is likely (50%+) at the start.
    private func rideTirePressure(_ s: PlanSession, engine: PlanEngine) -> (front: Double, rear: Double, note: String?)? {
        guard let gear = plan.profile.gear else { return nil }
        let start = slot?.start ?? draft.flatMap { Scheduler.time($0.startTime, on: engine.date($0.date), calendar: engine.calendar) }
            ?? date
        let wet = (weather.forecast?.at(start)?.precipProb ?? 0) >= 50
        let healthKg = dashboard.data?.today.metrics[.weight].map { $0 * 0.453_592 }
        return gear.pressure(forRide: s, wet: wet, riderKg: healthKg)
    }

    private func rework() async {
        unsent = false
        if let d = draft { plan.custom.save(d) }
        await AppServices.shared.syncSchedule()
        await plan.requestUpdate(dashboard: dashboard, calendar: calendarSync, weather: weather)
        await AppServices.shared.syncSchedule()
    }

    private func remove() {
        guard let d = draft else { return }
        plan.custom.delete(d)
        unsent = false
        Task { await AppServices.shared.syncSchedule() }
        dismiss()
    }

    @ViewBuilder
    private func forecast(at start: Date) -> some View {
        if let w = weather.forecast?.at(start) {
            row("Forecast at start", WeatherText.hour(w), w.feelsF >= Forecast.heatThresholdF ? "thermometer.sun.fill" : "cloud.sun")
            if w.feelsF >= Forecast.heatThresholdF {
                Text("Feels like \(Int(w.feelsF.rounded()))°F at start. Plan rule: above ~90°F, go at first light or ride the Bayshore, and add ~250 ml fluid per hour.")
                    .font(.caption).foregroundStyle(Palette.warning)
            }
        }
    }

    @ViewBuilder
    private func row(_ label: String, _ value: String?, _ icon: String) -> some View {
        if let value, !value.isEmpty {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Image(systemName: icon).foregroundStyle(.secondary).frame(width: 20)
                VStack(alignment: .leading, spacing: 2) {
                    Text(label).font(.caption).foregroundStyle(.secondary)
                    Text(value)
                }
            }
        }
    }
}

/// Start / end the Live Activity for a session or race.
struct LiveActivityButton: View {
    @ObservedObject private var live = LiveSession.shared
    let title: String
    let attributes: SessionActivityAttributes

    var body: some View {
        if live.isRunning(title: title) {
            Button("End Live Activity", role: .destructive) { Task { await live.end() } }
        } else {
            Button {
                Task { await live.start(attributes) }
            } label: {
                Label("Start Live Activity", systemImage: "livephoto")
            }
        }
        if let e = live.errorText { Text(e).font(.footnote).foregroundStyle(.red) }
    }
}

// MARK: - Recorded workout

struct WorkoutDetailView: View {
    @EnvironmentObject private var plan: PlanModel
    @EnvironmentObject private var review: ReviewModel
    @EnvironmentObject private var dashboard: DashboardModel
    let summary: WorkoutSummary

    @State private var detail: WorkoutDetail?
    @State private var errorText: String?
    @State private var loading = true
    @State private var showFeel = false
    /// Set once the sheet has been offered for this workout, so it doesn't reappear on every
    /// redraw or when they deliberately skipped it.
    @State private var offeredFeel = false

    var body: some View {
        // `plannedMatch` builds a PlanEngine and a whole day, so it's computed once per render
        // and handed down rather than read from three places.
        let planned = plannedMatch
        let compare = comparison(with: planned)

        return List {
            Section {
                HStack(spacing: 12) {
                    Image(systemName: summary.icon).font(.title2)
                        .foregroundStyle(Palette.color(for: summary.sport)).frame(width: 36)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(summary.name).font(.title3.bold())
                        Text(summary.start.formatted(.dateTime.weekday(.wide).month(.abbreviated).day().hour().minute()))
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                }
            }

            Section("Summary") {
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], alignment: .leading, spacing: 12) {
                    ForEach(stats) { s in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(s.label).font(.caption).foregroundStyle(.secondary)
                            Text(s.value).font(.headline.monospacedDigit())
                        }
                    }
                }
                .padding(.vertical, 4)
            }

            if loading {
                Section { ProgressView("Reading Health…") }
            } else if let d = detail {
                if d.heartRate.count > 1 {
                    Section("Heart rate") {
                        SeriesChart(points: d.heartRate, unit: "bpm", color: Palette.series1,
                                    reference: plan.settings.lthrBpm.map { (Double($0), "LTHR") })
                    }
                }
                if let zones = d.zones, zones.contains(where: { $0.minutes > 0 }) {
                    Section {
                        ZoneBars(zones: zones)
                    } header: {
                        Text("Time in heart-rate zones")
                    } footer: {
                        Text("Zones from your LTHR (\(plan.settings.lthrBpm ?? 0) bpm) in Plan settings.")
                    }
                }
                if d.power.count > 1 {
                    Section(summary.sport == .bike ? "Power" : "Running power") {
                        SeriesChart(points: d.power, unit: "W", color: Palette.series2,
                                    reference: summary.sport == .bike ? plan.settings.ftpWatts.map { (Double($0), "FTP") } : nil)
                    }
                }
                if d.heartRate.count <= 1 && d.power.count <= 1 {
                    Section { Text("No heart rate or power samples were recorded for this workout.").foregroundStyle(.secondary) }
                }
            } else if let errorText {
                Section { Text(errorText).foregroundStyle(.red) }
            }

            Section {
                if let feel = review.feel(for: summary.id) {
                    FeelRow(feel: feel, sport: summary.sport) { showFeel = true }
                } else {
                    FeelPromptCard(sport: summary.sport) { showFeel = true }
                }
            } header: {
                Text("How it went")
            }

            if compare.hadPlan && !compare.lines.isEmpty {
                Section {
                    CompareRows(compare: compare)
                } header: {
                    Text("Planned versus actual")
                } footer: {
                    Text(compare.headline + " Duration counts as on plan within 10%, or five minutes, whichever is larger.")
                }
            }

            coachSection

            if let s = planned {
                Section {
                    NavigationLink(value: PlanRoute.session(s, summary.start, nil, nil)) {
                        SessionLine(session: s)
                    }
                    if let fuel = s.rx?.fuelDuring {
                        Label(fuel, systemImage: "drop.fill").font(.caption).foregroundStyle(.secondary)
                    }
                } header: {
                    Text("What the plan called for")
                }
            }
        }
        .screenBackground(Palette.color(for: summary.sport))
        .navigationTitle(summary.sport.rawValue)
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showFeel) {
            FeelSheet(workout: summary, existing: review.feel(for: summary.id)) { feel in
                let first = review.save(feel: feel, for: summary, dateISO: plan.engine.iso(summary.start))
                // Changing an earlier answer invalidates the note that was written from it.
                if !first { review.clearNote(for: summary.id) }
                AppServices.shared.watchLink.push()        // it's no longer waiting on the watch
                Task { await askCoach(force: !first) }
            }
        }
        .task {
            do {
                detail = try await AppServices.shared.source.workoutDetail(summary, lthr: plan.settings.lthrBpm)
                if detail == nil {
                    errorText = summary.origin.kind == .fitFile
                        ? "Imported from a FIT file\(summary.origin.name.map { " (\($0))" } ?? ""). Only the totals are kept, so there's no heart-rate chart."
                        : "This workout is no longer in Apple Health."
                }
            } catch {
                errorText = error.localizedDescription
            }
            loading = false
            offerFeelIfFresh()
        }
    }

    /// The coach's note, or the way to ask for one. Never generated just by opening the screen —
    /// a note costs a request, so it follows answering the question or tapping the button.
    @ViewBuilder
    private var coachSection: some View {
        Section {
            if let note = review.note(for: summary.id) {
                CoachNoteCard(note: note, sport: summary.sport)
                Menu {
                    Button("Ask again") { Task { await askCoach(force: true) } }
                } label: {
                    Label("Written by \(note.model)", systemImage: "ellipsis.circle")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } else if review.isGenerating(summary.id) {
                HStack(spacing: 10) {
                    ProgressView()
                    Text("Reading your session…").foregroundStyle(.secondary)
                }
            } else if review.canGenerate {
                Button {
                    Task { await askCoach() }
                } label: {
                    Label("Ask the coach about this session", systemImage: "text.bubble")
                }
            } else {
                Text("Add an API key in Settings and the coach can write about each session.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            if let e = review.errorText {
                Text(e).font(.footnote).foregroundStyle(.red)
            }
        } header: {
            Text("Coach's note")
        } footer: {
            if review.note(for: summary.id) == nil && review.canGenerate {
                Text("One request per session, then it's saved — reopening this screen doesn't spend another. Answering how it felt asks for the note automatically.")
            }
        }
    }

    /// Asks the question by itself for anything finished in the last two days, so a session logged
    /// this morning gets the prompt the way Strava does. Older workouts show the card instead of
    /// having a sheet thrown at them while the athlete is browsing history.
    private func offerFeelIfFresh() {
        guard !offeredFeel else { return }
        offeredFeel = true
        guard review.feel(for: summary.id) == nil,
              Date.now.timeIntervalSince(summary.start) < WorkoutFeel.askWindow else { return }
        showFeel = true
    }

    private func askCoach(force: Bool = false) async {
        let engine = plan.engine            // built fresh on every access, so take one copy
        let planned = plannedMatch
        await review.review(
            workout: summary,
            detail: detail,
            planned: planned,
            compare: comparison(with: planned),
            engine: engine,
            recovery: dashboard.data?.recovery,
            recentSameSport: (dashboard.data?.recent ?? []).filter { $0.sport == summary.sport },
            dateISO: engine.iso(summary.start),
            force: force)
    }

    /// What the plan asked for against what the watch recorded. Pure and local — no key needed.
    private func comparison(with planned: PlanSession?) -> SessionCompare {
        SessionCompare.make(planned: planned,
                            actualSeconds: summary.duration,
                            avgHR: summary.avgHR ?? detail.flatMap { Stats.mean($0.heartRate.map(\.value)) },
                            avgPower: detail?.avgPower)
    }

    struct Stat: Identifiable {
        let label: String
        let value: String
        var id: String { label }
    }

    private var stats: [Stat] {
        var s: [Stat] = [Stat(label: "Duration", value: Fmt.minutes(summary.duration))]
        if let m = summary.distanceMeters, m > 0 {
            s.append(Stat(label: "Distance", value: DistanceFormat.string(meters: m, sport: summary.sport)))
            let hours = summary.duration / 3600
            switch summary.sport {
            case .run:
                let perMile = summary.duration / 60 / (m / 1609.344)
                s.append(Stat(label: "Avg pace", value: String(format: "%d:%02d /mi", Int(perMile), Int((perMile - floor(perMile)) * 60))))
            case .bike where hours > 0:
                s.append(Stat(label: "Avg speed", value: String(format: "%.1f mph", m / 1609.344 / hours)))
            case .swim:
                let per100 = summary.duration / (m / 0.9144 / 100)
                s.append(Stat(label: "Pace", value: String(format: "%d:%02d /100yd", Int(per100) / 60, Int(per100) % 60)))
            default: break
            }
        }
        if let hr = summary.avgHR { s.append(Stat(label: "Avg HR", value: "\(Int(hr.rounded())) bpm")) }
        if let d = detail {
            if let v = d.maxHR { s.append(Stat(label: "Max HR", value: "\(Int(v.rounded())) bpm")) }
            if let v = d.avgPower { s.append(Stat(label: "Avg power", value: "\(Int(v.rounded())) W")) }
            if let v = d.maxPower { s.append(Stat(label: "Max power", value: "\(Int(v.rounded())) W")) }
            if let v = d.avgCadence { s.append(Stat(label: "Cadence", value: "\(Int(v.rounded())) rpm")) }
            if let v = d.activeKcal { s.append(Stat(label: "Active energy", value: "\(Int(v.rounded())) kcal")) }
            if let v = d.elevationGainMeters {
                s.append(Stat(label: "Elevation", value: DistanceFormat.usesImperial ? "\(Int((v * 3.28084).rounded())) ft" : "\(Int(v.rounded())) m"))
            }
        }
        return s
    }

    /// The planned session that day of the same sport, if any.
    private var plannedMatch: PlanSession? {
        let day = plan.day(summary.start)
        return day.sessions.first { s in
            switch (s.kind, summary.sport) {
            case (.swim, .swim), (.bike, .bike), (.run, .run): return true
            case (.lift, .other): return true
            default: return false
            }
        }
    }
}

private struct SeriesChart: View {
    let points: [TimePoint]
    let unit: String
    let color: Color
    let reference: (Double, String)?

    @State private var selected: Date?

    private var selectedPoint: TimePoint? {
        guard let selected else { return nil }
        return points.min { abs($0.time.timeIntervalSince(selected)) < abs($1.time.timeIntervalSince(selected)) }
    }

    var body: some View {
        let start = points.first!.time
        let avg = Stats.mean(points.map(\.value)) ?? 0
        VStack(alignment: .leading, spacing: 6) {
            if let p = selectedPoint {
                Text("\(Fmt.minutes(p.time.timeIntervalSince(start))) in: \(Int(p.value.rounded())) \(unit)")
                    .font(.subheadline.monospacedDigit())
            } else {
                Text("Avg \(Int(avg.rounded())) \(unit) · max \(Int((points.map(\.value).max() ?? 0).rounded())) \(unit)")
                    .font(.subheadline.monospacedDigit()).foregroundStyle(.secondary)
            }
            Chart {
                if let reference {
                    RuleMark(y: .value(reference.1, reference.0))
                        .foregroundStyle(Palette.muted.opacity(0.6))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
                        .annotation(position: .top, alignment: .leading) {
                            Text("\(reference.1) \(Int(reference.0))").font(.caption2).foregroundStyle(.secondary)
                        }
                }
                ForEach(points) { p in
                    LineMark(x: .value("Time", p.time), y: .value(unit, p.value))
                        .foregroundStyle(color)
                        .lineStyle(StrokeStyle(lineWidth: 1.5))
                }
                if let s = selectedPoint {
                    RuleMark(x: .value("Selected", s.time)).foregroundStyle(Palette.muted.opacity(0.4))
                }
            }
            .chartYScale(domain: .automatic(includesZero: false))
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: 4)) { v in
                    AxisGridLine().foregroundStyle(Color(.separator).opacity(0.5))
                    AxisValueLabel {
                        if let d = v.as(Date.self) { Text(Fmt.minutes(d.timeIntervalSince(start))) }
                    }
                }
            }
            .chartXSelection(value: $selected)
            .frame(height: 170)
        }
        .padding(.vertical, 4)
    }
}

private struct ZoneBars: View {
    let zones: [ZoneTime]

    var body: some View {
        let total = max(1, zones.reduce(0) { $0 + $1.minutes })
        VStack(spacing: 6) {
            ForEach(zones) { z in
                HStack(spacing: 8) {
                    Text("Z\(z.zone)").font(.caption.monospacedDigit()).frame(width: 24, alignment: .leading)
                    GeometryReader { geo in
                        RoundedRectangle(cornerRadius: 3)
                            .fill(Palette.series1.opacity(0.35 + 0.13 * Double(z.zone)))
                            .frame(width: max(2, geo.size.width * z.minutes / total))
                    }
                    .frame(height: 12)
                    Text("\(Int(z.minutes.rounded())) min").font(.caption.monospacedDigit())
                        .frame(width: 56, alignment: .trailing)
                }
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Plan settings

struct PlanSettingsView: View {
    @EnvironmentObject private var plan: PlanModel
    @EnvironmentObject private var calendarSync: CalendarSync
    @EnvironmentObject private var weather: WeatherModel
    @EnvironmentObject private var watch: WatchScheduler
    @Environment(\.dismiss) private var dismiss
    @AppStorage(AppSettings.chatCanEditPlanKey) private var chatCanEditPlan = true
    @State private var confirmRemove = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    if watch.isSupported {
                        Toggle("Send sessions to Apple Watch", isOn: $watch.enabled)
                        if watch.authorization == .denied {
                            Text("Scheduling is off for Coach Bridge. Turn it on in the Watch app → Workout → Scheduled Workouts, or Settings → Privacy & Security.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Button("Sync now") { Task { await AppServices.shared.syncSchedule() } }
                        if let s = watch.lastSummary { Text(s).font(.caption).foregroundStyle(.secondary) }
                        Button("Remove scheduled workouts", role: .destructive) { Task { await watch.removeAll() } }
                    } else {
                        Text("Scheduled workouts need an Apple Watch paired with this iPhone.").foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Apple Watch")
                } footer: {
                    Text("The next 7 days of placed sessions appear in the Workout app under Scheduled, with steps (warm-up, intervals, cool-down) and heart-rate or power alerts from each session's targets. Sessions need a time, so turn on the Training calendar or let the app suggest times.")
                }

                Section {
                    if calendarSync.hasAccess {
                        Toggle("Plan around my calendar", isOn: $calendarSync.readEnabled)
                        Toggle("Add sessions to a Training calendar", isOn: $calendarSync.writeEnabled)
                        if calendarSync.readEnabled {
                            DisclosureGroup("Calendars to read") {
                                ForEach(calendarSync.readableCalendars(), id: \.calendarIdentifier) { c in
                                    Toggle(isOn: Binding(get: { calendarSync.isIncluded(c) },
                                                         set: { calendarSync.setIncluded(c, $0) })) {
                                        HStack {
                                            Circle().fill(Color(cgColor: c.cgColor)).frame(width: 10, height: 10)
                                            Text(c.title)
                                        }
                                    }
                                }
                            }
                        }
                        Button("Sync now") { Task { await AppServices.shared.syncSchedule() } }
                        if let s = calendarSync.lastSummary { Text(s).font(.caption).foregroundStyle(.secondary) }
                        Button("Remove Training calendar", role: .destructive) { confirmRemove = true }
                    } else {
                        Button("Connect Calendar") { Task { await calendarSync.requestAccess() } }
                        if calendarSync.status == .denied {
                            Text("Calendar access is off. Turn it on in Settings → Privacy & Security → Calendars → Coach Bridge.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                } header: {
                    Text("Calendar")
                } footer: {
                    Text("Sessions land in free time (weekdays 4:30–8:30 pm or 5:30–8:45 am, weekends from 7 am) and go into a separate Training calendar. Move one in Calendar and the app keeps your time. When you refresh the Plan tab, event times and titles for the next week go to Claude; locations, notes and attendees never do.")
                }
                .confirmationDialog("Delete the Training calendar and all its sessions? Your other calendars aren't touched.",
                                    isPresented: $confirmRemove, titleVisibility: .visible) {
                    Button("Delete Training calendar", role: .destructive) { calendarSync.removeTrainingCalendar() }
                }

                Section {
                    TextField("Name", text: $weather.locationName)
                    LabeledContent("Latitude") {
                        TextField("32.63", value: $weather.latitude, format: .number.precision(.fractionLength(2)))
                            .keyboardType(.numbersAndPunctuation).multilineTextAlignment(.trailing)
                    }
                    LabeledContent("Longitude") {
                        TextField("-117.10", value: $weather.longitude, format: .number.precision(.fractionLength(2)))
                            .keyboardType(.numbersAndPunctuation).multilineTextAlignment(.trailing)
                    }
                    Button("Use my current location") { Task { await weather.useCurrentLocation() } }
                    if !weather.isConfigured {
                        Button("Use the coordinates above") { weather.confirmLocation() }
                            .disabled(weather.latitude == 0 && weather.longitude == 0)
                    } else {
                        Button("Clear location", role: .destructive) { weather.clearLocation() }
                    }
                    if let err = weather.errorText { Text(err).font(.caption).foregroundStyle(.red) }
                    LabeledContent("Source", value: "Apple Weather")
                } header: {
                    Text("Weather location")
                } footer: {
                    Text(weather.isConfigured
                         ? "Forecasts come from Apple Weather. Only these coordinates, rounded to about 1 km, are sent. \"Use my current location\" asks for your approximate position once; it isn't tracked."
                         : "No location set, so no forecast and no heat warnings. Tap \"Use my current location\", or type coordinates and confirm them.")
                }

                Section {
                    LabeledContent("FTP") {
                        TextField("watts", value: $plan.settings.ftpWatts, format: .number)
                            .keyboardType(.numberPad).multilineTextAlignment(.trailing)
                    }
                    LabeledContent("Threshold HR (LTHR)") {
                        TextField("bpm", value: $plan.settings.lthrBpm, format: .number)
                            .keyboardType(.numberPad).multilineTextAlignment(.trailing)
                    }
                } header: {
                    Text("Zones")
                } footer: {
                    Text("With these set, sessions show watts and bpm instead of \"by feel\". FTP comes from the week-one test; LTHR from a 30-minute run test or your Strava zones.")
                }

                Section {
                    NavigationLink { VenueLibraryView() } label: {
                        Label("Places and photos", systemImage: "photo.stack")
                    }
                } header: {
                    Text("Where you train")
                } footer: {
                    Text("Each day shows a photo of where that session happens. Add your own shots of the Bayshore, the Aquaplex or the pain cave; they stay on your phone.")
                }

                Section {
                    Toggle("Let chat change my plan", isOn: $chatCanEditPlan)
                    if !plan.rules.rules.isEmpty {
                        ForEach(plan.rules.rules) { r in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(r.summary).font(.subheadline)
                                Text(r.note).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .onDelete { idx in
                            for i in idx { plan.rules.delete(plan.rules.rules[i]) }
                            Task { await AppServices.shared.syncSchedule() }
                        }
                    }
                    if !plan.chatDays.isEmpty {
                        Button("Undo \(plan.chatDays.count) day\(plan.chatDays.count == 1 ? "" : "s") changed in chat") {
                            plan.clearChatDays()
                            Task { await AppServices.shared.syncSchedule() }
                        }
                    }
                } header: {
                    Text("Coach chat")
                } footer: {
                    Text(plan.rules.rules.isEmpty
                         ? "On, Claude can propose changes from the Coach tab — nothing is applied until you tap Apply. Lasting rules show up here, where you can swipe to remove them."
                         : "Swipe a rule away to drop it. Sessions you added yourself are never moved or removed by a rule.")
                }

                Section {
                    NavigationLink {
                        ProfileSetupView()
                    } label: {
                        Label("Your training", systemImage: "figure.run.square.stack")
                    }
                } header: {
                    Text("The plan itself")
                } footer: {
                    Text("Your event and date, hours, training days, classes, trips and races all live here — change any of them and the whole season rebuilds.")
                }
            }
            .screenBackground(Palette.Tab.plan)
            .navigationTitle("Plan settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { Button("Done") { dismiss() } }
        }
    }
}


/// Attaches the system workout preview only when there's a plan to show.
private struct WorkoutPreviewModifier: ViewModifier {
    let plan: WorkoutPlan?
    @Binding var isPresented: Bool

    func body(content: Content) -> some View {
        if let plan {
            content.workoutPreview(plan, isPresented: $isPresented)
        } else {
            content
        }
    }
}
