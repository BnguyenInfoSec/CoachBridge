import SwiftUI

/// M1 + M2 screen: pick a day, see every metric with how it was computed,
/// preview the exact JSON, and upload it to Drive.
struct TodayView: View {
    @EnvironmentObject private var health: HealthAuthorizer
    @EnvironmentObject private var google: GoogleAuth
    @EnvironmentObject private var exporter: Exporter

    @State private var day = Date()
    @State private var build: DayBuild?
    @State private var isReading = false

    var body: some View {
        NavigationStack {
            List {
                daySection
                metricsSection
                jsonSection
                driveSection
                autoSection
                Section {
                    NavigationLink("Setup checks (M0)") { SetupCheckView() }
                }
            }
            .screenBackground(Palette.Tab.sync)
            .navigationTitle("Sync")
            .refreshable { await read() }
            .task(id: day) { await read() }
        }
    }

    // MARK: Sections

    private var daySection: some View {
        Section {
            DatePicker("Check-in day", selection: $day, in: ...Date(), displayedComponents: .date)
            if let build {
                LabeledContent("Metrics present",
                               value: "\(build.record.metrics.count) of \(MetricKey.allCases.count)")
            }
        } footer: {
            Text("Sleep, HRV, breathing, SpO₂ and wrist temp use 6 PM the night before to noon. Activity totals are for the day before. Pull down to re-read.")
        }
    }

    private var metricsSection: some View {
        Section("Metrics") {
            if isReading && build == nil {
                ProgressView("Reading Health…")
            } else if let build {
                ForEach(build.readings) { r in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text(r.key.title)
                            Spacer()
                            if let v = r.value {
                                Text("\(r.key.format(v)) \(r.key.unitLabel)").monospacedDigit().bold()
                            } else {
                                Text("not logged").foregroundStyle(.secondary)
                            }
                        }
                        Text(r.detail).font(.caption).foregroundStyle(.secondary)
                    }
                    .opacity(r.value == nil ? 0.6 : 1)
                }
            }
        }
    }

    private var jsonSection: some View {
        Section {
            if let build {
                DisclosureGroup("JSON preview · \(build.record.fileName)") {
                    Text(build.record.jsonString())
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                }
            }
        }
    }

    private var driveSection: some View {
        Section {
            if let email = google.email {
                LabeledContent("Google", value: email)
                Button {
                    Task { if let build { await exporter.export(build.record) } }
                } label: {
                    HStack {
                        Text("Export to Drive")
                        Spacer()
                        if exporter.isExporting { ProgressView() }
                    }
                }
                .disabled(build == nil || exporter.isExporting || !google.hasDriveScope)

                if let r = exporter.lastResult {
                    Label("\(r.outcome == .created ? "Created" : "Updated") Coach/health/\(r.fileName) at \(r.at.formatted(date: .omitted, time: .shortened))",
                          systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green).font(.footnote)
                }
                if let err = exporter.lastError {
                    Label(err, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red).font(.footnote)
                }
                Button("Sign out of Google", role: .destructive) {
                    Task { await google.signOut() }
                }
            } else {
                Button("Sign in with Google") {
                    Task { if await ConsentGate.shared.require(.drive) { await google.signIn() } }
                }
                if let err = google.lastError {
                    Text(err).foregroundStyle(.red).font(.footnote)
                }
            }
        } header: {
            Text("Google Drive")
        } footer: {
            Text("Coach Bridge can only see files it creates in your Drive. Re-exporting a day overwrites that day's file.")
        }
    }

    private var autoSection: some View {
        Section {
            if let last = exporter.lastAutoSuccess {
                LabeledContent("Last automatic export") {
                    Text(last, format: .relative(presentation: .named))
                }
                if let summary = exporter.lastAutoSummary {
                    Text(summary).font(.footnote).foregroundStyle(.secondary)
                }
            } else {
                Text("No automatic export yet").foregroundStyle(.secondary)
            }
            Button {
                Task { await exporter.runAutomatic(trigger: .manual) }
            } label: {
                HStack {
                    Text("Sync now (today, yesterday + missing days)")
                    Spacer()
                    if exporter.isExporting { ProgressView() }
                }
            }
            .disabled(!google.isSignedIn || exporter.isExporting)
        } header: {
            Text("Automatic export")
        } footer: {
            Text("Runs each morning after you first unlock your phone, whenever new Health data arrives, and when you open the app. Fills in any missing days from the last 60.")
        }
    }

    // MARK: Actions

    private func read() async {
        isReading = true
        defer { isReading = false }
        if health.authorization == .notRun {
            await health.requestAuthorization()   // shows the Health sheet only the first time
        }
        build = await AppServices.shared.source.day(day)
    }
}
