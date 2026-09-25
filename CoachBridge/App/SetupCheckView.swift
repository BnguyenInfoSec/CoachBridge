import SwiftUI

/// M0 screen: a checklist proving the project is wired correctly on a real iPhone.
/// Replaced by the DayRecord screen in M1.
struct SetupCheckView: View {
    @EnvironmentObject private var health: HealthAuthorizer

    private var googleClientID: String {
        (Bundle.main.object(forInfoDictionaryKey: "GIDClientID") as? String) ?? ""
    }
    private var googleConfigured: Bool {
        googleClientID.hasSuffix(".apps.googleusercontent.com")
    }

    var body: some View {
        List {
            Section("HealthKit") {
                row("Health data available", ok: health.isAvailable,
                    detail: health.isAvailable ? "Yes" : "No — run on an iPhone")
                stateRow("Read permission", state: health.authorization)
                Button("Request Health access") {
                    Task { await health.requestAuthorization() }
                }
                .disabled(!health.isAvailable || health.authorization == .running)

                stateRow("Background delivery entitlement", state: health.backgroundDelivery)
                Button("Check background delivery") {
                    Task { await health.checkBackgroundDeliveryEntitlement() }
                }
                .disabled(!health.isAvailable || health.backgroundDelivery == .running)
            }

            Section("Google Drive (used in M2)") {
                row("OAuth client ID set", ok: googleConfigured,
                    detail: googleConfigured ? "Configured" : "Add Config/Secrets.xcconfig")
            }

            Section("Build") {
                LabeledContent("Bundle ID", value: Bundle.main.bundleIdentifier ?? "?")
                LabeledContent("Version", value: appVersion)
            }
        }
        .navigationTitle("Setup checks")
    }

    private var appVersion: String {
        let v = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let b = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        return "\(v) (\(b))"
    }

    private func row(_ title: String, ok: Bool, detail: String) -> some View {
        HStack {
            Image(systemName: ok ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundStyle(ok ? .green : .red)
            Text(title)
            Spacer()
            Text(detail).foregroundStyle(.secondary).font(.footnote)
        }
    }

    @ViewBuilder
    private func stateRow(_ title: String, state: HealthAuthorizer.CheckState) -> some View {
        switch state {
        case .notRun:
            HStack { Image(systemName: "circle").foregroundStyle(.secondary); Text(title) }
        case .running:
            HStack { ProgressView(); Text(title) }
        case .passed(let msg):
            VStack(alignment: .leading) {
                HStack { Image(systemName: "checkmark.circle.fill").foregroundStyle(.green); Text(title) }
                Text(msg).font(.footnote).foregroundStyle(.secondary)
            }
        case .failed(let msg):
            VStack(alignment: .leading) {
                HStack { Image(systemName: "xmark.circle.fill").foregroundStyle(.red); Text(title) }
                Text(msg).font(.footnote).foregroundStyle(.secondary)
            }
        }
    }
}
