import UIKit
import os

/// Uploads DayRecords to Drive at /Coach/health/<date>.json — one day on tap (M2),
/// or automatically with backfill (M3). All health values stay in memory; only
/// timestamps and counts are persisted (UserDefaults) for the status line.
@MainActor
final class Exporter: ObservableObject {
    static let folderPath = ["Coach", "health"]

    enum Trigger: String {
        case appOpen = "app open"
        case healthUpdate = "Health update"
        case backgroundRefresh = "daily refresh"
        case manual = "Sync now"
    }

    struct Result: Equatable {
        let fileName: String
        let outcome: DriveClient.UploadOutcome
        let at: Date
    }

    @Published private(set) var isExporting = false
    @Published private(set) var lastResult: Result?
    @Published private(set) var lastError: String?
    @Published private(set) var lastAutoSuccess: Date?
    @Published private(set) var lastAutoSummary: String?

    private let source: any HealthSource
    private let auth: GoogleAuth
    private let drive: DriveClient
    private let defaults = UserDefaults.standard
    private let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "CoachBridge", category: "export")

    /// Background-triggered runs closer together than this are skipped (observers fire in bursts).
    private let throttle: TimeInterval = 10 * 60
    private var lastAutoAttempt: Date?

    private enum Key {
        static let lastAutoSuccess = "export.lastAutoSuccess"
        static let lastAutoSummary = "export.lastAutoSummary"
    }

    init(source: any HealthSource, auth: GoogleAuth) {
        self.source = source
        self.auth = auth
        drive = DriveClient(token: { [weak auth] in
            guard let auth else { throw GoogleAuth.AuthError.notSignedIn }
            return try await auth.accessToken()
        })
        lastAutoSuccess = defaults.object(forKey: Key.lastAutoSuccess) as? Date
        lastAutoSummary = defaults.string(forKey: Key.lastAutoSummary)
    }

    // MARK: - M2: one day, on tap

    func export(_ record: DayRecord) async {
        guard !isExporting else { return }
        guard await ConsentGate.shared.require(.drive) else {
            lastError = "Nothing was sent. Allow Drive export in Settings → Data sharing to save your summaries."
            return
        }
        isExporting = true
        lastError = nil
        defer { isExporting = false }
        do {
            let outcome = try await drive.upsertJSON(named: record.fileName,
                                                     data: record.jsonData(),
                                                     folderPath: Self.folderPath)
            lastResult = Result(fileName: record.fileName, outcome: outcome, at: .now)
            log.info("Manual export ok: \(record.metrics.count, privacy: .public) metrics")
        } catch {
            lastError = error.localizedDescription
            log.error("Manual export failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - M3: automatic

    /// Exports today + yesterday and backfills missing days (last 60).
    /// Returns true if the run completed (including "nothing to do"), false if it couldn't run.
    @discardableResult
    func runAutomatic(trigger: Trigger) async -> Bool {
        if isExporting {
            log.info("Auto run (\(trigger.rawValue, privacy: .public)) skipped: already running")
            return true
        }
        if trigger == .healthUpdate || trigger == .backgroundRefresh, let last = lastAutoAttempt, Date.now.timeIntervalSince(last) < throttle {
            log.info("Auto run (\(trigger.rawValue, privacy: .public)) skipped: throttled")
            return true
        }
        // Health data is encrypted while the phone is locked. Wait for the next trigger after unlock.
        guard UIApplication.shared.isProtectedDataAvailable else {
            log.info("Auto run (\(trigger.rawValue, privacy: .public)) skipped: device locked")
            return false
        }

        isExporting = true
        lastAutoAttempt = .now
        defer { isExporting = false }

        if !auth.isSignedIn { await auth.restore() }
        guard auth.isSignedIn, auth.hasDriveScope else {
            log.info("Auto run skipped: not signed in to Google")
            return false
        }
        // Automatic runs never ask; they wait until the athlete has said yes on screen.
        let allowed = trigger == .manual ? await ConsentGate.shared.require(.drive) : ConsentGate.isGranted(.drive)
        guard allowed else {
            log.info("Auto run skipped: no consent for Drive")
            lastError = "Drive export is paused until you allow it in Settings → Data sharing."
            return false
        }

        // Background launches get ~30 s, so backfill a week at a time; with the app on screen, do all 60 days.
        let foreground = UIApplication.shared.applicationState != .background
        let backfillLimit = foreground ? 60 : 7

        do {
            let folderID = try await drive.ensureFolderPath(Self.folderPath)
            let existing = try await drive.listFiles(inFolder: folderID)
            let days = ExportPlan.days(today: .now, existingFileNames: Set(existing.keys), backfillLimit: backfillLimit)

            var created = 0, updated = 0, empty = 0
            for day in days {
                try Task.checkCancellation()
                let record = await source.day(day).record
                // A file with no metrics tells the coach nothing; skip it (it'll be retried next run).
                guard !record.metrics.isEmpty else { empty += 1; continue }
                let outcome = try await drive.upsertJSON(named: record.fileName, data: record.jsonData(),
                                                         folderID: folderID, existingID: existing[record.fileName])
                if outcome == .created { created += 1 } else { updated += 1 }
            }

            let summary = Self.summary(created: created, updated: updated, empty: empty, trigger: trigger)
            lastAutoSuccess = .now
            lastAutoSummary = summary
            lastError = nil
            defaults.set(lastAutoSuccess, forKey: Key.lastAutoSuccess)
            defaults.set(summary, forKey: Key.lastAutoSummary)
            log.info("Auto run ok (\(trigger.rawValue, privacy: .public)): \(created, privacy: .public) created, \(updated, privacy: .public) updated, \(empty, privacy: .public) empty")
            return true
        } catch is CancellationError {
            log.info("Auto run cancelled (background time expired)")
            return false
        } catch {
            lastError = error.localizedDescription
            log.error("Auto run failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    nonisolated static func summary(created: Int, updated: Int, empty: Int, trigger: Trigger) -> String {
        var parts: [String] = []
        if created > 0 { parts.append("\(created) new") }
        if updated > 0 { parts.append("\(updated) updated") }
        if parts.isEmpty { parts.append("nothing new") }
        var s = parts.joined(separator: ", ") + " · \(trigger.rawValue)"
        if empty > 0 { s += " · \(empty) day\(empty == 1 ? "" : "s") without data" }
        return s
    }
}
