import SwiftUI
import UIKit

/// Coach tab: chat with Claude in the app (API), or hand off to the Claude app.
struct ChatView: View {
    @EnvironmentObject private var chat: ChatModel
    @EnvironmentObject private var dashboard: DashboardModel
    @EnvironmentObject private var plan: PlanModel
    @Environment(\.openURL) private var openURL

    @AppStorage(AppSettings.includeHealthKey) private var includeHealth = true
    @AppStorage(AppSettings.projectURLKey) private var projectURL = AppSettings.defaultProjectURL

    @State private var draft = ""
    @State private var showContext = false
    @State private var showHistory = false
    @State private var handoffNote: String?
    @FocusState private var inputFocused: Bool

    private let starters = [
        "How recovered am I today, and what should today's session look like?",
        "How did my training load look this week?",
        "What should I focus on this week for the bike?",
    ]

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 12) {
                            if chat.messages.isEmpty { emptyState }
                            ForEach(chat.messages) { m in
                                Bubble(message: m, isStreaming: chat.isStreaming && m.id == chat.messages.last?.id)
                                    .id(m.id)
                            }
                            if let p = chat.proposal {
                                ProposalCard(proposal: p,
                                             apply: { Task { await chat.applyProposal(plan: plan) } },
                                             discard: { chat.discardProposal() })
                                    .id(p.id)
                            }
                            if let err = chat.errorText {
                                Label(err, systemImage: "exclamationmark.triangle.fill")
                                    .font(.footnote).foregroundStyle(.red)
                            }
                        }
                        .padding(16)
                    }
                    .scrollDismissesKeyboard(.interactively)
                    .simultaneousGesture(TapGesture().onEnded { inputFocused = false })
                    .screenBackground(Palette.Tab.coach)
                    .softScrollEdges()
                    .onChange(of: chat.messages.last?.text) { _, _ in
                        if let id = chat.messages.last?.id { proxy.scrollTo(id, anchor: .bottom) }
                    }
                }
                inputBar
            }
            .navigationTitle("Coach")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") { inputFocused = false }
                }
                ToolbarItem(placement: .topBarLeading) {
                    Menu {
                        Toggle("Share my Health summary", isOn: $includeHealth)
                        Button("See what Claude sees", systemImage: "doc.text.magnifyingglass") { showContext = true }
                            .disabled(chat.lastSystemPrompt == nil)
                        Button("Open in Claude app", systemImage: "arrow.up.forward.app") { handoff() }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("History", systemImage: "clock.arrow.circlepath") { showHistory = true }
                        .disabled(chat.history.conversations.isEmpty && chat.messages.isEmpty)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("New chat", systemImage: "square.and.pencil") { chat.newChat() }
                        .disabled(chat.messages.isEmpty)
                }
            }
            .sheet(isPresented: $showHistory) { ChatHistoryView() }
            .sheet(isPresented: $showContext) {
                NavigationStack {
                    ScrollView {
                        Text(chat.lastSystemPrompt ?? "")
                            .font(.caption.monospaced()).textSelection(.enabled).padding()
                    }
                    .navigationTitle("Sent to Claude")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar { Button("Done") { showContext = false } }
                }
            }
            .overlay(alignment: .top) {
                if let note = handoffNote {
                    Text(note)
                        .font(.footnote).padding(.horizontal, 14).padding(.vertical, 8)
                        .background(.thinMaterial, in: Capsule())
                        .padding(.top, 8)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
        }
    }

    // MARK: Pieces

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Ask your coach").font(.title2.bold())
            Text(includeHealth
                 ? "Claude gets today's numbers, 2 weeks of resting HR and HRV, 8 weeks of training hours, and your recent workouts."
                 : "Health sharing is off: Claude only sees your profile from Settings.")
                .font(.subheadline).foregroundStyle(.secondary)
            if !chat.hasAPIKey {
                Label("Add your Anthropic API key in Settings to chat here.", systemImage: "key.fill")
                    .font(.subheadline).foregroundStyle(.orange)
            }
            ForEach(starters, id: \.self) { s in
                Button { send(s) } label: {
                    Text(s).font(.subheadline).multilineTextAlignment(.leading)
                        .glassCard(radius: 14, tint: Palette.Tab.coach, padding: 12)
                }
                .buttonStyle(.plain)
            }
            Divider().padding(.vertical, 4)
            Button { handoff() } label: {
                Label("Continue in the Claude app", systemImage: "arrow.up.forward.app")
            }
            Text("Copies today's numbers, then opens your Fitness Coach project, which has your plan, memory and Strava. Paste to start.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var inputBar: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField("Message", text: $draft, axis: .vertical)
                .lineLimit(1...5)
                .focused($inputFocused)
                .submitLabel(.send)
                .onSubmit { send(draft) }
                .padding(.horizontal, 14).padding(.vertical, 9)
                .glassSurface(radius: 20)
            if chat.isStreaming {
                Button { chat.stop() } label: { Image(systemName: "stop.circle.fill").font(.title) }
                    .accessibilityLabel("Stop")
            } else {
                Button { send(draft) } label: { Image(systemName: "arrow.up.circle.fill").font(.title) }
                    .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityLabel("Send")
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(.bar)
    }

    // MARK: Actions

    private func send(_ text: String) {
        chat.send(text, dashboard: dashboard, plan: plan)
        draft = ""
    }

    private func handoff() {
        Task {
            await dashboard.ensureLoaded()
            if let d = dashboard.data {
                UIPasteboard.general.string = CoachContext.handoffText(d)
                flash("Copied today's numbers. Paste them into the chat.")
            }
            if let url = PromptSafety.webURL(projectURL) { openURL(url) }
        }
    }

    private func flash(_ text: String) {
        withAnimation { handoffNote = text }
        Task {
            try? await Task.sleep(for: .seconds(3))
            withAnimation { handoffNote = nil }
        }
    }
}

