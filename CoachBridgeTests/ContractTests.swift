import XCTest
import HealthKit
@testable import CoachBridge

/// Guards the data contract in coach-bridge-handoff.md. If one of these fails,
/// the coach page will silently stop seeing a metric.
final class ContractTests: XCTestCase {

    func testMetricKeysMatchContractExactly() {
        let contract = [
            "rhr", "hrv", "sleep", "resp", "wristTemp", "spo2",
            "vo2", "cardioRecovery", "walkHR",
            "weight", "bodyFat",
            "activeCal", "exerciseMin", "steps",
            "runPower", "gct", "vosc", "stride",
        ]
        XCTAssertEqual(MetricKey.allCases.map(\.rawValue), contract)
    }

    func testReadSetIsMetricsPlusWorkoutsPlusDashboardExtras() {
        XCTAssertEqual(HealthTypes.read.count, MetricKey.allCases.count + 1 + HealthTypes.dashboardExtras.count)
        XCTAssertTrue(HealthTypes.read.contains(HKObjectType.workoutType()))
    }

    func testAppNeverRequestsWriteAccess() {
        XCTAssertTrue(HealthTypes.share.isEmpty)
    }

    func testSleepIsTheOnlyCategoryMetric() {
        let categories = MetricKey.allCases.filter { $0.quantityIdentifier == nil }
        XCTAssertEqual(categories, [.sleep])
    }
}
