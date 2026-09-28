import SwiftUI
import UIKit

/// Asks before anything leaves the phone for the AI provider or Google Drive, at the moment it
/// would first happen, and waits for the answer. Presented from UIKit over whatever is on
/// screen, so it works from a sheet, a tab or a button deep in the plan.
@MainActor
final class ConsentGate {
    static let shared = ConsentGate()
    private var asking = false

    /// The recipient for a scope as the app is set up right now.
    static func recipient(_ scope: ConsentScope) -> (id: String, name: String) {
        switch scope {
        case .ai:
            let d = UserDefaults.standard
            let provider = LLMProvider(rawValue: d.string(forKey: LLMProvider.key) ?? "") ?? .anthropic
            let url = d.string(forKey: AppSettings.hostedURLKey) ?? ""
            let name: String
            switch provider {
            case .anthropic: name = "Anthropic's Claude"
            case .openai: name = "OpenAI"
            case .hosted: name = PromptSafety.webURL(url)?.host.map { "the server at \($0)" } ?? "your server"
            }
            return (Consent.aiRecipient(provider: provider.rawValue, hostedURL: provider == .hosted ? url : nil), name)
        case .drive:
            return (Consent.driveRecipient, "Google Drive")
        }
    }

    static func isGranted(_ scope: ConsentScope) -> Bool {
        Consent.isGranted(scope, recipient: recipient(scope).id)
    }

    /// True if the athlete has agreed, asking them now if they haven't. False if they decline,
    /// or if there's nothing on screen to ask from (a background launch never asks).
    func require(_ scope: ConsentScope) async -> Bool {
        if Self.isGranted(scope) { return true }
        guard !asking, let top = await Self.topController() else { return false }
        asking = true
        defer { asking = false }
        let who = Self.recipient(scope)
        return await withCheckedContinuation { (done: CheckedContinuation<Bool, Never>) in
            var answered = false
            weak var host: UIViewController?
            let view = ConsentView(copy: Consent.copy(scope, recipientName: who.name)) { allowed in
                guard !answered else { return }
                answered = true
                if allowed { Consent.grant(scope, recipient: who.id) }
                host?.dismiss(animated: true)
                done.resume(returning: allowed)
            }
            let controller = UIHostingController(rootView: view)
            controller.isModalInPresentation = true        // answer it; no swipe-away
            host = controller
            top.present(controller, animated: true)
        }
    }

    /// The controller on top, once nothing is mid-dismissal (a sheet that just saved and is
    /// sliding away can't present anything). Gives up after a couple of seconds.
    private static func topController() async -> UIViewController? {
        for _ in 0..<25 {
            let scene = UIApplication.shared.connectedScenes
                .compactMap { $0 as? UIWindowScene }
                .first { $0.activationState == .foregroundActive }
            guard var top = scene?.keyWindow?.rootViewController else { return nil }
            var busy = false
            while let next = top.presentedViewController {
                if next.isBeingDismissed { busy = true; break }
                top = next
            }
            if !busy && !top.isBeingPresented && !top.isBeingDismissed { return top }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return nil
    }
}

struct ConsentView: View {
    let copy: Consent.Copy
    let answer: (Bool) -> Void

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text(copy.title).font(.title2.bold())
                        .fixedSize(horizontal: false, vertical: true)
                        .listRowBackground(Color.clear)
                }
                Section("What's shared") {
                    ForEach(copy.sent, id: \.self) { Label($0, systemImage: "arrow.up.circle").font(.callout) }
                }
                Section("Never shared") {
                    ForEach(copy.notSent, id: \.self) { Label($0, systemImage: "lock.fill").font(.callout) }
                }
                Section("Where it goes") { Text(copy.whereItGoes).font(.callout) }
                Section("When") { Text(copy.when).font(.callout) }
                Section { Text(copy.withdraw).font(.footnote).foregroundStyle(.secondary) }
            }
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: 10) {
                    Button { answer(true) } label: {
                        Text("Allow").fontWeight(.semibold).frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent).controlSize(.large)
                    Button { answer(false) } label: {
                        Text("Don't allow").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered).controlSize(.large)
                }
                .padding()
                .background(.bar)
            }
            .navigationTitle("Before anything is shared")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}
