import Foundation

/// What the iPhone widget shows: today's session and a go / no-go word. Written by the app into
/// the App Group, read by the widget extension.
///
/// Like the Watch's complication data, it carries no health numbers: widgets draw on the Lock
/// Screen, so it's stored with protection only until first unlock and must be safe to glance at.
struct PhoneGlance: Codable, Equatable, Sendable {
    struct Session: Codable, Equatable, Sendable {
        var title: String
        var symbol: String
        var kind: String
        var start: Date?
        var minutes: Int?
        /// The intensity line, trimmed to fit a widget.
        var intensity: String?
    }

    var generatedAt: Date
    var dayISO: String
    var isDemo: Bool
    /// `GoNoGo` raw value.
    var verdict: String
    var sessions: [Session]
    var phaseLabel: String?

    var goNoGo: GoNoGo { GoNoGo(rawValue: verdict) ?? .byFeel }

    static let placeholder = PhoneGlance(generatedAt: .now, dayISO: "", isDemo: true, verdict: GoNoGo.go.rawValue,
                                         sessions: [Session(title: "Endurance ride", symbol: "figure.outdoor.cycle",
                                                            kind: "bike", start: nil, minutes: 90, intensity: "Zone 2")],
                                         phaseLabel: "Base 1 · week 3 of 16")
}

enum PhoneGlanceStore {
    static let widgetKind = "today"

    private static var url: URL? {
        (Bundle.main.object(forInfoDictionaryKey: "CBAppGroup") as? String)
            .flatMap { FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: $0) }?
            .appendingPathComponent("phone-glance.json")
    }

    static func write(_ g: PhoneGlance) {
        guard let url else { return }
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        if let data = try? enc.encode(g) {
            try? data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        }
    }

    static func read() -> PhoneGlance? {
        guard let url, let data = try? Data(contentsOf: url) else { return nil }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return try? dec.decode(PhoneGlance.self, from: data)
    }

    static func clear() {
        if let url { try? FileManager.default.removeItem(at: url) }
    }
}
