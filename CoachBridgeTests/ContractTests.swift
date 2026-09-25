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

    /// The file name is the contract's key. dateKey stopped using a DateFormatter for speed;
    /// it must produce exactly what the formatter did — every 7 hours across ~12 years, in
    /// zones either side of UTC and one with a half-hour offset, and through a
    /// non-Gregorian calendar.
    func testDateKeyMatchesTheFormatterItReplaced() {
        let zones = ["America/Los_Angeles", "UTC", "Pacific/Kiritimati", "Asia/Kolkata", "America/St_Johns"]
        var calendars: [Calendar] = zones.map {
            var c = Calendar(identifier: .gregorian)
            c.timeZone = TimeZone(identifier: $0)!
            return c
        }
        var buddhist = Calendar(identifier: .buddhist)
        buddhist.timeZone = TimeZone(identifier: "Asia/Bangkok")!
        calendars.append(buddhist)

        for cal in calendars {
            let f = DateFormatter()
            f.calendar = Calendar(identifier: .gregorian)
            f.locale = Locale(identifier: "en_US_POSIX")
            f.timeZone = cal.timeZone
            f.dateFormat = "yyyy-MM-dd"
            var d = Date(timeIntervalSince1970: 1_700_000_000 - 86_400 * 365 * 4)
            let end = d.addingTimeInterval(86_400 * 365 * 12)
            var mismatches = 0
            while d < end {
                if DayRecord.dateKey(for: d, calendar: cal) != f.string(from: d) { mismatches += 1 }
                d.addTimeInterval(7 * 3_600)
            }
            XCTAssertEqual(mismatches, 0, "\(cal.identifier) \(cal.timeZone.identifier)")
        }
    }
}
