import Combine
import Foundation
import os

/// Loads and caches the dashboard data (shared by the dashboard, chat context and handoff).
@MainActor
final class DashboardModel: ObservableObject {
    @Published private(set) var data: DashboardData?
    @Published private(set) var isLoading = false
    @Published private(set) var errorText: String?

    private let source: any HealthSource

    /// Which mode the numbers on screen came from. Data loaded in the other mode is never shown:
    /// switching demo mode on must not leave real Health readings sitting in the UI.
    private var loadedInDemoMode: Bool?
    /// Bumped on every refresh, so a slow real-Health load that finishes after a mode switch
    /// is discarded instead of overwriting the demo numbers.
    private var generation = 0

    init(source: any HealthSource) { self.source = source }

    /// `force` runs even when a load is already in flight — used when demo mode flips, where
    /// waiting for the old load would mean showing the wrong data in the meantime.
    func refresh(force: Bool = false) async {
        if isLoading, !force { return }
        generation += 1
        let token = generation
        isLoading = true
        defer { if token == generation { isLoading = false } }

        if DemoData.isOn {
            data = DemoData.dashboard()
            loadedInDemoMode = true
            errorText = nil
            return
        }
        do {
            let loaded = try await source.dashboard(now: .now)
            guard token == generation else { return }     // demo mode flipped while we were reading
            data = loaded
            loadedInDemoMode = false
            errorText = nil
        } catch {
            guard token == generation else { return }
            errorText = error.localizedDescription
        }
    }

    /// Reloads if there's no data, it came from the other mode, or it's more than 15 minutes old.
    func ensureLoaded() async {
        if let d = data, loadedInDemoMode == DemoData.isOn,
           Date.now.timeIntervalSince(d.generatedAt) < 15 * 60 { return }
        await refresh()
    }

    /// Demo mode was turned on or off. Drop what's on screen *before* anything can read it,
    /// then load the other set.
    func demoModeChanged() async {
        data = nil
        errorText = nil
        loadedInDemoMode = nil
        await refresh(force: true)
    }
}

/// In-app chat. Conversations are saved on the phone (see `ChatStore`) and listed in History.
@MainActor
final class ChatModel: ObservableObject {
    @Published private(set) var messages: [ChatMessage] = []
    @Published private(set) var isStreaming = false
    @Published var errorText: String?
    /// Exactly what was sent as the system prompt last time — viewable in the chat screen.
    @Published private(set) var lastSystemPrompt: String?
    /// A plan change Claude wants to make; applied only when the athlete taps Apply.
    @Published var proposal: PlanProposal?
    @Published private(set) var appliedNote: String?

    /// Saved conversations. The one on screen is `conversationID`.
    let history = ChatStore()
    @Published private(set) var conversationID = UUID()

