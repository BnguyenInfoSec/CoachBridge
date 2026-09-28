import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @EnvironmentObject private var chat: ChatModel
    @EnvironmentObject private var dashboard: DashboardModel
    @EnvironmentObject private var plan: PlanModel

    @AppStorage(AppSettings.modelKey) private var model = AppSettings.defaultModel
    @AppStorage(AppSettings.profileKey) private var profile = AppSettings.defaultProfile
    @AppStorage(AppSettings.includeHealthKey) private var includeHealth = true
    @AppStorage(AppSettings.planURLKey) private var planURL = AppSettings.defaultPlanURL
    @AppStorage(AppSettings.projectURLKey) private var projectURL = AppSettings.defaultProjectURL

    @AppStorage(Appearance.key) private var appearance = Appearance.system.rawValue

    @AppStorage(LLMProvider.key) private var providerRaw = LLMProvider.anthropic.rawValue
    @AppStorage(AppSettings.hostedURLKey) private var hostedURL = ""

    @State private var keyDraft = ""
    @State private var hasKey = false
    @State private var keyError: String?
    @State private var keyTest: KeyTester.Result?
    @State private var testingKey = false
    @State private var showOnboarding = false
    @AppStorage(DemoData.key) private var demoMode = false
    /// What demo mode was when this screen opened, so leaving it can tell whether to reload.
    @State private var modeOnAppear: Bool?
    @ObservedObject private var fit = AppServices.shared.fit
    @State private var showFITImporter = false
    @State private var fitMessage: String?
    @State private var confirmRemoveFIT = false
    @State private var exportFile: ExportFile?
    /// Kept apart from `exportFile`: SwiftUI clears the sheet's item before onDismiss runs,
    /// so reading it there found nothing and the export stayed in tmp.
    @State private var exportedURL: URL?
    @State private var exportError: String?
    @State private var confirmDelete = false
    @State private var deleted = false

    private var provider: LLMProvider { LLMProvider(rawValue: providerRaw) ?? .anthropic }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Provider", selection: $providerRaw) {
                        ForEach(LLMProvider.allCases) { p in Text(p.label).tag(p.rawValue) }
                    }
                    if provider == .hosted {
                        TextField("Server URL", text: $hostedURL)
                            .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                    }
                    if hasKey {
                        LabeledContent(provider == .hosted ? "Access token" : "API key",
                                       value: "Saved on this iPhone")
                        if provider != .hosted {
                            testButton { Keychain.get(account: provider.keychainAccount) ?? "" }
                        }
                        Button("Remove", role: .destructive) {
                            Keychain.delete(account: provider.keychainAccount)
                            hasKey = false
                        }
                    } else {
                        SecureField(provider.keyPrompt, text: $keyDraft)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        Button("Save") { saveKey() }
                            .disabled(keyDraft.trimmingCharacters(in: .whitespaces).count < 8)
                        if provider != .hosted, keyDraft.trimmingCharacters(in: .whitespaces).count >= 8 {
                            testButton { keyDraft }
                        }
                        if let keyError { Text(keyError).foregroundStyle(.red).font(.footnote) }
                    }
                    Picker("Model", selection: $model) {
                        ForEach(provider.models, id: \.self) { Text($0).tag($0) }
                        if !provider.models.contains(model) { Text(model).tag(model) }
                    }
                    TextField("Or type a model name", text: $model)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(.body.monospaced())
                } header: {
                    Text("Model provider")
                } footer: {
                    Text(provider.costNote + (provider == .hosted
                        ? " The server holds the key; this phone only stores your token."
                        : " The key is kept in this iPhone's Keychain and is sent only to \(provider.label)."))
                }

                Section {
                    NavigationLink {
                        ProfileSetupView()
                    } label: {
                        Label("Your training", systemImage: "figure.run.square.stack")
                    }
                    Toggle("Share my Health summary", isOn: $includeHealth)
                    ZStack(alignment: .topLeading) {
                        if profile.isEmpty {
                            Text(AppSettings.profilePlaceholder)
                                .foregroundStyle(.tertiary)
                                .padding(.top, 8)
                                .allowsHitTesting(false)
                        }
                        TextField("", text: $profile, axis: .vertical)
                            .lineLimit(6...16)
                    }
                } header: {
                    Text("What the coach knows")
                } footer: {
                    Text("Sent with every message. When sharing is on, the coach also gets today's numbers and recent trends; the chat menu has \"See what Claude sees\". Chats are saved on this iPhone only — see History in the Coach tab.")
                }

                Section {
                    Picker("Appearance", selection: $appearance) {
                        ForEach(Appearance.allCases) { a in
                            Text(a.label).tag(a.rawValue)
                        }
                    }
                    .pickerStyle(.segmented)
                } header: {
                    Text("Appearance")
                } footer: {
                    Text("System follows your iPhone's setting, including its light/dark schedule. Both schemes are tuned separately rather than one being a dimmed copy of the other.")
                }

                Section {
                    TextField("My plan page (optional)", text: $planURL)
                        .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                    TextField("Claude project URL", text: $projectURL)
                        .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                } header: {
                    Text("Links")
                } footer: {
                    Text("A plan page of your own opens from the Plan tab's ⋯ menu. The project URL is where \"Continue in the Claude app\" goes.")
                }

                Section {
                    Button {
                        showFITImporter = true
                    } label: {
                        Label("Import FIT files", systemImage: "square.and.arrow.down")
                    }
                    if !fit.workouts.isEmpty {
                        LabeledContent("Imported workouts", value: "\(fit.workouts.count)")
                        let devices = Set(fit.workouts.compactMap(\.device)).sorted()
                        if !devices.isEmpty {
                            LabeledContent("From", value: devices.joined(separator: ", "))
                        }
                        Button("Remove imported workouts", role: .destructive) { confirmRemoveFIT = true }
                    }
                } header: {
                    Text("Other devices")
                } footer: {
                    Text("Bring in rides and runs from a Garmin, Wahoo, Hammerhead or other bike computer: import .fit files here, or open one in Coach Bridge from Files or the share sheet. Only each session's totals are kept — never the route — and a session that's also in Apple Health counts once.")
                }

                Section {
                    Button {
                        do {
                            let url = try PersonalData.export()
                            exportedURL = url
                            exportFile = ExportFile(url: url)
                        } catch {
                            exportError = error.localizedDescription
                        }
                    } label: {
                        Label("Export my data", systemImage: "square.and.arrow.up")
                    }
                    Button(role: .destructive) { confirmDelete = true } label: {
                        Label("Delete my data", systemImage: "trash")
                    }
                    if let exportError { Text(exportError).font(.footnote).foregroundStyle(.red) }
                } header: {
                    Text("Your data")
                } footer: {
                    Text("Export gives you everything Coach Bridge stored — your plan, sessions, chats, workout notes and settings — as one JSON file. Health data stays in Apple Health, which has its own export; API keys are never included. Delete removes all of it from this iPhone and your Watch, signs out of Google and removes the saved keys.")
                }

                Section {
                    Toggle("Demo mode", isOn: $demoMode)
                } header: {
                    Text("Demo")
                } footer: {
                    Text("Fills the app with generated training data — and, if you haven't set up a plan of your own, a sample 70.3 plan — so you can show someone what the app does without an Apple Watch or any Health history. Nothing generated is ever exported to Drive, and the coach is told the numbers aren't real. Turn it off to go back to your own data.")
                }

                Section {
                    Button("Show the walkthrough again") { showOnboarding = true }
                    NavigationLink("Setup checks") { SetupCheckView() }
                }
            }
            .screenBackground(Palette.Tab.settings)
            .navigationTitle("Settings")
            .keyboardDismissible()
            .fullScreenCover(isPresented: $showOnboarding) { OnboardingView() }
            .sheet(item: $exportFile, onDismiss: {
                // The export holds everything; don't leave a copy lying in tmp.
                if let url = exportedURL { try? FileManager.default.removeItem(at: url) }
                exportedURL = nil
            }) { file in
                ShareSheet(items: [file.url])
            }
            .confirmationDialog("Delete all your Coach Bridge data?", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("Delete my data", role: .destructive) {
                    Task { await PersonalData.deleteEverything(removeTrainingCalendar: false); deleted = true }
                }
                Button("Delete my data and the Training calendar", role: .destructive) {
                    Task { await PersonalData.deleteEverything(removeTrainingCalendar: true); deleted = true }
                }
            } message: {
                Text("Removes your plan, sessions, chats, workout notes, imported workouts, places and settings from this iPhone and your Watch, removes scheduled Watch workouts, signs out of Google and deletes your API keys. Apple Health and the files already in your Google Drive aren't touched. This can't be undone; export first if you want a copy.")
            }
            .fullScreenCover(isPresented: $deleted) {
                ContentUnavailableView {
                    Label("Your data has been deleted", systemImage: "checkmark.shield")
                } description: {
                    Text("Close Coach Bridge from the app switcher. It will start fresh, as if newly installed.")
                }
                .interactiveDismissDisabled()
            }
            .fileImporter(isPresented: $showFITImporter, allowedContentTypes: [UTType(filenameExtension: "fit") ?? .data],
                          allowsMultipleSelection: true) { result in
                guard case .success(let urls) = result, !urls.isEmpty else { return }
                Task { fitMessage = await AppServices.shared.importFIT(urls) }
            }
            .alert("FIT import", isPresented: Binding(get: { fitMessage != nil }, set: { if !$0 { fitMessage = nil } })) {
                Button("OK") { fitMessage = nil }
            } message: {
                Text(fitMessage ?? "")
            }
            .confirmationDialog("Remove all imported workouts?", isPresented: $confirmRemoveFIT, titleVisibility: .visible) {
                Button("Remove \(fit.workouts.count) workouts", role: .destructive) {
                    fit.deleteAll()
                    Task {
                        AppServices.shared.plan.invalidateWorkouts()
                        await AppServices.shared.dashboard.refresh(force: true)
                    }
                }
            } message: {
                Text("Removes them from Coach Bridge only. Your FIT files and your device's own records aren't touched.")
            }
            .onChange(of: demoMode) { _, new in
                modeOnAppear = modeOnAppear ?? !new
                Task { await AppServices.shared.demoModeChanged() }
            }
            .onAppear {
                refreshKeyState()
                modeOnAppear = demoMode
            }
            .onDisappear {
                // Belt and braces: the toggle's own refresh can still be in flight, or have
                // raced a Health read that finished afterwards. Leaving Settings with the mode
                // changed always reloads, so no other tab can be showing the other mode's data.
                guard let was = modeOnAppear, was != demoMode else { return }
                modeOnAppear = demoMode
                Task { await AppServices.shared.demoModeChanged() }
            }
            .onChange(of: providerRaw) { _, _ in
                keyTest = nil
                keyDraft = ""
                keyError = nil
                refreshKeyState()
            }
        }
    }

    /// Checks a key for free (the provider's model list) and says plainly whether it works.
    @ViewBuilder
    private func testButton(_ key: @escaping () -> String) -> some View {
        Button {
            testingKey = true
            Task {
                keyTest = await KeyTester.test(provider: provider, key: key())
                testingKey = false
            }
        } label: {
            HStack {
                Text("Test key")
                Spacer()
                if testingKey { ProgressView() }
            }
        }
        .disabled(testingKey)
        if let keyTest {
            Label(keyTest.message, systemImage: keyTest == .valid ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .font(.footnote)
                .foregroundStyle(keyTest == .valid ? Palette.good : Palette.warning)
        }
    }

    private func refreshKeyState() {
        hasKey = Keychain.get(account: provider.keychainAccount) != nil
        if !provider.models.contains(model) && provider != .hosted { model = provider.defaultModel }
    }

    private func saveKey() {
        let key = keyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        // It goes into an HTTP header: visible ASCII only, so it can't smuggle in headers.
        guard PromptSafety.isPlausibleSecret(key) else {
            keyError = "That doesn't look like a key — keys are letters, numbers and symbols with no spaces. Paste it again."
            return
        }
        do {
            try Keychain.set(key,
                             account: provider.keychainAccount)
            keyDraft = ""
            hasKey = true
            keyError = nil
            chat.objectWillChange.send()
        } catch {
            keyError = error.localizedDescription
        }
    }
}

/// An export waiting to be shared.
struct ExportFile: Identifiable {
    let url: URL
    var id: String { url.path }
}

/// The system share sheet, for a file.
struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}
