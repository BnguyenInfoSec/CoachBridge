import SwiftUI

/// Add or edit one of the athlete's own sessions. Saving places it in the calendar
/// (and on the Watch) and asks Claude to rework the week around it.
struct CustomSessionEditor: View {
    @EnvironmentObject private var plan: PlanModel
    @EnvironmentObject private var dashboard: DashboardModel
    @EnvironmentObject private var calendarSync: CalendarSync
    @EnvironmentObject private var weather: WeatherModel
    @Environment(\.dismiss) private var dismiss

    /// nil = new session
    let existing: CustomSession?
    let defaultDate: Date

    @State private var day = Date()
    @State private var time = Date()
    @State private var duration = 45
    @State private var kind: SessionKind = .run
    @State private var title = ""
    @State private var notes = ""
    @State private var sending = false

    private let kinds: [SessionKind] = [.run, .bike, .swim, .lift, .flex, .fun]

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    DatePicker("Date", selection: $day, displayedComponents: .date)
                    DatePicker("Start time", selection: $time, displayedComponents: .hourAndMinute)
                    Stepper(value: $duration, in: 15...360, step: 5) {
                        LabeledContent("Length", value: Fmt.hours(duration))
                    }
                    Picker("Type", selection: $kind) {
                        ForEach(kinds, id: \.self) { k in
                            Label(k.label, systemImage: k.symbol).tag(k)
                        }
                    }
                }

                Section("What is it") {
                    TextField("Title (e.g. Group run with the guys)", text: $title)
                    TextField("Description — pace, distance, who's coming, anything Claude should know",
                              text: $notes, axis: .vertical)
                        .lineLimit(3...8)
                }

                Section {
                    Button {
                        Task { await save() }
                    } label: {
                        HStack {
                            Text(existing == nil ? "Add session and update plan" : "Save and update plan")
                            Spacer()
                            if sending { ProgressView() }
                        }
                    }
                    .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty || sending)
                } footer: {
                    Text("Your session is fixed: the app books that exact time, and Claude reworks the rest of the week around it. Claude updates at most once a minute, so it may take a moment.")
                }

                if let existing {
                    Section {
                        Button("Delete session", role: .destructive) {
                            plan.custom.delete(existing)
                            Task { await AppServices.shared.syncSchedule() }
                            dismiss()
                        }
                    }
                }
            }
            .navigationTitle(existing == nil ? "Add session" : "Edit session")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
            .onAppear(perform: load)
        }
    }

    private func load() {
        let cal = plan.engine.calendar
        if let e = existing {
            day = plan.engine.date(e.date)
            time = Scheduler.time(e.startTime, on: day, calendar: cal) ?? day
            duration = e.durationMin
            kind = e.kind
            title = e.title
            notes = e.notes
        } else {
            day = defaultDate
            time = cal.date(bySettingHour: 6, minute: 0, second: 0, of: defaultDate) ?? defaultDate
        }
    }

    private func save() async {
        sending = true
        defer { sending = false }
        let cal = plan.engine.calendar
        let comps = cal.dateComponents([.hour, .minute], from: time)
        let session = CustomSession(
            id: existing?.id ?? UUID(),
            date: plan.engine.iso(day),
            startTime: String(format: "%02d:%02d", comps.hour ?? 6, comps.minute ?? 0),
            durationMin: duration,
            kind: kind,
            title: title.trimmingCharacters(in: .whitespacesAndNewlines),
            notes: notes.trimmingCharacters(in: .whitespacesAndNewlines),
            createdAt: existing?.createdAt ?? .now)
        plan.custom.save(session)
        dismiss()
        await AppServices.shared.syncSchedule()
        await plan.requestUpdate(dashboard: dashboard, calendar: calendarSync, weather: weather)
        await AppServices.shared.syncSchedule()
    }
}