    private var bag: Set<AnyCancellable> = []
    private var task: Task<Void, Never>?
    private var smoother: StreamSmoother?
    private let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "CoachBridge", category: "chat")

    init() {
        history.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }.store(in: &bag)
    }

    /// True when the chosen provider has a key (or token) to work with.
    var hasAPIKey: Bool { LLMFactory.isConfigured }

    func send(_ raw: String, dashboard: DashboardModel, plan: PlanModel) {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isStreaming else { return }
        let canEdit = UserDefaults.standard.object(forKey: AppSettings.chatCanEditPlanKey) as? Bool ?? true
        guard let setup = LLMFactory.current(maxTokens: canEdit ? 3000 : 1500) else {
            errorText = AnthropicClient.APIError.missingKey.localizedDescription
            return
        }
        errorText = nil
        messages.append(ChatMessage(role: .user, text: text))
        let reply = ChatMessage(role: .assistant, text: "")
        messages.append(reply)
        isStreaming = true

        task = Task { [weak self] in
            guard let self else { return }
            defer { self.isStreaming = false; self.removeIfEmpty(reply.id) }

            let defaults = UserDefaults.standard
            let include = defaults.object(forKey: AppSettings.includeHealthKey) as? Bool ?? true
            if include { await dashboard.ensureLoaded() }
            var summary = include ? dashboard.data.map { CoachContext.healthSummary($0) } : nil
            // What the athlete said about their own sessions. Heart rate can't tell you that
            // Tuesday's easy run felt like a fight; their rating can.
            if include, let effort = AppServices.shared.review.journal.effortSummary() {
                summary = (summary.map { $0 + "\n\n" } ?? "") + effort
                    + "\n(RPE is Borg CR10: 1 is barely moving, 10 is everything they had.)"
            }
            let profile = defaults.string(forKey: AppSettings.profileKey) ?? AppSettings.defaultProfile
            let athlete = CoachContext.athleteText(plan.profile, engine: plan.engine)
                + (DemoData.isOn ? "\n\nNOTE: demo mode is on — the Health numbers below are generated sample data, not this person's real data. Say so if you refer to them." : "")
            let system = CoachContext.systemPrompt(profile: profile, healthSummary: summary, now: .now,
                                                   athlete: athlete,
                                                   planText: CoachContext.planText(plan: plan),
                                                   canEditPlan: canEdit)
            self.lastSystemPrompt = system

            let context = Self.trimHistory(self.messages.filter { $0.id != reply.id })
            let client = setup.client
            do {
                // Text goes through the smoother so the reply reads at a steady pace instead
                // of arriving in lurches.
                let smoother = StreamSmoother { [weak self] piece in
                    guard let self, let i = self.messages.firstIndex(where: { $0.id == reply.id }) else { return }
                    self.messages[i].text += piece
                }
                self.smoother = smoother

                for try await event in client.stream(system: system, messages: context,
                                                     tools: canEdit ? [PlanChangeTool.schema] : []) {
                    switch event {
                    case .text(let chunk):
                        smoother.push(chunk)
                    case .toolUse(let name, let json):
                        guard name == PlanChangeTool.name, let data = json.data(using: .utf8) else { continue }
                        do {
                            let e = plan.engine
                            let p = try PlanChangeTool.parse(data, todayISO: e.iso(.now),
                                                             bounds: e.startISO...e.endISO)
                            if !p.isEmpty {
                                self.proposal = p
                                if let i = self.messages.firstIndex(where: { $0.id == reply.id }), self.messages[i].text.isEmpty {
                                    self.messages[i].text = p.summary
                                }
                            }
                        } catch {
                            self.errorText = error.localizedDescription
                        }
                    }
                }
                self.log.info("Reply finished (\(context.count, privacy: .public) messages in context)")
            } catch is CancellationError {
                self.log.info("Reply stopped")
            } catch {
                self.errorText = error.localizedDescription
                self.log.error("Chat failed: \(error.localizedDescription, privacy: .public)")
            }
            // Release anything still buffered before saving, or the stored copy is short.
            self.smoother?.finish()
            self.smoother = nil
            // Save whatever was said, including a reply that was stopped part way.
            self.history.save(id: self.conversationID, messages: self.messages)
        }
    }

    func stop() {
        smoother?.cancel()
        task?.cancel()
    }

    /// Applies the pending proposal and re-syncs the calendar and Watch.
    func applyProposal(plan: PlanModel) async {
        guard let p = proposal else { return }
        plan.apply(p)
        proposal = nil
        appliedNote = "Applied: \(p.summary)"
        messages.append(ChatMessage(role: .assistant, text: "✅ Applied. \(p.bullets.joined(separator: "\n"))"))
        await AppServices.shared.syncSchedule()
    }

    func discardProposal() {
        proposal = nil
        appliedNote = nil
    }

    /// Files the conversation on screen and starts an empty one.
    func newChat() {
        stop()
        history.save(id: conversationID, messages: messages)
        conversationID = UUID()
        reset()
    }

    /// Opens a saved conversation, filing the current one first.
    func open(_ c: Conversation) {
        stop()
        history.save(id: conversationID, messages: messages)
        conversationID = c.id
        reset()
        messages = c.chatMessages
    }

    /// Deletes a saved conversation; if it's the one on screen, clears the screen too.
    func delete(_ c: Conversation) {
        history.delete(c.id)
        if c.id == conversationID {
            conversationID = UUID()
            reset()
        }
    }

    /// Drops the copy of the last system prompt, which "See what Claude sees" shows verbatim —
    /// after a demo-mode switch it would still be quoting the other mode's Health numbers.
    func clearContextCache() { lastSystemPrompt = nil }

    private func reset() {
        messages = []
        errorText = nil
        lastSystemPrompt = nil
        proposal = nil
        appliedNote = nil
    }

    private func removeIfEmpty(_ id: UUID) {
        if let i = messages.firstIndex(where: { $0.id == id }), messages[i].text.isEmpty {
            messages.remove(at: i)
        }
    }

    /// Last 20 turns, starting with a user message (the API requires it), no empty messages.
    nonisolated static func trimHistory(_ all: [ChatMessage], limit: Int = 20) -> [ChatMessage] {
        var h = Array(all.filter { !$0.text.isEmpty }.suffix(limit))
        while let first = h.first, first.role != .user { h.removeFirst() }
        return h
    }
}
