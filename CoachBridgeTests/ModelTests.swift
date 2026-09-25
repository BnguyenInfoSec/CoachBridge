import XCTest
@testable import CoachBridge

final class DayRecordJSONTests: XCTestCase {
    private let pacific = TimeZone(identifier: "America/Los_Angeles")!

    private func record(_ metrics: [MetricKey: Double]) -> DayRecord {
        // 2026-09-22 07:41:10 PDT
        DayRecord(date: "2026-09-22", exportedAt: Date(timeIntervalSince1970: 1_790_088_070), metrics: metrics)
    }

    func testHeaderFieldsAndOffset() throws {
        let json = record([:]).jsonString(timeZone: pacific)
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        XCTAssertEqual(obj["schema"] as? Int, 1)
        XCTAssertEqual(obj["source"] as? String, "coach-bridge")
        XCTAssertEqual(obj["date"] as? String, "2026-09-22")
        XCTAssertEqual(obj["exportedAt"] as? String, "2026-09-22T07:41:10-07:00")
        XCTAssertEqual((obj["metrics"] as? [String: Any])?.count, 0)
    }

    func testMissingMetricsAreOmittedNotZero() throws {
        let json = record([.rhr: 46, .sleep: 7.44]).jsonString(timeZone: pacific)
        XCTAssertTrue(json.contains("\"rhr\": 46"))
        XCTAssertTrue(json.contains("\"sleep\": 7.4"))
        XCTAssertFalse(json.contains("hrv"))
        XCTAssertFalse(json.contains("steps"))
    }

    func testDecimalsPerKey() {
        let json = record([.rhr: 45.6, .stride: 1.049, .weight: 172.46, .spo2: 96.6, .vosc: 8.94])
            .jsonString(timeZone: pacific)
        XCTAssertTrue(json.contains("\"rhr\": 46"))
        XCTAssertTrue(json.contains("\"stride\": 1.05"))
        XCTAssertTrue(json.contains("\"weight\": 172.5"))
        XCTAssertTrue(json.contains("\"spo2\": 97"))
        XCTAssertTrue(json.contains("\"vosc\": 8.9"))
    }

    func testNoNegativeZero() {
        XCTAssertEqual(MetricKey.wristTemp.format(-0.04), "0.0")
        XCTAssertEqual(MetricKey.wristTemp.format(-0.26), "-0.3")
    }

    func testKeysWrittenInContractOrder() {
        let json = record([.stride: 1, .rhr: 50, .steps: 100]).jsonString(timeZone: pacific)
        let r = json.range(of: "rhr")!.lowerBound
        let s = json.range(of: "steps")!.lowerBound
        let st = json.range(of: "stride")!.lowerBound
        XCTAssertTrue(r < s && s < st)
    }

    func testAllKeysProduceValidJSON() throws {
        var all: [MetricKey: Double] = [:]
        for k in MetricKey.allCases { all[k] = 1.234 }
        let data = record(all).jsonData(timeZone: pacific)
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual((obj["metrics"] as? [String: Any])?.count, 18)
    }

    func testNonFiniteValuesAreDropped() {
        let json = record([.hrv: .nan, .rhr: .infinity]).jsonString(timeZone: pacific)
        XCTAssertFalse(json.contains("hrv"))
        XCTAssertFalse(json.contains("rhr"))
    }
}

final class DayWindowsTests: XCTestCase {
    private var cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        return c
    }()

    private func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 0) -> Date {
        cal.date(from: DateComponents(year: y, month: m, day: d, hour: h))!
    }

    func testWindows() {
        let w = DayWindows(for: date(2026, 9, 22, 7), calendar: cal)
        XCTAssertEqual(w.day.start, date(2026, 9, 22))
        XCTAssertEqual(w.day.end, date(2026, 9, 23))
        XCTAssertEqual(w.previousDay.start, date(2026, 9, 21))
        XCTAssertEqual(w.sleep.start, date(2026, 9, 21, 18))
        XCTAssertEqual(w.sleep.end, date(2026, 9, 22, 12))
        XCTAssertEqual(w.last7Days.start, date(2026, 9, 16))
        XCTAssertEqual(w.lastTwoDays.start, date(2026, 9, 21))
    }

    func testSleepWindowAcrossDSTEnd() {
        // DST ends Nov 1 2026 at 2 AM in the US: window is 19 real hours, still 6 PM → noon on the clock.
        let w = DayWindows(for: date(2026, 11, 1, 8), calendar: cal)
        XCTAssertEqual(w.sleep.start, date(2026, 10, 31, 18))
        XCTAssertEqual(w.sleep.end, date(2026, 11, 1, 12))
        XCTAssertEqual(w.sleep.duration, 19 * 3600)
    }

    func testDateKey() {
        XCTAssertEqual(DayRecord.dateKey(for: date(2026, 9, 22, 23), calendar: cal), "2026-09-22")
    }
}

