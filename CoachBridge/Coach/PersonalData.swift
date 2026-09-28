import Foundation
import os

/// "Export my data" and "Delete my data". Your data is yours: you can take all of it with you
/// in an open format, or remove every trace of it from this phone.
///
/// Health data itself isn't Coach Bridge's to export or delete — it lives in Apple Health,
/// which has its own export — and the files already in your Google Drive are yours to manage
/// there. Both screens say so.
@MainActor
enum PersonalData {
    private static let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "CoachBridge", category: "data")

    static var supportDir: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    }

    // MARK: Export

    /// Everything the app stored, as one JSON document: every file it wrote and every setting.
    /// Venue photos are listed, not embedded (they can be large); API keys and sign-in tokens
    /// are never included. Written to a temporary file with complete protection, for the share
    /// sheet; the caller deletes it afterwards.
    static func export(now: Date = .now) throws -> URL {
        removeLeftoverExports()
        var files: [String: Any] = [:]
        var photos: [String] = []
        let fm = FileManager.default
        if let walker = fm.enumerator(at: supportDir, includingPropertiesForKeys: [.isRegularFileKey]) {
            for case let url as URL in walker where (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
                let name = url.path.replacingOccurrences(of: supportDir.path + "/", with: "")
                if url.pathExtension.lowercased() == "json",
                   let data = try? Data(contentsOf: url),
                   let object = try? JSONSerialization.jsonObject(with: data) {
                    files[name] = object
                } else {
                    photos.append(name)
                }
            }
        }
        let settings = (Bundle.main.bundleIdentifier.flatMap { UserDefaults.standard.persistentDomain(forName: $0) } ?? [:])
            .compactMapValues(jsonSafe)

        let document: [String: Any] = [
            "format": "coach-bridge-export",
            "version": 1,
            "exportedAt": ISO8601DateFormatter().string(from: now),
            "appVersion": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "",
            "note": "Everything Coach Bridge stored on this iPhone. Health data stays in Apple Health (export it from the Health app). API keys and sign-in tokens are never exported.",
            "files": files,
            "settings": settings,
            "photosNotIncluded": photos.sorted(),
        ]
        let data = try JSONSerialization.data(withJSONObject: document, options: [.prettyPrinted, .sortedKeys])
        let day = ISO8601DateFormatter.string(from: now, timeZone: .current, formatOptions: [.withFullDate])
        let url = fm.temporaryDirectory.appendingPathComponent("coach-bridge-export-\(day).json")
        try data.write(to: url, options: [.atomic, .completeFileProtection])
        log.info("Exported \(files.count, privacy: .public) files, \(settings.count, privacy: .public) settings")
        return url
    }

    /// An export left behind if the app was closed with the share sheet open.
    static func removeLeftoverExports() {
        let fm = FileManager.default
        for url in (try? fm.contentsOfDirectory(at: fm.temporaryDirectory, includingPropertiesForKeys: nil)) ?? []
        where url.lastPathComponent.hasPrefix("coach-bridge-export-") {
            try? fm.removeItem(at: url)
        }
    }

    /// Settings as JSON values: dates as ISO strings, stored JSON decoded in place, other data
    /// as base64 so nothing is silently dropped.
    private static func jsonSafe(_ v: Any) -> Any? {
        switch v {
        case let d as Date: return ISO8601DateFormatter().string(from: d)
        case let d as Data: return (try? JSONSerialization.jsonObject(with: d)) ?? d.base64EncodedString()
        case let a as [Any]: return a.compactMap(jsonSafe)
        case let m as [String: Any]: return m.compactMapValues(jsonSafe)
        case is String, is NSNumber: return v
        default: return String(describing: v)
        }
    }

    // MARK: Delete

    /// Removes everything Coach Bridge put on this phone and in your accounts, except what's
    /// yours to manage elsewhere (Apple Health, files already in Drive).
    static func deleteEverything(removeTrainingCalendar: Bool) async {
        let s = AppServices.shared

        // Things outside the app's own files first, while the settings that find them exist.
        await s.watch.removeAll()                                      // scheduled Watch workouts
        if removeTrainingCalendar { s.calendar.removeTrainingCalendar() }
        await s.google.signOut()                                       // revokes Drive access, not just local tokens
        for account in [LLMProvider.anthropic, .openai, .hosted].map(\.keychainAccount) {
            Keychain.delete(account: account)
        }
        s.watchLink.wipeWatch()
        PhoneGlancePublisher.clear()                                   // the widget's copy
        await LiveSession.shared.endAllNow()                           // nothing left on the Lock Screen

        // Then the app's own files and settings.
        let fm = FileManager.default
        for url in (try? fm.contentsOfDirectory(at: supportDir, includingPropertiesForKeys: nil)) ?? [] {
            try? fm.removeItem(at: url)
        }
        for url in (try? fm.contentsOfDirectory(at: fm.temporaryDirectory, includingPropertiesForKeys: nil)) ?? [] {
            try? fm.removeItem(at: url)
        }
        if let id = Bundle.main.bundleIdentifier { UserDefaults.standard.removePersistentDomain(forName: id) }
        log.info("Deleted all app data")
    }
}
