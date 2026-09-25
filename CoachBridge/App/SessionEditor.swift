import SwiftUI

/// Every editable field of a session as a live control, so changing one value is one tap rather
/// than a trip through a separate form. Shared by adding a session and by editing any session in
/// place — planned or the athlete's own — so there is one set of inputs to learn.
struct SessionFields: View {
    @Binding var session: CustomSession
    /// What the plan would prescribe, shown as each target's placeholder so a blank field says
    /// what it will default to instead of looking empty.
    let defaults: Prescription?
    let calendar: Calendar

    static let kinds: [SessionKind] = [.run, .bike, .swim, .lift, .golf, .flex, .fun]

    var body: some View {
        Section {
            Picker(selection: $session.kind) {
                ForEach(Self.kinds, id: \.self) { k in
                    Label(k.label, systemImage: k.symbol).tag(k)
                }
            } label: {
                Label("Type", systemImage: session.kind.symbol)
            }
            TextField("Title", text: $session.title)
                .font(.headline)
                .submitLabel(.done)
            DatePicker(selection: day, displayedComponents: .date) {
                Label("Date", systemImage: "calendar")
            }
            DatePicker(selection: time, displayedComponents: .hourAndMinute) {
                Label("Start", systemImage: "clock")
            }
            Stepper(value: $session.durationMin, in: CustomSession.durationRange, step: 5) {
                HStack {
                    Label("Length", systemImage: "timer").lineLimit(1)
                    Spacer(minLength: 8)
                    Text(Fmt.hours(session.durationMin)).monospacedDigit().foregroundStyle(.secondary)
                }
            }
            .accessibilityValue(Fmt.hours(session.durationMin))
            if session.kind == .bike {
                Toggle(isOn: indoor) {
                    Label("On the trainer", systemImage: "house")
                }
            }
        }

        Section {
            target("Distance", "ruler", \.distance)
            target("Intensity", "gauge.with.dots.needle.33percent", \.intensity)
            target("Heart rate", "heart.fill", \.heartRate)
            if session.kind == .bike { target("Power", "bolt.fill", \.power) }
            if session.kind == .run || session.kind == .swim { target("Pace", "speedometer", \.pace) }
        } header: {
            Text("Targets")
        } footer: {
            Text("Leave a target blank and the plan fills it in from your zones.")
        }

        Section("Notes") {
            TextField("Route, pace, who's coming — anything Claude should know",
                      text: $session.notes, axis: .vertical)
                .lineLimit(2...8)
        }
    }

    // MARK: Rows

    private func target(_ label: String, _ icon: String,
                        _ field: WritableKeyPath<Prescription, String?>) -> some View {
        LabeledContent {
            // Wraps rather than truncating: the plan's targets are often a full sentence.
            TextField(defaults?[keyPath: field] ?? "—", text: text(field), axis: .vertical)
                .lineLimit(1...3)
                .multilineTextAlignment(.trailing)
                .submitLabel(.done)
        } label: {
            Label(label, systemImage: icon)
        }
    }

    // MARK: Bindings between the stored strings and the controls

    private func text(_ field: WritableKeyPath<Prescription, String?>) -> Binding<String> {
        Binding {
            session.rx?[keyPath: field] ?? ""
        } set: { new in
            var r = session.rx ?? Prescription()
            r[keyPath: field] = new.isEmpty ? nil : new
            session.rx = r
        }
    }

    private var day: Binding<Date> {
        Binding {
            AthleteProfile.date(session.date, calendar: calendar)
        } set: { new in
            session.date = AthleteProfile.iso(new, calendar: calendar)
        }
    }

    private var time: Binding<Date> {
        Binding {
            let d = AthleteProfile.date(session.date, calendar: calendar)
            return Scheduler.time(session.startTime, on: d, calendar: calendar) ?? d
        } set: { new in
            let c = calendar.dateComponents([.hour, .minute], from: new)
            session.startTime = String(format: "%02d:%02d", c.hour ?? 6, c.minute ?? 0)
        }
    }

    private var indoor: Binding<Bool> {
        Binding { session.indoor == true } set: { session.indoor = $0 ? true : nil }
    }
}

/// A new session of the athlete's own. Nothing is saved until Add, so Cancel leaves no trace.
struct AddSessionSheet: View {
    @EnvironmentObject private var plan: PlanModel
    @EnvironmentObject private var dashboard: DashboardModel
    @EnvironmentObject private var calendarSync: CalendarSync
    @EnvironmentObject private var weather: WeatherModel
    @Environment(\.dismiss) private var dismiss

    let defaultDate: Date
    @State private var session: CustomSession?

    var body: some View {
        let engine = plan.engine
        NavigationStack {
            Form {
                if let binding = Binding($session) {
                    SessionFields(session: binding,
                                  defaults: plan.prescriber.prescription(for: binding.wrappedValue.planSession(),
                                                                         on: engine.date(binding.wrappedValue.date)),
                                  calendar: engine.calendar)
                    Section {
                        EmptyView()
                    } footer: {
                        Text("Your session is fixed: the app books that exact time, and Claude reworks the rest of the week around it — one request, at most once a minute.")
                    }
                }
            }
            .navigationTitle("Add session")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") { add() }.disabled(session == nil)
                }
            }
            .onAppear {
                guard session == nil else { return }
                session = CustomSession(date: engine.iso(defaultDate), startTime: "06:00",
                                        durationMin: 45, kind: .run, title: "")
            }
        }
    }

    private func add() {
        guard let session else { return }
        plan.custom.save(session)
        dismiss()
        Task {
            await AppServices.shared.syncSchedule()
            await plan.requestUpdate(dashboard: dashboard, calendar: calendarSync, weather: weather)
            await AppServices.shared.syncSchedule()
        }
    }
}
