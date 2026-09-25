import Foundation

// The only code the iPhone and Watch apps share: plain values, sent over WatchConnectivity.
// The phone computes everything and the watch displays it, so the watch needs none of the plan
// engine, never reads Health, and never talks to an LLM.

enum WatchLinkKey {
    /// applicationContext: the latest snapshot (only the newest one matters).
    static let snapshot = "snapshot"
    /// transferUserInfo: a feel report, queued until the phone takes it.
    static let feel = "feel"
}

/// Everything the watch shows, as of `generatedAt`.
struct WatchSnapshot: Codable, Equatable, Sendable {
    static let currentVersion = 1
    /// WatchConnectivity's context limit is about 64 KB; stay well under it.
    static let maxBytes = 48_000

    var version = WatchSnapshot.currentVersion
    var generatedAt: Date
    var isDemo: Bool
    var raceName: String?
    var daysToRace: Int?
    var phase: Phase?
    var recovery: Recovery?
    /// Today and the next few days, in order.
    var sessions: [Session]
    /// Recently finished workouts with no feel answer yet.
    var awaitingFeel: [Workout]

    struct Phase: Codable, Equatable, Sendable {
        var id: String
        var name: String
        var week: Int
        var weeks: Int
        var isEasier: Bool
        var focus: String

        var label: String { "\(name) · week \(week) of \(weeks)" }
    }

    struct Recovery: Codable, Equatable, Sendable {
        /// "good", "normal", "caution" or "unknown".
        var level: String
        var headline: String
        var reasons: [String]
    }

    struct Session: Codable, Equatable, Sendable, Identifiable {
        var id: String
        var dateISO: String
        var start: Date?
        var kind: String
        var symbol: String
        var title: String
        var minutes: Int?
        var intensity: String?
        var heartRate: String?
        var power: String?
        var pace: String?
        var fuelDuring: String?
        var isYours: Bool
        /// WorkoutKit's `WorkoutPlan.dataRepresentation`, so Start opens it in the Workout app.
        var workoutPlan: Data?
    }

    struct Workout: Codable, Equatable, Sendable, Identifiable {
        var id: UUID
        var name: String
        var symbol: String
        var start: Date
        var minutes: Int
    }

    // MARK: Wire format

    func encoded() throws -> Data {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        return try enc.encode(self)
    }

    /// Nil for anything unreadable or from a different version, rather than a half-decoded
    /// snapshot on screen: after an update, the next push from the phone replaces it.
    static func decode(_ data: Data) -> WatchSnapshot? {
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        guard let s = try? dec.decode(WatchSnapshot.self, from: data), s.version == currentVersion else { return nil }
        return s
    }

    /// The largest version of this snapshot that fits the transport: Watch workout plans go
    /// first (Start then falls back to the Workout app's own list), then later sessions.
    func fitting(maxBytes: Int = WatchSnapshot.maxBytes) -> WatchSnapshot {
        var s = self
        if (try? s.encoded().count) ?? .max <= maxBytes { return s }
        for i in s.sessions.indices.reversed() where (try? s.encoded().count) ?? .max > maxBytes {
            s.sessions[i].workoutPlan = nil
        }
        while (try? s.encoded().count) ?? .max > maxBytes, s.sessions.count > 1 { s.sessions.removeLast() }
        return s
    }

    /// What a complication may show. Kept apart and minimal: complications render while the
    /// watch is locked, so this is stored with weaker file protection — no health numbers.
    var glance: WatchGlance {
        let next = sessions.first { ($0.start ?? .distantFuture) > generatedAt.addingTimeInterval(-3 * 3600) } ?? sessions.first
        return WatchGlance(generatedAt: generatedAt, isDemo: isDemo, raceName: raceName, daysToRace: daysToRace,
                           phaseLabel: phase?.label, nextTitle: next?.title, nextSymbol: next?.symbol,
                           nextStart: next?.start, nextMinutes: next?.minutes)
    }
}

/// The complication's data. Deliberately free of anything from Health.
struct WatchGlance: Codable, Equatable, Sendable {
    var generatedAt: Date
    var isDemo: Bool
    var raceName: String?
    var daysToRace: Int?
    var phaseLabel: String?
    var nextTitle: String?
    var nextSymbol: String?
    var nextStart: Date?
    var nextMinutes: Int?

    static let placeholder = WatchGlance(generatedAt: .now, isDemo: true, raceName: "Race day", daysToRace: 120,
                                         phaseLabel: "Base 1 · week 3 of 16", nextTitle: "Easy run",
                                         nextSymbol: "figure.run", nextStart: nil, nextMinutes: 45)
}

/// How a workout felt, answered on the watch. The phone treats it as untrusted: it checks every
/// field and only accepts answers for workouts it knows about.
struct WatchFeelReport: Codable, Equatable, Sendable {
    var workoutID: UUID
    /// A `WorkoutFeel.Mood` raw value.
    var mood: String
    var rpe: Int
    var sentAt: Date

    static let rpeRange = 1...10
    static let moods = ["great", "good", "okay", "tough", "awful"]

    func encoded() throws -> Data {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        return try enc.encode(self)
    }

    static func decode(_ data: Data) -> WatchFeelReport? {
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return try? dec.decode(WatchFeelReport.self, from: data)
    }

    /// Accepted only for a known workout, with a known mood and an RPE in range.
    func isValid(knownWorkouts: Set<UUID>) -> Bool {
        knownWorkouts.contains(workoutID) && Self.moods.contains(mood) && Self.rpeRange.contains(rpe)
    }
}
