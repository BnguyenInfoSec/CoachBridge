import HealthKit
import os

/// M0 smoke tests for HealthKit: availability, the permission sheet, and the
/// background-delivery entitlement. Logs status only — never metric values.
@MainActor
final class HealthAuthorizer: ObservableObject {
    enum CheckState: Equatable {
        case notRun, running, passed(String), failed(String)
    }

    @Published private(set) var authorization: CheckState = .notRun
    @Published private(set) var backgroundDelivery: CheckState = .notRun

    let store = HKHealthStore()
    private let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "CoachBridge", category: "health")

    var isAvailable: Bool { HKHealthStore.isHealthDataAvailable() }

    /// Shows the Health permission sheet (first time only). HealthKit never reveals
    /// whether READ access was granted — M1 confirms access by actually reading data.
    func requestAuthorization() async {
        guard isAvailable else {
            authorization = .failed("Health data isn't available on this device.")
            return
        }
        authorization = .running
        do {
            try await store.requestAuthorization(toShare: HealthTypes.share, read: HealthTypes.read)
            log.info("Authorization request completed for \(HealthTypes.read.count, privacy: .public) read types")
            authorization = .passed("Permission sheet completed for \(HealthTypes.read.count) read types.")
        } catch {
            log.error("Authorization request failed: \(error.localizedDescription, privacy: .public)")
            authorization = .failed(error.localizedDescription)
        }
    }

    /// Proves the background-delivery entitlement is in the signed build by enabling it for
    /// resting HR. Idempotent, and M3 wants it on anyway, so it's never turned back off here.
    func checkBackgroundDeliveryEntitlement() async {
        backgroundDelivery = .running
        let type = HKQuantityType(.restingHeartRate)
        do {
            try await store.enableBackgroundDelivery(for: type, frequency: .daily)
            log.info("Background delivery entitlement check passed")
            backgroundDelivery = .passed("Entitlement present; daily delivery enabled.")
        } catch {
            log.error("Background delivery check failed: \(error.localizedDescription, privacy: .public)")
            backgroundDelivery = .failed(error.localizedDescription)
        }
    }
}
