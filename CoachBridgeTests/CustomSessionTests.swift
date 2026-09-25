import XCTest
@testable import CoachBridge

final class CustomSessionTests: XCTestCase {
    private var cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        return c
    }()

    private func sample() -> CustomSession {
        CustomSession(date: "2026-09-26", startTime: "06:00", durationMin: 50, kind: .run,
                      title: "Group run with the guys", notes: "3–5 miles, easy, meet at the pier")
    }

    func testConvertsToAFixedPlanSession() {
        let s = sample().planSession()
        XCTAssertTrue(s.addedByAthlete)
        XCTAssertEqual(s.startTime, "06:00")
        XCTAssertEqual(s.rx?.durationMin, 50)
        XCTAssertEqual(s.kind, .run)
        XCTAssertEqual(s.detail, "3–5 miles, easy, meet at the pier")
    }

    func testLineForClaude() {
        XCTAssertEqual(sample().line(),
                       "2026-09-26 06:00 · run · Group run with the guys · 50 min · 3–5 miles, easy, meet at the pier")
    }

    func testRoundTripsThroughJSON() throws {
        let data = try JSONEncoder().encode([sample()])
        let back = try JSONDecoder().decode([CustomSession].self, from: data)
        XCTAssertEqual(back.first?.title, sample().title)
    }

    /// A 6 am session blocks that time, so the plan's own session goes elsewhere that day.
    func testFixedSessionPushesPlanSessionLater() {
        let day = cal.date(from: DateComponents(year: 2026, month: 9, day: 26))!   // Saturday
        let mine = BusyBlock(start: cal.date(bySettingHour: 6, minute: 0, second: 0, of: day)!,
                             end: cal.date(bySettingHour: 6, minute: 50, second: 0, of: day)!,
                             title: "Group run", allDay: false)
        let slots = Scheduler.place(durations: [120], day: day, busy: [mine], calendar: cal)
        XCTAssertEqual(slots.first??.start, cal.date(bySettingHour: 7, minute: 5, second: 0, of: day)!)
    }

    func testPlannedPayloadMarksAthleteSessions() throws {
        let input = PlanAdjuster.DayInput(date: "2026-09-26", day: "Sat",
                                          sessions: [PlanSession(kind: .run, title: "Long run"), sample().planSession()])
        let json = String(decoding: try JSONEncoder().encode(input), as: UTF8.self)
        XCTAssertTrue(json.contains("\"addedByAthlete\":true"))
        XCTAssertTrue(json.contains("\"addedByAthlete\":false"))
        XCTAssertTrue(PlanAdjuster.systemPrompt(engine: PlanEngine()).contains("addedByAthlete"))
    }
}