final class SleepMathTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_790_000_000)
    private func at(_ h: Double) -> Date { t0.addingTimeInterval(h * 3600) }
    private var window: DateInterval { DateInterval(start: at(0), end: at(18)) }

    func testWatchPreferredOverPhone() throws {
        let r = try XCTUnwrap(SleepMath.hoursAsleep([
            SleepInterval(start: at(5), end: at(12), isWatch: true),
            SleepInterval(start: at(4), end: at(13), isWatch: false),
        ], window: window))
        XCTAssertEqual(r.hours, 7, accuracy: 0.001)
        XCTAssertTrue(r.usedWatchOnly)
        XCTAssertEqual(r.intervalsIgnored, 1)
    }

    func testOverlapsMergedNotDoubleCounted() throws {
        let r = try XCTUnwrap(SleepMath.hoursAsleep([
            SleepInterval(start: at(5), end: at(7), isWatch: true),
            SleepInterval(start: at(6), end: at(8), isWatch: true),
            SleepInterval(start: at(9), end: at(10), isWatch: true),
        ], window: window))
        XCTAssertEqual(r.hours, 4, accuracy: 0.001)   // 5–8 plus 9–10
    }

    func testClippedToWindow() throws {
        let r = try XCTUnwrap(SleepMath.hoursAsleep([
            SleepInterval(start: at(-2), end: at(1), isWatch: true),
            SleepInterval(start: at(17), end: at(20), isWatch: true),
        ], window: window))
        XCTAssertEqual(r.hours, 2, accuracy: 0.001)
    }

    func testPhoneOnlyStillCounts() throws {
        let r = try XCTUnwrap(SleepMath.hoursAsleep([
            SleepInterval(start: at(5), end: at(11), isWatch: false),
        ], window: window))
        XCTAssertEqual(r.hours, 6, accuracy: 0.001)
        XCTAssertFalse(r.usedWatchOnly)
    }

    func testNothingInWindowIsNil() {
        XCTAssertNil(SleepMath.hoursAsleep([], window: window))
        XCTAssertNil(SleepMath.hoursAsleep([SleepInterval(start: at(20), end: at(22), isWatch: true)], window: window))
    }

    func testStats() {
        XCTAssertEqual(Stats.median([3, 1, 2]), 2)
        XCTAssertEqual(Stats.median([4, 1, 3, 2]), 2.5)
        XCTAssertNil(Stats.median([]))
        XCTAssertEqual(Stats.mean([1, 2, 3]), 2)
        XCTAssertEqual(Stats.celsiusToFahrenheit(36.5), 97.7, accuracy: 0.0001)
    }
}

final class DriveHelpersTests: XCTestCase {
    func testMultipartBody() {
        let body = DriveClient.multipartBody(metadata: Data("{\"name\":\"x\"}".utf8),
                                             media: Data("{\"a\":1}".utf8), boundary: "B")
        let s = String(decoding: body, as: UTF8.self)
        XCTAssertEqual(s, "--B\r\nContent-Type: application/json; charset=UTF-8\r\n\r\n{\"name\":\"x\"}\r\n--B\r\nContent-Type: application/json\r\n\r\n{\"a\":1}\r\n--B--\r\n")
    }

    func testQueryEscaping() {
        XCTAssertEqual(DriveClient.escape("Brandon's"), "Brandon\\'s")
    }
}
