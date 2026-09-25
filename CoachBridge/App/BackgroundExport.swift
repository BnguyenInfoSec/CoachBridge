import BackgroundTasks
import HealthKit
import os

/// M3 wiring: HealthKit observer queries with daily background delivery, plus a
/// BGAppRefreshTask as backup. Both must be set up during app launch, including
/// background launches, which is why this is called from the app delegate.
@MainActor
enum BackgroundExport {
    static var taskID: String { (Bundle.main.bundleIdentifier ?? "CoachBridge") + ".daily-export" }

    private static let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "CoachBridge", category: "background")
    private static var observersStarted = false

    // MARK: BGAppRefreshTask

    static func registerRefreshTask() {
        let ok = BGTaskScheduler.shared.register(forTaskWithIdentifier: taskID, using: nil) { @Sendable task in
            guard let task = task as? BGAppRefreshTask else { task.setTaskCompleted(success: false); return }
            Task { @MainActor in handle(task) }
        }
        log.info("Refresh task registered: \(ok, privacy: .public)")
    }

    static func scheduleRefresh() {
        let request = BGAppRefreshTaskRequest(identifier: taskID)
        request.earliestBeginDate = ExportPlan.nextMorning(after: .now)
        do {
            try BGTaskScheduler.shared.submit(request)
            log.info("Refresh scheduled")
        } catch {
            // Always fails in the simulator; on device usually means Background App Refresh is off.
            log.error("Refresh schedule failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private static func handle(_ task: BGAppRefreshTask) {
        scheduleRefresh()   // chain the next one first, in case this run is cut short
        let work = Task { @MainActor in
            let ok = await AppServices.shared.exporter.runAutomatic(trigger: .backgroundRefresh)
            task.setTaskCompleted(success: ok)
        }
        task.expirationHandler = { work.cancel() }
    }

    // MARK: HealthKit observers

    /// Long-running observer queries on RHR, HRV and sleep. HealthKit launches the app in the
    /// background (at most daily) when new samples land, and also fires each query once at start.
    static func startObservers(store: HKHealthStore) {
        guard HKHealthStore.isHealthDataAvailable(), !observersStarted else { return }
        observersStarted = true

        for type in HealthTypes.backgroundDelivery {
            let query = HKObserverQuery(sampleType: type, predicate: nil) { @Sendable _, completionHandler, error in
                if let error {
                    Task { @MainActor in log.error("Observer error: \(error.localizedDescription, privacy: .public)") }
                    completionHandler()
                    return
                }
                Task { @MainActor in
                    await AppServices.shared.exporter.runAutomatic(trigger: .healthUpdate)
                    completionHandler()   // tell HealthKit we're done so it keeps delivering
                }
            }
            store.execute(query)
            store.enableBackgroundDelivery(for: type, frequency: .daily) { @Sendable ok, error in
                if let error {
                    Task { @MainActor in log.error("Background delivery failed: \(error.localizedDescription, privacy: .public)") }
                } else {
                    Task { @MainActor in log.info("Background delivery enabled: \(ok, privacy: .public)") }
                }
            }
        }
    }
}
