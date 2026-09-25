import Foundation
import os
import WatchConnectivity
import WidgetKit

/// The watch's copy of what the phone knows. It never computes a plan, reads Health or talks
/// to an LLM: it shows the latest snapshot and sends back how workouts felt.
@MainActor
final class WatchModel: NSObject, ObservableObject {
    @Published private(set) var snapshot: WatchSnapshot?
    /// Feel answers sent but not yet reflected in a snapshot from the phone, so a workout
    /// doesn't reappear in "How did it feel?" while the answer is in flight.
    @Published private(set) var answered: Set<UUID> = []

    private let session: WCSession? = WCSession.isSupported() ? .default : nil
    private let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "CoachBridgeWatch", category: "watch")

    override init() {
        super.init()
        snapshot = Self.loadSnapshot()
        answered = Self.loadAnswered()
    }

    func activate() {
        guard let session, session.activationState != .activated else { return }
        session.delegate = self
        session.activate()
    }

    var awaitingFeel: [WatchSnapshot.Workout] {
        (snapshot?.awaitingFeel ?? []).filter { !answered.contains($0.id) }
    }

    /// Queued with transferUserInfo, so it reaches the phone even if the phone app isn't running
    /// or the phone is out of range right now.
    func send(_ report: WatchFeelReport) {
        guard let session, let data = try? report.encoded() else { return }
        session.transferUserInfo([WatchLinkKey.feel: data])
        answered.insert(report.workoutID)
        Self.saveAnswered(answered)
    }

    /// The phone's data was deleted: remove everything the watch kept.
    private func wipe() {
        snapshot = nil
        answered = []
        try? FileManager.default.removeItem(at: Self.snapshotURL)
        try? FileManager.default.removeItem(at: Self.answeredURL)
        GlanceStore.clear()
        WidgetCenter.shared.reloadAllTimelines()
    }

    private func handle(_ context: [String: Any]) {
        if context[WatchLinkKey.wipe] as? Bool == true { wipe(); return }
        if let data = context[WatchLinkKey.snapshot] as? Data { receive(data) }
    }

    private func receive(_ data: Data) {
        guard let s = WatchSnapshot.decode(data) else {
            log.info("Ignored a snapshot that didn't decode")
            return
        }
        snapshot = s
        // Anything the phone no longer lists as waiting has been received there.
        answered = answered.intersection(Set(s.awaitingFeel.map(\.id)))
        Self.saveAnswered(answered)
        Self.save(s)
        WidgetCenter.shared.reloadAllTimelines()
    }

    // MARK: Storage

    private static var dir: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    }
    private static var snapshotURL: URL { dir.appendingPathComponent("watch-snapshot.json") }
    private static var answeredURL: URL { dir.appendingPathComponent("watch-answered.json") }

    /// The full snapshot includes recovery reasons with health numbers in them, so it gets the
    /// strongest protection. The complication's glance, written separately, holds none.
    private static func save(_ s: WatchSnapshot) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if let data = try? s.encoded() {
            try? data.write(to: snapshotURL, options: [.atomic, .completeFileProtection])
        }
        GlanceStore.write(s.glance)
    }

    private static func loadSnapshot() -> WatchSnapshot? {
        (try? Data(contentsOf: snapshotURL)).flatMap(WatchSnapshot.decode)
    }

    private static func saveAnswered(_ ids: Set<UUID>) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(Array(ids)) {
            try? data.write(to: answeredURL, options: [.atomic, .completeFileProtection])
        }
    }

    private static func loadAnswered() -> Set<UUID> {
        guard let data = try? Data(contentsOf: answeredURL),
              let ids = try? JSONDecoder().decode([UUID].self, from: data) else { return [] }
        return Set(ids)
    }
}

extension WatchModel: WCSessionDelegate {
    nonisolated func session(_ session: WCSession, activationDidCompleteWith state: WCSessionActivationState, error: Error?) {
        // A context that arrived while the app wasn't running is waiting here.
        let context = session.receivedApplicationContext
        let wipe = context[WatchLinkKey.wipe] as? Bool == true
        let data = context[WatchLinkKey.snapshot] as? Data
        Task { @MainActor in self.handle(wipe ? [WatchLinkKey.wipe: true] : data.map { [WatchLinkKey.snapshot: $0] } ?? [:]) }
    }

    nonisolated func session(_ session: WCSession, didReceiveApplicationContext context: [String: Any]) {
        let wipe = context[WatchLinkKey.wipe] as? Bool == true
        let data = context[WatchLinkKey.snapshot] as? Data
        Task { @MainActor in self.handle(wipe ? [WatchLinkKey.wipe: true] : data.map { [WatchLinkKey.snapshot: $0] } ?? [:]) }
    }
}
