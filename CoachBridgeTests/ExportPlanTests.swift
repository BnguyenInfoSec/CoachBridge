import XCTest
@testable import CoachBridge

final class ExportPlanTests: XCTestCase {
    private var cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        return c
    }()

    private func date(_ m: Int, _ d: Int, _ h: Int = 0, _ min: Int = 0) -> Date {
        cal.date(from: DateComponents(year: 2026, month: m, day: d, hour: h, minute: min))!
    }
    private func keys(_ days: [Date]) -> [String] { days.map { DayRecord.dateKey(for: $0, calendar: cal) } }

    func testTodayAndYesterdayAlwaysIncluded() {
        let existing: Set = ["2026-09-22.json", "2026-09-21.json"]
        let days = ExportPlan.days(today: date(9, 22, 7), existingFileNames: existing,
                                   lookbackDays: 3, backfillLimit: 0, calendar: cal)
        XCTAssertEqual(keys(days), ["2026-09-22", "2026-09-21"])
    }

    func testBackfillsOnlyMissingNewestFirst() {
        let existing: Set = ["2026-09-20.json", "2026-09-18.json"]
        let days = ExportPlan.days(today: date(9, 22, 7), existingFileNames: existing,
                                   lookbackDays: 6, backfillLimit: 10, calendar: cal)
        XCTAssertEqual(keys(days), ["2026-09-22", "2026-09-21", "2026-09-19", "2026-09-17"])
    }

    func testBackfillLimit() {
        let days = ExportPlan.days(today: date(9, 22, 7), existingFileNames: [],
                                   lookbackDays: 60, backfillLimit: 7, calendar: cal)
        XCTAssertEqual(days.count, 9)
        XCTAssertEqual(keys(days).last, "2026-09-14")
    }

    func testFullLookbackIs60Days() {
        let days = ExportPlan.days(today: date(9, 22, 7), existingFileNames: [],
                                   backfillLimit: 1000, calendar: cal)
        XCTAssertEqual(days.count, 60)
        XCTAssertEqual(keys(days).last, "2026-07-25")
    }

    func testNextMorning() {
        XCTAssertEqual(ExportPlan.nextMorning(after: date(9, 22, 5), calendar: cal), date(9, 22, 6, 30))
        XCTAssertEqual(ExportPlan.nextMorning(after: date(9, 22, 6, 30), calendar: cal), date(9, 23, 6, 30))
        XCTAssertEqual(ExportPlan.nextMorning(after: date(9, 22, 21), calendar: cal), date(9, 23, 6, 30))
    }

    func testSummary() {
        XCTAssertEqual(Exporter.summary(created: 3, updated: 2, empty: 0, trigger: .appOpen),
                       "3 new, 2 updated · app open")
        XCTAssertEqual(Exporter.summary(created: 0, updated: 0, empty: 1, trigger: .backgroundRefresh),
                       "nothing new · daily refresh · 1 day without data")
    }
}
