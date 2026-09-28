import SwiftUI
import UIKit

/// Asks before anything leaves the phone for the AI provider or Google Drive, at the moment it
/// would first happen, and waits for the answer. Presented from UIKit over whatever is on
/// screen, so it works from a sheet, a tab or a button deep in the plan.
@MainActor
final class ConsentGate {
    static let shared = ConsentGate(askUser: { await ConsentGate.present($0) },
                                    granted: { ConsentGate.isGranted($0) })

    /// Shows the question and returns the answer. Injected so the queueing below can be tested
    /// without UIKit.
    private let askUser: @MainActor (ConsentScope) async -> Bool
    private let granted: @MainActor (ConsentScope) -> Bool

    init(askUser: @escaping @MainActor (ConsentScope) async -> Bool,
         granted: @escaping @MainActor (ConsentScope) -> Bool) {
        self.askUser = askUser
        self.granted = granted
    }
    /// The question on screen, if any. Callers that arrive while it's open share its answer,
    /// and a question for the other scope waits its turn, so two screens never race: the
    /// second presentation would fail and leave its caller waiting forever.
    private var inFlight: (id: UUID, scope: ConsentScope, answer: Task<Bool, Never>)?

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
        while let current = inFlight {
            let answer = await current.answer.value
            if current.scope == scope { return answer }
            // Whoever gets here first clears a finished question, so nobody waits on it again.
            if inFlight?.id == current.id { inFlight = nil }
        }
        if granted(scope) { return true }
        let id = UUID()
        let ask = askUser
        let task = Task { await ask(scope) }
        inFlight = (id, scope, task)
        let answer = await task.value
        if inFlight?.id == id { inFlight = nil }
        return answer
    }

    private static func present(_ scope: ConsentScope) async -> Bool {
        guard let top = await Self.topController() else { return false }
        let who = Self.recipient(scope)
        return await withCheckedContinuation { (done: CheckedContinuation<Bool, Never>) in
            var answered = false
            weak var host: UIViewController?
            func finish(_ allowed: Bool) {
                guard !answered else { return }
                answered = true
                if allowed { Consent.grant(scope, recipient: who.id) }
                done.resume(returning: allowed)
            }
            let view = ConsentView(copy: Consent.copy(scope, recipientName: who.name)) { allowed in
                host?.dismiss(animated: true)
                finish(allowed)
            }
            let controller = UIHostingController(rootView: view)
            controller.isModalInPresentation = true        // answer it; no swipe-away
            host = controller
            top.present(controller, animated: true)
            // UIKit drops a presentation it can't make without calling back. Treat that as
            // "not now" rather than leaving the caller waiting for an answer that never comes.
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(2))
                if controller.presentingViewController == nil { finish(false) }
            }
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
