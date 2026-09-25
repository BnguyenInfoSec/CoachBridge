import Foundation

/// One saved conversation. Titles are taken from the opening question, so the list reads like
/// a list of things you asked rather than "Chat 4".
struct Conversation: Codable, Identifiable, Hashable, Sendable {
    var id: UUID = UUID()
    var title: String
    var messages: [StoredMessage]
    var createdAt: Date = .now
    var updatedAt: Date = .now

    struct StoredMessage: Codable, Hashable, Sendable {
        var role: String
        var text: String
    }

    var preview: String {
        messages.last(where: { $0.role == ChatMessage.Role.assistant.rawValue })?.text
            ?? messages.first?.text ?? ""
    }

    /// First line of the opening question, clipped. "How recovered am I today…" beats "Chat 4".
    static func title(from messages: [ChatMessage]) -> String {
        guard let first = messages.first(where: { $0.role == .user })?.text
            .trimmingCharacters(in: .whitespacesAndNewlines), !first.isEmpty else { return "New chat" }
        let line = first.split(separator: "\n").first.map(String.init) ?? first
        return line.count > 48 ? String(line.prefix(47)) + "…" : line
    }

    init(id: UUID = UUID(), from messages: [ChatMessage], createdAt: Date = .now, now: Date = .now) {
        self.id = id
        self.title = Self.title(from: messages)
        self.messages = messages.map { .init(role: $0.role.rawValue, text: $0.text) }
        self.createdAt = createdAt
        self.updatedAt = now
    }

    var chatMessages: [ChatMessage] {
        messages.map { ChatMessage(role: ChatMessage.Role(rawValue: $0.role) ?? .assistant, text: $0.text) }
    }
}

/// Saved conversations on the phone. Complete file protection, same as the plan files — chats
/// carry health talk, so they're readable only while the phone is unlocked, and they never leave.
@MainActor
final class ChatStore: ObservableObject {
    @Published private(set) var conversations: [Conversation] = []

    /// Oldest chats fall off rather than growing without bound.
    static let limit = 100

    private static var url: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("chats.json")
    }

    init() { load() }

    /// Newest first, grouped into Today / Yesterday / Previous 7 days / Earlier.
    func grouped(calendar: Calendar = .current, now: Date = .now) -> [(String, [Conversation])] {
        let sorted = conversations.sorted { $0.updatedAt > $1.updatedAt }
        var buckets: [(String, [Conversation])] = []
        func add(_ name: String, _ list: [Conversation]) { if !list.isEmpty { buckets.append((name, list)) } }
        let weekAgo = calendar.date(byAdding: .day, value: -7, to: now) ?? now
        add("Today", sorted.filter { calendar.isDateInToday($0.updatedAt) })
        add("Yesterday", sorted.filter { calendar.isDateInYesterday($0.updatedAt) })
        add("Previous 7 days", sorted.filter {
            !calendar.isDateInToday($0.updatedAt) && !calendar.isDateInYesterday($0.updatedAt) && $0.updatedAt >= weekAgo
        })
        add("Earlier", sorted.filter { $0.updatedAt < weekAgo })
        return buckets
    }

    /// Creates or updates the conversation with this id. Empty conversations are never saved.
    func save(id: UUID, messages: [ChatMessage]) {
        let real = messages.filter { !$0.text.trimmingCharacters(in: .whitespaces).isEmpty }
        guard real.contains(where: { $0.role == .user }) else { return }
        if let i = conversations.firstIndex(where: { $0.id == id }) {
            let created = conversations[i].createdAt
            let kept = conversations[i].title
            var c = Conversation(id: id, from: real, createdAt: created)
            // A hand-picked name survives new messages.
            if kept != Conversation.title(from: conversations[i].chatMessages) { c.title = kept }
            conversations[i] = c
        } else {
            conversations.append(Conversation(id: id, from: real))
        }
        trim()
        persist()
    }

    func conversation(_ id: UUID) -> Conversation? { conversations.first { $0.id == id } }

    func rename(_ id: UUID, to title: String) {
        guard let i = conversations.firstIndex(where: { $0.id == id }) else { return }
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        conversations[i].title = t.isEmpty ? conversations[i].title : String(t.prefix(60))
        persist()
    }

    func delete(_ id: UUID) {
        conversations.removeAll { $0.id == id }
        persist()
    }

    func deleteAll() {
        conversations = []
        persist()
    }

    private func trim() {
        guard conversations.count > Self.limit else { return }
        conversations = conversations.sorted { $0.updatedAt > $1.updatedAt }.prefix(Self.limit).map { $0 }
    }

    private func load() {
        guard let data = try? Data(contentsOf: Self.url) else { return }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        conversations = (try? dec.decode([Conversation].self, from: data)) ?? []
    }

    private func persist() {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        guard let data = try? enc.encode(conversations) else { return }
        try? FileManager.default.createDirectory(at: Self.url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: Self.url, options: [.atomic, .completeFileProtection])
    }
}
