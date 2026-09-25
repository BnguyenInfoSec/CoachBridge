import Foundation

/// A session the athlete added themselves (a group run, a race, a swim with friends).
/// These are fixed: the app schedules them at the time given, and Claude reworks the
/// rest of the week around them rather than moving them.
struct CustomSession: Codable, Identifiable, Hashable, Sendable {
    var id: UUID = UUID()
    /// "yyyy-MM-dd"
    var date: String
    /// "HH:mm" local
    var startTime: String
    var durationMin: Int
    var kind: SessionKind
    var title: String
    var notes: String = ""
    var createdAt: Date = .now

    func planSession() -> PlanSession {
        PlanSession(kind: kind, title: title, detail: notes,
                    rx: Prescription(durationMin: durationMin),
                    startTime: startTime, customID: id)
    }

    /// One line for Claude.
    func line() -> String {
        var s = "\(date) \(startTime) · \(kind.rawValue) · \(title) · \(durationMin) min"
        if !notes.isEmpty { s += " · \(notes.prefix(200))" }
        return s
    }
}

/// Stores the athlete's own sessions on the phone (Application Support, complete file protection).
@MainActor
final class CustomSessionStore: ObservableObject {
    @Published private(set) var sessions: [CustomSession] = []

    private static var url: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("custom-sessions.json")
    }

    init() { load() }

    func forDay(_ iso: String) -> [CustomSession] {
        sessions.filter { $0.date == iso }.sorted { $0.startTime < $1.startTime }
    }

    func upcoming(from iso: String) -> [CustomSession] {
        sessions.filter { $0.date >= iso }.sorted { ($0.date, $0.startTime) < ($1.date, $1.startTime) }
    }

    func save(_ s: CustomSession) {
        if let i = sessions.firstIndex(where: { $0.id == s.id }) { sessions[i] = s } else { sessions.append(s) }
        persist()
    }

    func delete(_ s: CustomSession) {
        sessions.removeAll { $0.id == s.id }
        persist()
    }

    /// Drops sessions older than 60 days so the file stays small.
    func prune(before iso: String) {
        let old = sessions.count
        sessions.removeAll { $0.date < iso }
        if sessions.count != old { persist() }
    }

    private func load() {
        guard let data = try? Data(contentsOf: Self.url) else { return }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        sessions = (try? dec.decode([CustomSession].self, from: data)) ?? []
    }

    private func persist() {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        guard let data = try? enc.encode(sessions) else { return }
        try? FileManager.default.createDirectory(at: Self.url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: Self.url, options: [.atomic, .completeFileProtection])
    }
}