/// Saved conversations, newest first.
private struct ChatHistoryView: View {
    @EnvironmentObject private var chat: ChatModel
    @Environment(\.dismiss) private var dismiss
    @State private var renaming: Conversation?
    @State private var newTitle = ""
    @State private var confirmClear = false

    var body: some View {
        NavigationStack {
            List {
                if chat.history.conversations.isEmpty {
                    ContentUnavailableView("No saved chats", systemImage: "bubble.left.and.text.bubble.right",
                                           description: Text("Conversations are saved here once you've asked something."))
                }
                ForEach(chat.history.grouped(), id: \.0) { section, items in
                    Section(section) {
                        ForEach(items) { c in
                            Button {
                                chat.open(c)
                                dismiss()
                            } label: {
                                VStack(alignment: .leading, spacing: 3) {
                                    HStack {
                                        Text(c.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                                        if c.id == chat.conversationID {
                                            Text("OPEN").font(.system(size: 9, weight: .bold))
                                                .padding(.horizontal, 4).padding(.vertical, 1)
                                                .background(Palette.series3.opacity(0.25), in: Capsule())
                                        }
                                    }
                                    Text(c.preview).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                                    Text(c.updatedAt.formatted(date: .abbreviated, time: .shortened))
                                        .font(.caption2).foregroundStyle(.tertiary)
                                }
                            }
                            .buttonStyle(.plain)
                            .swipeActions(edge: .trailing) {
                                Button("Delete", role: .destructive) { chat.delete(c) }
                                Button("Rename") { renaming = c; newTitle = c.title }.tint(Palette.series1)
                            }
                        }
                    }
                }
            }
            .screenBackground(Palette.Tab.coach)
            .navigationTitle("History")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Delete all", role: .destructive) { confirmClear = true }
                        .disabled(chat.history.conversations.isEmpty)
                }
            }
            .confirmationDialog("Delete every saved chat? This can't be undone.",
                                isPresented: $confirmClear, titleVisibility: .visible) {
                Button("Delete all chats", role: .destructive) { chat.history.deleteAll() }
            }
            .alert("Rename chat", isPresented: Binding(get: { renaming != nil },
                                                       set: { if !$0 { renaming = nil } })) {
                TextField("Name", text: $newTitle)
                Button("Save") {
                    if let c = renaming { chat.history.rename(c.id, to: newTitle) }
                    renaming = nil
                }
                Button("Cancel", role: .cancel) { renaming = nil }
            }
        }
    }
}

/// Claude's proposed plan change, with Apply / Discard.
private struct ProposalCard: View {
    let proposal: PlanProposal
    let apply: () -> Void
    let discard: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Proposed plan change", systemImage: "calendar.badge.plus")
                .font(.subheadline.bold()).foregroundStyle(Palette.series7)
            Text(proposal.summary).font(.subheadline)
            ForEach(proposal.bullets, id: \.self) { b in
                HStack(alignment: .top, spacing: 6) {
                    Text("•")
                    Text(b).font(.caption)
                }
                .foregroundStyle(.secondary)
            }
            HStack {
                Button("Apply", action: apply).glassButton(prominent: true)
                Button("Discard", role: .cancel, action: discard).glassButton()
            }
            .font(.subheadline)
        }
        .glassCard(radius: 18, tint: Palette.series7, padding: 14)
    }
}

/// The athlete's turns are a solid sport-blue capsule; Claude's are glass, so the two read
/// apart at a glance even in bright sun.
private struct BubbleBackground: ViewModifier {
    let isUser: Bool

    func body(content: Content) -> some View {
        if isUser {
            content.background(
                LinearGradient(colors: [Palette.series1, Palette.series7.opacity(0.85)],
                               startPoint: .topLeading, endPoint: .bottomTrailing),
                in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        } else {
            content.glassSurface(radius: 18)
        }
    }
}

private struct Bubble: View {
    let message: ChatMessage
    let isStreaming: Bool

    var body: some View {
        HStack {
            if message.role == .user { Spacer(minLength: 40) }
            Group {
                if message.text.isEmpty && isStreaming {
                    ProgressView().padding(.vertical, 4)
                } else if message.role == .assistant {
                    Text(Self.markdown(message.text))
                } else {
                    Text(message.text)
                }
            }
            .textSelection(.enabled)
            .padding(12)
            .modifier(BubbleBackground(isUser: message.role == .user))
            .foregroundStyle(message.role == .user ? Color.white : Color.primary)
            if message.role == .assistant { Spacer(minLength: 24) }
        }
    }

    /// Inline markdown (bold, italics, links) with line breaks kept.
    static func markdown(_ s: String) -> AttributedString {
        (try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(s)
    }
}
