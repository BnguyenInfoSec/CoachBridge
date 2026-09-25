import Foundation

/// The complication's copy, in the App Group so the widget extension can read it. Protected
/// only until first unlock, because complications draw while the watch is locked — which is
/// why `WatchGlance` carries no health data.
enum GlanceStore {
    static var groupID: String? { Bundle.main.object(forInfoDictionaryKey: "CBAppGroup") as? String }

    private static var url: URL? {
        groupID.flatMap { FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: $0) }?
            .appendingPathComponent("glance.json")
    }

    static func write(_ g: WatchGlance) {
        guard let url else { return }
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        if let data = try? enc.encode(g) {
            try? data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        }
    }

    static func read() -> WatchGlance? {
        guard let url, let data = try? Data(contentsOf: url) else { return nil }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return try? dec.decode(WatchGlance.self, from: data)
    }
}
