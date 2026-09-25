import SwiftUI
import UIKit

enum PlanRoute: Hashable {
    case session(PlanSession, Date, PlanUpdate.DayChange?, DateInterval?)
    case workout(WorkoutSummary)
}


/// Plan tab: month → week → day → session / recorded workout.
/// Pull to refresh reloads Health and asks Claude to update the coming week (max once a minute).
struct PlanCalendarView: View {
    @EnvironmentObject private var plan: PlanModel
    @EnvironmentObject private var dashboard: DashboardModel
    @EnvironmentObject private var calendarSync: CalendarSync
    @EnvironmentObject private var weather: WeatherModel
    @EnvironmentObject private var venues: VenueStore
    @AppStorage(AppSettings.planURLKey) private var planURL = AppSettings.defaultPlanURL

    enum Scale: String, CaseIterable { case month = "Month", week = "Week", day = "Day" }

    @State private var scale: Scale = .week
    @State private var selected = Calendar.current.startOfDay(for: .now)
    @State private var showSettings = false
    @State private var showPage = false
    @State private var showAdd = false
    /// First detent: the artwork opened up, plan pushed down. Second pull from there refreshes.
    @State private var peek = false
    @State private var refreshing = false
    /// While the page is pulled open, the athlete can flick through the four times of day.
    @State private var artPhase: TimeOfDay?
    /// Kept around and pre-armed; a generator created at the moment of impact often misses.
    /// Armed once the pull relaxes after opening, so the same gesture can't run straight on
    /// into a refresh.
    @State private var canRefresh = false
    @State private var showPlaces = false
    @State private var softTap = UIImpactFeedbackGenerator(style: .soft)
    @State private var firmTap = UIImpactFeedbackGenerator(style: .rigid)

    private var engine: PlanEngine { plan.engine }

