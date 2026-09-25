import SwiftUI

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
    @State private var showOnboarding = false
    @AppStorage(DemoData.key) private var demoMode = false
    /// What demo mode was when this screen opened, so leaving it can tell whether to reload.
    @State private var modeOnAppear: Bool?

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
            .fullScreenCover(isPresented: $showOnboarding) { OnboardingView() }
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
                keyDraft = ""
                keyError = nil
                refreshKeyState()
            }
        }
    }

    private func refreshKeyState() {
        hasKey = Keychain.get(account: provider.keychainAccount) != nil
        if !provider.models.contains(model) && provider != .hosted { model = provider.defaultModel }
    }

    private func saveKey() {
        do {
            try Keychain.set(keyDraft.trimmingCharacters(in: .whitespacesAndNewlines),
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
