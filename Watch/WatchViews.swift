import SwiftUI
import WorkoutKit

@main
struct CoachBridgeWatchApp: App {
    @StateObject private var model = WatchModel()

    var body: some Scene {
        WindowGroup {
            NavigationStack { WatchHomeView() }
                .environmentObject(model)
                .task { model.activate() }
        }
    }
}

// MARK: - Home

struct WatchHomeView: View {
    @EnvironmentObject private var model: WatchModel
    @ObservedObject private var fuelTimer = FuelTimer.shared

    var body: some View {
        if let s = model.snapshot {
            content(s)
        } else {
            ContentUnavailableView("Open Coach Bridge on your iPhone", systemImage: "iphone",
                                   description: Text("Your plan appears here once the phone sends it."))
        }
    }

    private func content(_ s: WatchSnapshot) -> some View {
        let today = Self.iso(.now)
        let todays = s.sessions.filter { $0.dateISO == today }
        let later = s.sessions.filter { $0.dateISO > today }.prefix(4)
        return List {
            if let race = s.race {
                Section {
                    NavigationLink { RaceView(race: race) } label: {
                        Label("Race day: \(race.name)", systemImage: "flag.checkered").font(.headline)
                    }
                }
            } else if s.phase != nil || s.daysToRace != nil {
                Section { SeasonRow(snapshot: s) }
            }

            if fuelTimer.startedAt != nil {
                Section { FuelTimerRow() }
            }

            if !model.awaitingFeel.isEmpty {
                Section("How did it feel?") {
                    ForEach(model.awaitingFeel) { w in
                        NavigationLink { FeelView(workout: w) } label: {
                            Label {
                                VStack(alignment: .leading) {
                                    Text(w.name).font(.headline)
                                    Text("\(w.minutes) min · \(w.start.formatted(.relative(presentation: .named)))")
                                        .font(.caption2).foregroundStyle(.secondary)
                                }
                            } icon: {
                                Image(systemName: w.symbol).foregroundStyle(.orange)
                            }
                        }
                    }
                }
            }

            Section("Today") {
                if todays.isEmpty {
                    Label("Rest day", systemImage: "bed.double.fill").foregroundStyle(.secondary)
                }
                ForEach(todays) { SessionRow(session: $0) }
            }

            if !later.isEmpty {
                Section("Coming up") {
                    ForEach(Array(later)) { SessionRow(session: $0, showDay: true) }
                }
            }

            if let r = s.recovery {
                Section("Recovery") {
                    VStack(alignment: .leading, spacing: 4) {
                        Label(r.headline, systemImage: Self.recoverySymbol(r.level))
                            .foregroundStyle(Self.recoveryColor(r.level))
                            .font(.headline)
                        ForEach(r.reasons, id: \.self) { Text($0).font(.caption2).foregroundStyle(.secondary) }
                    }
                }
            }

            Section {
                VStack(alignment: .leading, spacing: 2) {
                    if s.isDemo { Text("Demo data").font(.caption2.bold()).foregroundStyle(.orange) }
                    Text("Updated \(s.generatedAt.formatted(.relative(presentation: .named)))")
                        .font(.caption2).foregroundStyle(.secondary)
                    if Date.now.timeIntervalSince(s.generatedAt) > 12 * 3600 {
                        Text("Open Coach Bridge on your iPhone to refresh.")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }
                .listRowBackground(Color.clear)
            }
        }
        .navigationTitle("Coach Bridge")
    }

    /// "yyyy-MM-dd" in the watch's own calendar, matching the phone's day keys.
    static func iso(_ d: Date) -> String {
        let c = Calendar(identifier: .gregorian).dateComponents(in: .current, from: d)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    static func recoverySymbol(_ level: String) -> String {
        switch level {
        case "good": return "checkmark.circle.fill"
        case "caution": return "exclamationmark.triangle.fill"
        case "normal": return "circle.fill"
        default: return "questionmark.circle"
        }
    }

    static func recoveryColor(_ level: String) -> Color {
        switch level {
        case "good": return .green
        case "caution": return .orange
        default: return .secondary
        }
    }
}

private struct SeasonRow: View {
    let snapshot: WatchSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            if let days = snapshot.daysToRace {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text("\(days)").font(.system(.title, design: .rounded).bold()).monospacedDigit()
                    Text(snapshot.raceName.map { "days to \($0)" } ?? "days left").font(.caption2).foregroundStyle(.secondary)
                }
            }
            if let p = snapshot.phase {
                Text(p.label).font(.caption.weight(.semibold))
                if p.isEasier { Text("Easier week").font(.caption2).foregroundStyle(.teal) }
            }
        }
        .accessibilityElement(children: .combine)
    }
}