    var body: some View {
        NavigationStack {
            GeometryReader { geo in
            ScrollView {
                VStack(spacing: 0) {
                    // The detent itself: empty space that lets the artwork through.
                    Color.clear.frame(height: peek ? geo.size.height * 0.64 : 0)

                VStack(alignment: .leading, spacing: 16) {
                    SeasonHeader(engine: engine, date: selected)
                    CoachUpdateCard()
                    Picker("View", selection: $scale) {
                        ForEach(Scale.allCases, id: \.self) { Text($0.rawValue) }
                    }
                    .pickerStyle(.segmented)
                    navigator
                    switch scale {
                    case .month:
                        MonthGrid(month: selected, selected: selected) { d in
                            selected = d
                            withAnimation { scale = .week }
                        }
                    case .week:
                        WeekList(monday: engine.monday(of: selected), selected: selected) { d in
                            selected = d
                            withAnimation { scale = .day }
                        }
                    case .day:
                        DayDetail(day: plan.day(selected))
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 24)
                }
            }
            .scrollBounceBehavior(.always)
            // The scroll view's own geometry, rather than inferring it from a GeometryReader
            // inside the content — that never reported reliably.
            .onScrollGeometryChange(for: CGFloat.self) { geo in
                geo.contentOffset.y + geo.contentInsets.top
            } action: { _, offset in
                handlePull(-offset)             // positive once dragged past the top
            }
            .venueBackground(session: backdropSession, iso: engine.iso(selected),
                             openness: peek ? 1 : 0, phase: peek ? artPhase : nil)
            .softScrollEdges()
            .overlay(alignment: .top) { if peek { peekOverlay(geo) } }
            .navigationTitle("Plan")
            .navigationDestination(for: PlanRoute.self) { route in
                switch route {
                case .session(let s, let d, let change, let slot): SessionDetailView(session: s, date: d, change: change, slot: slot)
                case .workout(let w): WorkoutDetailView(summary: w)
                }
            }
            .task(id: rangeKey) { await loadVisible() }
            .task {
                softTap.prepare()
                firmTap.prepare()
                await weather.refresh()
                if calendarSync.lastSync.map({ Date.now.timeIntervalSince($0) > 10 * 60 }) ?? true {
                    await AppServices.shared.syncSchedule()
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showAdd = true } label: { Image(systemName: "plus") }
                        .accessibilityLabel("Add your own session")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button("Refresh now", systemImage: "arrow.clockwise") { Task { await refresh() } }
                        Button("Plan settings", systemImage: "slider.horizontal.3") { showSettings = true }
                        if !planURL.isEmpty {
                            Button("Open my plan page", systemImage: "safari") { showPage = true }
                        }
                        if plan.update != nil {
                            Button("Undo Claude's changes", systemImage: "arrow.uturn.backward", role: .destructive) { plan.clearUpdate() }
                        }
                    } label: { Image(systemName: "ellipsis.circle") }
                }
            }
            .sheet(isPresented: $showPlaces) {
                NavigationStack { VenueLibraryView() }
            }
            .sheet(isPresented: $showAdd) { AddSessionSheet(defaultDate: selected) }
            .sheet(isPresented: $showSettings, onDismiss: {
                Task { await weather.refresh(); await AppServices.shared.syncSchedule() }
            }) { PlanSettingsView() }
            .fullScreenCover(isPresented: $showPage) {
                if let url = URL(string: planURL) { SafariView(url: url) { showPage = false }.ignoresSafeArea() }
            }
            }
        }
    }

    /// What sits over the artwork while the page is pulled down: where you are, and the four
    /// times of day the scene was drawn for. This is the artwork viewer — there isn't a
    /// separate screen for it.
    @ViewBuilder
    private func peekOverlay(_ geo: GeometryProxy) -> some View {
        VStack(spacing: 12) {
            Spacer(minLength: 0)

            if let slot = heroSlot {
                VStack(spacing: 3) {
                    Text(VenueSlot.label(slot).uppercased())
                        .font(.caption2.weight(.bold)).tracking(1.2)
                        .foregroundStyle(.white.opacity(0.75))
                    Text(heroVenue?.name ?? VenueSlot.label(slot))
                        .font(.title2.bold()).foregroundStyle(.white)
                    if let note = heroVenue?.note, !note.isEmpty {
                        Text(note).font(.caption).foregroundStyle(.white.opacity(0.8))
                    }
                }
                .multilineTextAlignment(.center)
                .shadow(radius: 8)

                if heroVenue?.art != nil {
                    HStack(spacing: 7) {
                        ForEach(TimeOfDay.allCases, id: \.self) { t in
                            Button {
                                withAnimation(.easeInOut(duration: 0.35)) { artPhase = t }
                            } label: {
                                Text(t.rawValue.capitalized)
                                    .font(.caption2.weight(.semibold))
                                    .padding(.horizontal, 11).padding(.vertical, 6)
                                    .background(t == artPhase ? .white.opacity(0.92) : .white.opacity(0.2),
                                                in: Capsule())
                                    .foregroundStyle(t == artPhase ? .black : .white)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }

            Group {
                if refreshing {
                    HStack(spacing: 8) {
                        ProgressView().tint(.white)
                        Text("Asking your coach…")
                    }
                } else if canRefresh {
                    Label("Pull again to refresh", systemImage: "arrow.down")
                } else {
                    Text("Scroll up to go back")
                }
            }
            .font(.caption)
            .foregroundStyle(.white.opacity(0.85))
            .shadow(radius: 4)
            .padding(.bottom, 10)
        }
        .frame(height: geo.size.height * 0.62)
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 20)
        .overlay(alignment: .topTrailing) { backgroundMenu }
        .transition(.opacity)
    }

    /// Swap the picture behind the plan: pick another of your places for this sport, go back to
    /// the daily rotation, or go add one.
    @ViewBuilder
    private var backgroundMenu: some View {
        if let slot = heroSlot {
            Menu {
                let list = venues.venues(for: slot)
                if !list.isEmpty {
                    Section("Show here") {
                        ForEach(list) { v in
                            Button {
                                pin(v.id.uuidString, for: slot)
                            } label: {
                                Label(v.name, systemImage: plan.settings.venueByKind?[slot] == v.id.uuidString
                                      ? "checkmark" : "photo")
                            }
                        }
                    }
                }
                Button("Rotate by day", systemImage: "shuffle") { pin(nil, for: slot) }
                Divider()
                Button("Manage places…", systemImage: "photo.stack") { showPlaces = true }
            } label: {
                Label("Background", systemImage: "photo.on.rectangle.angled")
                    .font(.caption.weight(.semibold))
                    .labelStyle(.iconOnly)
                    .foregroundStyle(.white)
                    .padding(10)
                    .background(.black.opacity(0.35), in: Circle())
            }
            .padding(.top, 8)
            .padding(.trailing, 4)
            .accessibilityLabel("Change background")
        }
    }

    /// nil goes back to the date-driven rotation.
    private func pin(_ id: String?, for slot: String) {
        var m = plan.settings.venueByKind ?? [:]
        m[slot] = id
        withAnimation(.easeInOut(duration: 0.3)) {
            plan.settings.venueByKind = m.compactMapValues { $0 }.isEmpty ? nil : m
        }
    }

    // MARK: Pull

    /// Two detents. The first opens the artwork; a second pull from there refreshes, which is
    /// why the standard pull-to-refresh isn't used — it would fire on the first one.
    private func handlePull(_ y: CGFloat) {
        guard peek else {
            if y > 70 {
                softTap.impactOccurred()
                softTap.prepare()
                canRefresh = false          // this pull is spent on opening the artwork
                withAnimation(.snappy(duration: 0.35)) { peek = true }
            }
            return
        }
        if y < -70 {
            withAnimation(.snappy(duration: 0.3)) { peek = false }
            artPhase = nil
            return
        }
        // A refresh costs an API call, so it needs a deliberate second pull: the first one has
        // to relax back to the top before the next one counts.
        guard canRefresh else {
            if y < 12 { canRefresh = true }
            return
        }
        if y > 90, !refreshing {
            firmTap.impactOccurred()
            firmTap.prepare()
            Task { await refresh() }
        }
    }

    private func refresh() async {
        guard !refreshing else { return }
        refreshing = true
        plan.invalidateWorkouts()
        await weather.refresh(force: true)
        await dashboard.refresh()
        await loadVisible()
        await plan.requestUpdate(dashboard: dashboard, calendar: calendarSync, weather: weather)
        await AppServices.shared.syncSchedule()
        refreshing = false
        canRefresh = false
        withAnimation(.snappy(duration: 0.3)) { peek = false }
        artPhase = nil
    }

    // MARK: Navigation row

    private var navigator: some View {
        HStack {
            Button { step(-1) } label: { Image(systemName: "chevron.left") }
                .accessibilityLabel("Previous")
            Spacer()
            Text(title).font(.headline)
            Spacer()
            Button("Today") {
                selected = engine.calendar.startOfDay(for: .now)
            }
            .font(.subheadline)
            Button { step(1) } label: { Image(systemName: "chevron.right") }
                .accessibilityLabel("Next")
        }
        .buttonStyle(.borderless)
    }

    private var title: String {
        switch scale {
        case .month: return selected.formatted(.dateTime.month(.wide).year())
        case .week:
            let m = engine.monday(of: selected)
            return "\(m.formatted(.dateTime.month(.abbreviated).day())) – \(engine.add(m, days: 6).formatted(.dateTime.month(.abbreviated).day()))"
        case .day: return selected.formatted(.dateTime.weekday(.wide).month(.abbreviated).day())
        }
    }

    private func step(_ n: Int) {
        let cal = engine.calendar
        switch scale {
        case .month: selected = cal.date(byAdding: .month, value: n, to: selected) ?? selected
        case .week: selected = engine.add(selected, days: 7 * n)
        case .day: selected = engine.add(selected, days: n)
        }
    }

    // MARK: Workouts for what's on screen

    /// Every scale gets a picture, driven by the selected day's main session — so stepping
    /// through the month changes the scenery instead of leaving a flat wash.
    private var backdropSession: PlanSession? {
        if let s = VenueSlot.hero(of: plan.day(selected).sessions) { return s }
        // A rest day borrows the next session within the week, rather than dropping to grey.
        for i in 1...7 {
            if let s = VenueSlot.hero(of: plan.day(engine.add(selected, days: i)).sessions) { return s }
        }
        return nil
    }

    private var heroSlot: String? { backdropSession.flatMap { VenueSlot.key(for: $0) } }

    private var heroVenue: Venue? {
        guard let slot = heroSlot else { return nil }
        return VenuePicker.pick(venues.venues, slot: slot, iso: engine.iso(selected),
                                pinnedID: plan.settings.venueByKind?[slot])
    }

    private var visibleRange: (Date, Date) {
        let cal = engine.calendar
        let monthStart = cal.date(from: cal.dateComponents([.year, .month], from: selected))!
        let start = engine.monday(of: monthStart)
        return (start, engine.add(start, days: 42))
    }

    private var rangeKey: String { engine.iso(visibleRange.0) }

    private func loadVisible() async {
        let (a, b) = visibleRange
        await plan.loadWorkouts(from: a, to: b)
    }
}

// MARK: - Header + Claude card

private struct SeasonHeader: View {
    let engine: PlanEngine
    let date: Date

    var body: some View {
        let ph = engine.phase(for: date)
        let days = engine.daysToRace(from: .now)
        VStack(alignment: .leading, spacing: 4) {
            Text("\(days / 7) weeks · \(days) days to \(engine.raceName)")
                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            Text(ph.name).font(.title2.bold())
            Text("\(ph.hours) / week · \(ph.goal)").font(.subheadline).foregroundStyle(.secondary)
        }
        .padding(.top, 4)
    }
}

private struct CoachUpdateCard: View {
    @EnvironmentObject private var plan: PlanModel
    @EnvironmentObject private var dashboard: DashboardModel
    @EnvironmentObject private var calendarSync: CalendarSync
    @EnvironmentObject private var weather: WeatherModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Coach update", systemImage: "sparkles").font(.headline)
                Spacer()
                if let u = plan.update {
                    Text(u.createdAt, format: .relative(presentation: .named))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if let u = plan.update {
                Text(u.todayCall).font(.subheadline)
                if let note = u.weekNote { Text(note).font(.caption).foregroundStyle(.secondary) }
                let n = u.days.values.filter(\.changedSessions).count
                Text(n == 0 ? "Plan stands as written this week." : "\(n) day\(n == 1 ? "" : "s") changed this week. Look for the ✦ marks.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Text("Pull down to have Claude check this week against your recovery and recent training.")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            TimelineView(.periodic(from: .now, by: 1)) { ctx in
                let wait = plan.secondsUntilNextUpdate(now: ctx.date)
                Button {
                    Task {
                        await plan.requestUpdate(dashboard: dashboard, calendar: calendarSync, weather: weather)
                        await AppServices.shared.syncSchedule()
                    }
                } label: {
                    HStack(spacing: 8) {
                        if plan.isUpdating {
                            ProgressView()
                            Text("Asking Claude…")
                        } else if wait > 0 {
                            Image(systemName: "hourglass")
                            Text("Next update in \(wait) s").monospacedDigit()
                        } else {
                            Image(systemName: "arrow.clockwise")
                            Text("Update this week")
                        }
                    }
                    .font(.subheadline.weight(.semibold))
                }
                .buttonStyle(.bordered)
                .disabled(wait > 0 || plan.isUpdating)
            }
            if let err = plan.errorText {
                Label(err, systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(.red)
            }
            if let info = plan.infoText {
                Text(info).font(.caption).foregroundStyle(.secondary)
            }
            if let summary = calendarSync.lastSummary {
                Label(summary, systemImage: "calendar").font(.caption).foregroundStyle(.secondary)
            }
            if let err = calendarSync.errorText {
                Label(err, systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(.red)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassSurface(radius: 16)
    }
}

// MARK: - Month

private struct MonthGrid: View {
    @EnvironmentObject private var plan: PlanModel
    let month: Date
    let selected: Date
    let onPick: (Date) -> Void

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 4), count: 7)

    var body: some View {
        let e = plan.engine
        let cal = e.calendar
        let first = cal.date(from: cal.dateComponents([.year, .month], from: month))!
        let start = e.monday(of: first)
        let monthIndex = cal.component(.month, from: first)
        let today = cal.startOfDay(for: .now)

        VStack(spacing: 6) {
            LazyVGrid(columns: columns, spacing: 4) {
                ForEach(["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"], id: \.self) {
                    Text($0).font(.caption2).foregroundStyle(.secondary)
                }
                ForEach(0..<42, id: \.self) { i in
                    let d = e.add(start, days: i)
                    let day = plan.day(d)
                    Button { onPick(d) } label: {
                        MonthCell(day: day,
                                  outside: cal.component(.month, from: d) != monthIndex,
                                  isToday: d == today,
                                  isSelected: d == cal.startOfDay(for: selected),
                                  isPast: d < today)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text(d.formatted(date: .complete, time: .omitted)))
                }
            }
            legend
        }
        .padding(10)
        .glassSurface(radius: 16)
    }

    private var legend: some View {
        let kinds: [SessionKind] = [.swim, .bike, .run, .lift, .snow]
        return HStack(spacing: 10) {
            ForEach(kinds, id: \.self) { k in
                HStack(spacing: 4) {
                    Circle().fill(Palette.color(for: k)).frame(width: 7, height: 7)
                    Text(k.label).font(.caption2).foregroundStyle(.secondary)
                }
            }
            HStack(spacing: 4) {
                Image(systemName: "checkmark").font(.caption2).foregroundStyle(Palette.good)
                Text("Done").font(.caption2).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 4)
    }
}

private struct MonthCell: View {
    let day: DayPlan
    let outside: Bool
    let isToday: Bool
    let isSelected: Bool
    let isPast: Bool

    var body: some View {
        let active = day.sessions.filter { $0.kind != .rest }
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 2) {
                Text("\(Calendar.current.component(.day, from: day.date))")
                    .font(.caption.weight(isToday ? .bold : .regular).monospacedDigit())
                    .foregroundStyle(isToday ? Palette.series1 : .primary)
                Spacer(minLength: 0)
                if day.change?.changedSessions == true { Text("✦").font(.caption2).foregroundStyle(Palette.series7) }
                if !day.milestones.isEmpty { Image(systemName: "flag.fill").font(.system(size: 8)).foregroundStyle(Palette.series7) }
            }
            HStack(spacing: 3) {
                if isPast && !day.done.isEmpty {
                    Image(systemName: "checkmark").font(.system(size: 9, weight: .bold)).foregroundStyle(Palette.good)
                } else {
                    ForEach(Array(active.prefix(3).enumerated()), id: \.offset) { _, s in
                        Circle().fill(Palette.color(for: s.kind)).frame(width: 6, height: 6)
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(5)
        .frame(maxWidth: .infinity, minHeight: 48, alignment: .topLeading)
        .glassSurface(radius: 8)
        .overlay(RoundedRectangle(cornerRadius: 8)
            .stroke(isSelected ? Color.primary : (isToday ? Palette.series1 : .clear), lineWidth: isSelected ? 2 : 1))
        .opacity(outside ? 0.4 : 1)
    }
}

// MARK: - Week

private struct WeekList: View {
    @EnvironmentObject private var plan: PlanModel
    let monday: Date
    let selected: Date
    let onPick: (Date) -> Void

    var body: some View {
        let e = plan.engine
        let days = (0..<7).map { plan.day(e.add(monday, days: $0)) }
        let plannedMin = days.flatMap(\.sessions).compactMap { $0.rx?.durationMin }.reduce(0, +)
        let doneMin = days.flatMap(\.done).reduce(0) { $0 + Int($1.duration / 60) }
        let today = e.calendar.startOfDay(for: .now)

        VStack(spacing: 10) {
            HStack {
                Text("Planned \(Fmt.hours(plannedMin))").font(.subheadline.monospacedDigit())
                Spacer()
                Text("Done \(Fmt.hours(doneMin))").font(.subheadline.monospacedDigit()).foregroundStyle(.secondary)
            }
            ForEach(days, id: \.iso) { day in
                Button { onPick(day.date) } label: {
                    WeekDayRow(day: day, isToday: day.date == today, isPast: day.date < today)
                }
                .buttonStyle(.plain)
            }
        }
    }
}

private struct WeekDayRow: View {
    @EnvironmentObject private var calendarSync: CalendarSync
    @EnvironmentObject private var weather: WeatherModel
    let day: DayPlan
    let isToday: Bool
    let isPast: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(spacing: 2) {
                Text(day.date.formatted(.dateTime.weekday(.abbreviated))).font(.caption).foregroundStyle(.secondary)
                Text(day.date.formatted(.dateTime.day())).font(.title3.bold().monospacedDigit())
                    .foregroundStyle(isToday ? Palette.series1 : .primary)
                if let w = weather.day(day.date) {
                    Text("\(Int(w.highF.rounded()))°").font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                    if weather.isHot(day.date) {
                        Image(systemName: "thermometer.sun.fill").font(.caption2).foregroundStyle(Palette.warning)
                            .accessibilityLabel("Hot afternoon")
                    }
                }
            }
            .frame(width: 40)
            VStack(alignment: .leading, spacing: 6) {
                ForEach(day.milestones, id: \.title) { m in
                    Label(m.title, systemImage: "flag.fill").font(.caption.bold()).foregroundStyle(Palette.series7)
                }
                ForEach(Array(day.sessions.enumerated()), id: \.offset) { i, s in
                    SessionLine(session: s, slot: calendarSync.slot(for: day, index: i),
                                unplaced: calendarSync.isUnplaced(day, index: i))
                }
                if day.change?.changedSessions == true, let reason = day.change?.reason {
                    Text("✦ \(reason)").font(.caption).foregroundStyle(Palette.series7)
                }
                if !day.done.isEmpty {
                    ForEach(day.done) { w in
                        Label("\(w.name) · \(Fmt.minutes(w.duration))", systemImage: "checkmark.circle.fill")
                            .font(.caption).foregroundStyle(Palette.good)
                    }
                }
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
        }
        .padding(12)
        .glassSurface(radius: 14)
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(isToday ? Palette.series1 : .clear, lineWidth: 1))
        .opacity(isPast && day.done.isEmpty ? 0.7 : 1)
    }
}

struct SessionLine: View {
    let session: PlanSession
    var slot: DateInterval? = nil
    var unplaced = false

    var body: some View {
        HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 2).fill(Palette.color(for: session.kind)).frame(width: 3)
            Image(systemName: (session.indoor ?? false) && session.kind == .bike ? "figure.indoor.cycle" : session.kind.symbol)
                .font(.caption).foregroundStyle(.secondary).frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                if let slot {
                    Text(slot.start.formatted(date: .omitted, time: .shortened))
                        .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                } else if unplaced {
                    Label("No free slot", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption2).foregroundStyle(Palette.warning)
                }
                HStack(spacing: 6) {
                    Text(session.title).font(.subheadline.weight(session.kind == .rest ? .regular : .semibold))
                        .foregroundStyle(session.kind == .rest ? .secondary : .primary)
                    if session.addedByAthlete {
                        Text("YOURS").font(.system(size: 9, weight: .bold))
                            .padding(.horizontal, 4).padding(.vertical, 1)
                            .background(Palette.series4.opacity(0.25), in: Capsule())
                    }
                }
                if let line = Fmt.targetLine(session) {
                    Text(line).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - Day

private struct DayDetail: View {
    @EnvironmentObject private var plan: PlanModel
    @EnvironmentObject private var calendarSync: CalendarSync
    @EnvironmentObject private var weather: WeatherModel
    @State private var showAdd = false
    /// First detent: the artwork opened up, plan pushed down. Second pull from there refreshes.
    @State private var peek = false
    @State private var refreshing = false
    /// While the page is pulled open, the athlete can flick through the four times of day.
    @State private var artPhase: TimeOfDay?
    /// Kept around and pre-armed; a generator created at the moment of impact often misses.
    /// Armed once the pull relaxes after opening, so the same gesture can't run straight on
    /// into a refresh.
    @State private var canRefresh = false
    @State private var showPlaces = false
    @State private var softTap = UIImpactFeedbackGenerator(style: .soft)
    @State private var firmTap = UIImpactFeedbackGenerator(style: .rigid)
    let day: DayPlan

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(plan.engine.inPlan(day.date) ? plan.engine.phase(for: day.date).name : "Outside the plan")
                .font(.caption).foregroundStyle(.secondary)

            if let w = weather.day(day.date) {
                WeatherCard(day: w, hot: weather.isHot(day.date), location: weather.locationName,
                            source: weather.source, attribution: weather.attribution)
            }

            let busy = calendarSync.busy(on: day.date)
            if !busy.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Label("Your calendar", systemImage: "calendar").font(.subheadline.bold())
                    ForEach(Array(busy.enumerated()), id: \.offset) { _, b in
                        HStack(alignment: .firstTextBaseline) {
                            Text(b.allDay ? "All day" : "\(b.start.formatted(date: .omitted, time: .shortened))–\(b.end.formatted(date: .omitted, time: .shortened))")
                                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                            Text(b.title ?? "Busy").font(.caption).lineLimit(1)
                        }
                    }
                }
                .glassCard(radius: 14, padding: 12)
            }

            ForEach(day.milestones, id: \.title) { m in
                VStack(alignment: .leading, spacing: 4) {
                    Label(m.title, systemImage: "flag.fill").font(.subheadline.bold()).foregroundStyle(Palette.series7)
                    Text(m.detail).font(.caption).foregroundStyle(.secondary)
                }
                .glassCard(radius: 14, padding: 12)
            }

            if let c = day.change {
                VStack(alignment: .leading, spacing: 6) {
                    Label(c.changedSessions ? "Changed by Claude" : "Targets refined by Claude", systemImage: "sparkles")
                        .font(.subheadline.bold()).foregroundStyle(Palette.series7)
                    Text(c.reason).font(.caption)
                    if c.changedSessions && !day.original.isEmpty {
                        DisclosureGroup("Original plan") {
                            VStack(alignment: .leading, spacing: 6) {
                                ForEach(Array(day.original.enumerated()), id: \.offset) { _, s in SessionLine(session: s) }
                            }
                            .padding(.top, 4)
                        }
                        .font(.caption)
                    }
                }
                .glassCard(radius: 14, padding: 12)
            }

            Text("Planned").font(.headline)
            if day.sessions.isEmpty {
                Text("Nothing planned.").foregroundStyle(.secondary)
            }
            ForEach(Array(day.sessions.enumerated()), id: \.offset) { i, s in
                let slot = calendarSync.slot(for: day, index: i)
                NavigationLink(value: PlanRoute.session(s, day.date, day.change, slot)) {
                    SessionCard(session: s, slot: slot, unplaced: calendarSync.isUnplaced(day, index: i),
                                weather: slot.flatMap { weather.forecast?.at($0.start) })
                }
                .buttonStyle(.plain)
            }

            Button { showAdd = true } label: {
                Label("Add your own session", systemImage: "plus.circle.fill")
                    .font(.subheadline.weight(.semibold))
            }
            .padding(.top, 2)
            .sheet(isPresented: $showAdd) { AddSessionSheet(defaultDate: day.date) }

            Text("Recorded").font(.headline).padding(.top, 4)
            if day.done.isEmpty {
                Text(day.date > Date.now ? "Still to come." : "No workouts recorded in Apple Health.")
                    .foregroundStyle(.secondary)
            }
            ForEach(day.done) { w in
                NavigationLink(value: PlanRoute.workout(w)) {
                    WorkoutCard(w: w)
                }
                .buttonStyle(.plain)
            }
        }
    }
}

private struct SessionCard: View {
    let session: PlanSession
    var slot: DateInterval? = nil
    var unplaced = false
    var weather: HourWeather? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                SessionLine(session: session, slot: slot, unplaced: unplaced)
                Spacer()
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
            }
            if let rx = session.rx {
                if let hr = rx.heartRate ?? rx.power {
                    Label(hr, systemImage: rx.heartRate != nil ? "heart.fill" : "bolt.fill")
                        .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
                if let fuel = rx.fuelDuring {
                    Label(fuel, systemImage: "fork.knife").font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
            }
            if let w = weather {
                Label(WeatherText.hour(w), systemImage: w.feelsF >= Forecast.heatThresholdF ? "thermometer.sun.fill" : "cloud.sun")
                    .font(.caption).foregroundStyle(w.feelsF >= Forecast.heatThresholdF ? Palette.warning : .secondary)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.ultraThinMaterial)
        .overlay(alignment: .leading) {
            Rectangle().fill(Palette.color(for: session.kind)).frame(width: 4)
        }
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

private struct WorkoutCard: View {
    @EnvironmentObject private var review: ReviewModel
    let w: WorkoutSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Image(systemName: w.sport.symbol).foregroundStyle(Palette.color(for: w.sport)).frame(width: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text(w.name).font(.subheadline.bold())
                    Text([w.start.formatted(date: .omitted, time: .shortened), Fmt.minutes(w.duration),
                          w.distanceMeters.map { DistanceFormat.string(meters: $0, sport: w.sport) }]
                        .compactMap { $0 }.joined(separator: " · "))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if let hr = w.avgHR {
                    Text("\(Int(hr.rounded())) bpm").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
            }

            // The nudge lives on the card itself, so an unanswered session is visible from the
            // day screen rather than only once you open it.
            if let feel = review.feel(for: w.id) {
                HStack(spacing: 6) {
                    Image(systemName: feel.mood.symbol).symbolVariant(.fill)
                    Text("\(feel.mood.label) · RPE \(feel.rpe)/10")
                    if review.note(for: w.id) != nil {
                        Text("·").foregroundStyle(.tertiary)
                        Image(systemName: "text.bubble.fill")
                        Text("Coach replied")
                    }
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            } else {
                Label("How did it feel?", systemImage: "bubble.left.and.text.bubble.right.fill")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(Palette.color(for: w.sport))
            }
        }
        .padding(12)
        .glassSurface(radius: 14)
    }
}

// MARK: - Formatting

enum Fmt {
    static func hours(_ minutes: Int) -> String {
        minutes < 60 ? "\(minutes) min" : String(format: "%d:%02d h", minutes / 60, minutes % 60)
    }

    static func minutes(_ seconds: TimeInterval) -> String {
        let m = Int((seconds / 60).rounded())
        return m < 60 ? "\(m) min" : String(format: "%d:%02d", m / 60, m % 60)
    }

    static func targetLine(_ s: PlanSession) -> String? {
        guard s.kind != .rest else { return s.detail.isEmpty ? nil : s.detail }
        var parts: [String] = []
        if let m = s.rx?.durationMin, m > 0 { parts.append(hours(m)) }
        if let d = s.rx?.distance { parts.append(d) }
        if parts.isEmpty, !s.detail.isEmpty { return s.detail }
        if let p = s.rx?.power, p.contains("W") { parts.append(p) }
        else if let hr = s.rx?.heartRate, hr.contains("bpm") { parts.append(hr) }
        return parts.joined(separator: " · ")
    }
}


// MARK: - Weather

enum WeatherText {
    static func hour(_ w: HourWeather) -> String {
        var s = "\(Int(w.tempF.rounded()))°F"
        if abs(w.feelsF - w.tempF) >= 3 { s += " (feels \(Int(w.feelsF.rounded())))" }
        s += " · wind \(Int(w.windMph.rounded())) mph"
        if w.precipProb >= 20 { s += " · rain \(Int(w.precipProb.rounded()))%" }
        if w.uv >= 6 { s += " · UV \(Int(w.uv.rounded()))" }
        return s
    }
}

struct WeatherCard: View {
    @Environment(\.colorScheme) private var scheme
    let day: DayWeather
    let hot: Bool
    let location: String
    var source: WeatherModel.Source = .openMeteo
    var attribution: AppleWeather.Attribution? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label("\(Int(day.lowF.rounded()))–\(Int(day.highF.rounded()))°F", systemImage: hot ? "thermometer.sun.fill" : "cloud.sun")
                    .font(.subheadline.bold())
                    .foregroundStyle(hot ? Palette.warning : .primary)
                Spacer()
                Text("rain \(Int(day.precipProbMax.rounded()))%").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            if let rise = day.sunrise, let set = day.sunset {
                Text("Sunrise \(rise.formatted(date: .omitted, time: .shortened)) · sunset \(set.formatted(date: .omitted, time: .shortened))")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if hot {
                Text("Hot afternoon: sessions move to first light (the plan's ~90°F rule).").font(.caption)
            }
            if source == .apple, let a = attribution {
                HStack(spacing: 6) {
                    Text(location).font(.caption2).foregroundStyle(.tertiary)
                    AsyncImage(url: scheme == .dark ? a.markDark : a.markLight) { img in
                        img.resizable().scaledToFit()
                    } placeholder: { Text("Apple Weather").font(.caption2) }
                    .frame(height: 11)
                    Link("Data sources", destination: a.legal).font(.caption2)
                }
            } else {
                Text("\(location) · Weather data by Open-Meteo.com").font(.caption2).foregroundStyle(.tertiary)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassSurface(radius: 12)
    }
}
