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
    /// Targets the athlete typed in. Anything left nil is filled from the plan's own rules.
    /// Optional, like the two below, so files written before v2.8 still decode.
    var rx: Prescription? = nil
    var indoor: Bool? = nil
    /// Set when this began as a planned session the athlete edited: that day's first planned
    /// session of this kind is hidden, so the edit replaces it instead of doubling the day.
    var replaces: SessionKind? = nil

    /// Longest text kept per field. All of it is typed by the athlete and then sent to Claude
    /// and written to the calendar, so it's capped rather than trusted.
    static let maxTitle = 120
    static let maxNotes = 1_000
    static let maxTarget = 80
    static let durationRange = 5...720

    func planSession() -> PlanSession {
        var r = rx ?? Prescription()
        r.durationMin = durationMin
        return PlanSession(kind: kind, title: title, detail: notes, rx: r,
                           startTime: startTime, customID: id, indoor: indoor)
    }

    /// One line for Claude.
    func line() -> String {
        var s = "\(date) \(startTime) · \(kind.rawValue) · \(title) · \(durationMin) min"
        let targets = [rx?.distance, rx?.intensity, rx?.heartRate, rx?.power, rx?.pace].compactMap { $0 }
        if !targets.isEmpty { s += " · \(targets.joined(separator: ", "))" }
        if indoor == true { s += " · indoor" }
        if !notes.isEmpty { s += " · \(notes.prefix(200))" }
        return s
    }

    /// A planned session the athlete starts editing becomes theirs: same content, now fixed,
    /// hiding the planned original. `startTime` is where the calendar placed it, if anywhere.
    static func adopting(_ s: PlanSession, on iso: String, startTime: String?) -> CustomSession {
        var c = CustomSession(date: iso, startTime: startTime ?? s.startTime ?? "06:00",
                              durationMin: s.rx?.durationMin ?? 45, kind: s.kind,
                              title: s.title, notes: s.detail)
        c.rx = s.rx
        c.indoor = s.indoor
        c.replaces = s.kind
        return c.sanitized()
    }

    /// An optional session made definite: the sport it actually is (from its title — "Optional
    /// easy run" is a run), "Optional" dropped from the title, and adopted like any edit, so it
    /// replaces the optional slot and Claude plans around it.
    static func committing(_ s: PlanSession, on iso: String, startTime: String?) -> CustomSession {
        var c = adopting(s, on: iso, startTime: startTime)
        guard s.kind == .flex else { return c }
        switch Prescriber.sport(of: s) {
        case .swim: c.kind = .swim
        case .bike: c.kind = .bike
        case .run: c.kind = .run
        case .lift: c.kind = .lift
        case .other: break                     // can't tell: stays optional in kind, but committed
        }
        let stripped = c.title.replacingOccurrences(of: "(?i)^optional\\s*", with: "", options: .regularExpression)
        c.title = stripped.isEmpty ? c.kind.label : stripped.prefix(1).uppercased() + stripped.dropFirst()
        c.replaces = .flex
        return c.sanitized()
    }

    /// Clamps every field to something sane. Applied on every save: the values come from text
    /// fields and end up in Claude's prompt, the calendar and the Watch.
    func sanitized() -> CustomSession {
        var c = self
        c.title = Self.oneLine(title, max: Self.maxTitle)
        if c.title.isEmpty { c.title = kind.label }
        c.notes = Self.clean(notes, max: Self.maxNotes)
        c.durationMin = min(max(durationMin, Self.durationRange.lowerBound), Self.durationRange.upperBound)
        if !Self.isTime(startTime) { c.startTime = "06:00" }
        if var r = rx {
            func target(_ t: String?) -> String? {
                let v = t.map { Self.oneLine($0, max: Self.maxTarget) } ?? ""
                return v.isEmpty ? nil : v
            }
            r.durationMin = nil        // `durationMin` on the session is the one source of truth
            r.distance = target(r.distance)
            r.intensity = target(r.intensity)
            r.heartRate = target(r.heartRate)
            r.power = target(r.power)
            r.pace = target(r.pace)
            c.rx = r
        }
        return c
    }

    /// Drops control characters (keeping line breaks), trims, and caps the length.
    static func clean(_ t: String, max: Int) -> String {
        let kept = t.unicodeScalars.filter { $0 == "\n" || !CharacterSet.controlCharacters.contains($0) }
        return String(String(String.UnicodeScalarView(kept))
            .trimmingCharacters(in: .whitespacesAndNewlines).prefix(max))
    }

    /// `clean`, with line breaks turned into spaces — for titles and targets.
    static func oneLine(_ t: String, max: Int) -> String {
        clean(t.replacingOccurrences(of: "\n", with: " "), max: max)
    }

    /// "HH:mm", 00:00–23:59.
    static func isTime(_ t: String) -> Bool {
        let p = t.split(separator: ":", omittingEmptySubsequences: false)
        guard p.count == 2, p[0].count == 2, p[1].count == 2,
              let h = Int(p[0]), let m = Int(p[1]) else { return false }
        return (0...23).contains(h) && (0...59).contains(m)
    }

    /// The day's planned sessions minus the ones the athlete took over: for each of their
    /// sessions that replaces a kind, the first remaining planned session of that kind.
    ///
    /// A workout the athlete adds also takes the day's optional sessions with it: "Optional easy
    /// run" next to the ride they just planned was a second, unwanted thing to do.
    static func remaining(planned: [PlanSession], replacedBy mine: [CustomSession]) -> [PlanSession] {
        var out = planned
        for kind in mine.compactMap(\.replaces) {
            if let i = out.firstIndex(where: { $0.kind == kind && !$0.addedByAthlete }) { out.remove(at: i) }
        }
        if mine.contains(where: { $0.kind != .rest && $0.kind != .flex }) {
            out.removeAll { $0.kind == .flex && !$0.addedByAthlete }
        }
        return out
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
        let s = s.sanitized()
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