private struct SessionRow: View {
    let session: WatchSnapshot.Session
    var showDay = false

    var body: some View {
        NavigationLink { WatchSessionView(session: session) } label: {
            HStack(spacing: 8) {
                Image(systemName: session.symbol)
                    .foregroundStyle(WatchSessionView.color(session.kind))
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: 1) {
                    Text(session.title).font(.headline).lineLimit(2)
                    Text(subtitle).font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
    }

    private var subtitle: String {
        var parts: [String] = []
        if showDay, let start = session.start { parts.append(start.formatted(.dateTime.weekday(.abbreviated))) }
        if let start = session.start { parts.append(start.formatted(date: .omitted, time: .shortened)) }
        if let m = session.minutes { parts.append(m < 60 ? "\(m) min" : String(format: "%d:%02d h", m / 60, m % 60)) }
        return parts.joined(separator: " · ")
    }
}

// MARK: - Session

struct WatchSessionView: View {
    let session: WatchSnapshot.Session
    @State private var errorText: String?
    @State private var opening = false

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 4) {
                    Label(session.title, systemImage: session.symbol)
                        .font(.headline)
                        .foregroundStyle(Self.color(session.kind))
                    if session.isYours {
                        Text("Your session").font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }

            if let data = session.workoutPlan {
                Section {
                    Button {
                        Task { await start(data) }
                    } label: {
                        Label(opening ? "Opening…" : "Start in Workout", systemImage: "play.fill")
                    }
                    .disabled(opening)
                    .tint(.green)
                } footer: {
                    Text("Opens this session in the Workout app, with its steps and alerts.")
                }
            }

            Section("Targets") {
                row("Length", session.minutes.map { "\($0) min" }, "clock")
                row("Intensity", session.intensity, "gauge.with.dots.needle.33percent")
                row("Heart rate", session.heartRate, "heart.fill")
                row("Power", session.power, "bolt.fill")
                row("Pace", session.pace, "speedometer")
            }

            if let fuel = session.fuelDuring {
                Section("Fuel during") {
                    Text(fuel).font(.caption)
                    let cues = FuelCue.every20(minutes: session.minutes ?? 0,
                                               text: String(fuel.split(separator: "—").first ?? Substring(fuel)))
                    if !cues.isEmpty { FuelTimerButton(title: session.title, cues: cues) }
                }
            }
        }
        .navigationTitle(session.start?.formatted(date: .omitted, time: .shortened) ?? "Session")
        .alert("Couldn't open the workout", isPresented: .constant(errorText != nil)) {
            Button("OK") { errorText = nil }
        } message: {
            Text(errorText ?? "")
        }
    }

    private func start(_ data: Data) async {
        opening = true
        defer { opening = false }
        do {
            try await WorkoutPlan(from: data).openInWorkoutApp()
        } catch {
            errorText = "It's also in the Workout app under Scheduled. (\(error.localizedDescription))"
        }
    }

    @ViewBuilder
    private func row(_ label: String, _ value: String?, _ icon: String) -> some View {
        if let value, !value.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                Label(label, systemImage: icon).font(.caption2).foregroundStyle(.secondary)
                Text(value).font(.caption)
            }
        }
    }

    /// The phone's sport colors, approximately — the watch has no Palette.
    static func color(_ kind: String) -> Color {
        switch kind {
        case "swim": return .blue
        case "bike": return .orange
        case "run": return .green
        case "lift": return .pink
        case "golf": return .yellow
        case "snow", "fun": return .purple
        default: return .secondary
        }
    }
}

// MARK: - Feel

/// The phone's "How did it feel?" on the wrist: a face and an effort rating, turned with the
/// Digital Crown. Sent to the phone, which saves it like an answer given there.
struct FeelView: View {
    @EnvironmentObject private var model: WatchModel
    @Environment(\.dismiss) private var dismiss
    let workout: WatchSnapshot.Workout

    @State private var mood: String?
    @State private var rpe = 5.0

    private let moods: [(id: String, symbol: String, label: String)] = [
        ("great", "face.smiling.inverse", "Great"),
        ("good", "face.smiling", "Good"),
        ("okay", "face.dashed", "Okay"),
        ("tough", "exclamationmark.triangle", "Tough"),
        ("awful", "xmark.octagon", "Awful"),
    ]

    var body: some View {
        ScrollView {
            VStack(spacing: 10) {
                Text(workout.name).font(.headline)
                LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 3), spacing: 6) {
                    ForEach(moods, id: \.id) { m in
                        Button { mood = m.id } label: {
                            VStack(spacing: 2) {
                                Image(systemName: m.symbol).font(.title3)
                                Text(m.label).font(.system(size: 10))
                            }
                            .frame(maxWidth: .infinity, minHeight: 40)
                        }
                        .buttonStyle(.bordered)
                        .tint(mood == m.id ? .green : .gray)
                        .accessibilityAddTraits(mood == m.id ? .isSelected : [])
                    }
                }

                VStack(spacing: 2) {
                    Text("Effort \(Int(rpe))/10").font(.title3.bold()).monospacedDigit()
                    Text(Self.rpeText(Int(rpe))).font(.caption2).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .focusable()
                .digitalCrownRotation($rpe, from: Double(WatchFeelReport.rpeRange.lowerBound),
                                      through: Double(WatchFeelReport.rpeRange.upperBound), by: 1,
                                      sensitivity: .low, isContinuous: false, isHapticFeedbackEnabled: true)
                .accessibilityElement(children: .combine)
                .accessibilityValue("\(Int(rpe)) of 10")
                .accessibilityAdjustableAction { dir in
                    switch dir {
                    case .increment: rpe = min(10, rpe + 1)
                    case .decrement: rpe = max(1, rpe - 1)
                    @unknown default: break
                    }
                }

                Button("Save") {
                    guard let mood else { return }
                    model.send(WatchFeelReport(workoutID: workout.id, mood: mood, rpe: Int(rpe), sentAt: .now))
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(mood == nil)

                Text("Turn the Digital Crown to rate the effort. The coach's note is written when you open this workout on your iPhone.")
                    .font(.system(size: 10)).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
        }
        .navigationTitle("How did it feel?")
    }

    /// Mirrors the phone's scale wording.
    static func rpeText(_ r: Int) -> String {
        switch r {
        case ...2: return "Very easy — recovery pace"
        case 3: return "Easy — could do this all day"
        case 4: return "Steady — full sentences"
        case 5: return "Moderate — short sentences"
        case 6: return "Somewhat hard — breathing noticeably"
        case 7: return "Hard — a few words at a time"
        case 8: return "Very hard — holding on"
        case 9: return "Near maximal"
        default: return "All out"
        }
    }
}

// MARK: - Race day

struct RaceView: View {
    let race: WatchSnapshot.Race

    var body: some View {
        List {
            Section { FuelTimerButton(title: race.name, cues: race.fuel) }
            ForEach(race.legs) { leg in
                Section(leg.label) {
                    Text(leg.target).font(.caption.weight(.semibold))
                    Text(leg.cue).font(.caption2).foregroundStyle(.secondary)
                }
            }
            Section("Fuel") {
                ForEach(race.fuel) { cue in
                    HStack(alignment: .firstTextBaseline) {
                        Text(cue.at < 0 ? "−\(-cue.at / 60):\(String(format: "%02d", -cue.at % 60))"
                                        : "\(cue.at / 60):\(String(format: "%02d", cue.at % 60))")
                            .font(.caption.monospacedDigit().bold())
                            .frame(width: 40, alignment: .leading)
                        Text(cue.text).font(.caption2)
                    }
                }
            }
        }
        .navigationTitle("Race day")
    }
}

// MARK: - Fuel timer

/// Start at the gun, or at the start of a long session.
struct FuelTimerButton: View {
    @ObservedObject private var timer = FuelTimer.shared
    let title: String
    let cues: [FuelCue]

    var body: some View {
        if timer.title == title, timer.startedAt != nil {
            FuelTimerRow()
        } else {
            Button {
                Task { await timer.start(title, cues: cues) }
            } label: {
                Label("Start fuel timer", systemImage: "timer")
            }
            .tint(.orange)
            if let e = timer.errorText { Text(e).font(.caption2).foregroundStyle(.secondary) }
        }
    }
}

struct FuelTimerRow: View {
    @ObservedObject private var timer = FuelTimer.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let next = timer.nextCue {
                Text("Next fuel ") + Text(next.date, style: .relative).monospacedDigit()
                Text(next.cue.text).font(.caption2).foregroundStyle(.secondary)
            } else {
                Text("Fuel timer finished").font(.caption)
            }
            Button("Stop fuel timer", role: .destructive) { timer.stop() }
        }
    }
}
