import XCTest
@testable import CoachBridge

final class SchedulerTests: XCTestCase {
    private var cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        return c
    }()
    private func at(_ d: Int, _ h: Int, _ m: Int = 0) -> Date {
        cal.date(from: DateComponents(year: 2026, month: 9, day: d, hour: h, minute: m))!
    }

    func testWeekdayGoesAfterWork() {
        // Tue Sep 22: work 9–4
        let busy = [BusyBlock(start: at(22, 9), end: at(22, 16), title: "Work", allDay: false)]
        let s = Scheduler.place(durations: [45], day: at(22, 0), busy: busy, calendar: cal)
        XCTAssertEqual(s.first??.start, at(22, 16, 30))
    }

    func testRunThenLiftStayTogetherAndSkipClass() {
        // Thu: class 6–8 pm blocks the evening block of 25 + 10 + 60 = 95 min → morning.
        let busy = [BusyBlock(start: at(24, 9), end: at(24, 16), title: "Work", allDay: false),
                    BusyBlock(start: at(24, 18), end: at(24, 20), title: "Class", allDay: false)]
        let s = Scheduler.place(durations: [25, 60], day: at(24, 0), busy: busy, calendar: cal)
        XCTAssertEqual(s[0]?.start, at(24, 5, 30))
        XCTAssertEqual(s[1]?.start, at(24, 6, 5))      // 25 min + 10 min transition
    }

    func testPushesPastAMeetingWithBuffer() {
        let busy = [BusyBlock(start: at(22, 16, 30), end: at(22, 17, 10), title: "Call", allDay: false)]
        let s = Scheduler.place(durations: [60], day: at(22, 0), busy: busy, calendar: cal)
        XCTAssertEqual(s.first??.start, at(22, 17, 25))   // 17:10 + 15 min buffer
    }

    func testHotAfternoonPrefersMorning() {
        let s = Scheduler.place(durations: [45], day: at(22, 0), busy: [], calendar: cal, hot: true)
        XCTAssertEqual(s.first??.start, at(22, 5, 30))
    }

    func testWeekendMorningAndLongRideFits() {
        let s = Scheduler.place(durations: [180, 20], day: at(26, 0), busy: [], calendar: cal)   // Saturday
        XCTAssertEqual(s[0]?.start, at(26, 7))
        XCTAssertEqual(s[1]?.start, at(26, 10, 10))
    }

    func testPreferredStartUsedWhenFree() {
        let s = Scheduler.place(durations: [30], preferredStart: at(22, 6), day: at(22, 0), busy: [], calendar: cal)
        XCTAssertEqual(s.first??.start, at(22, 6))
    }

    func testNoRoomReturnsNil() {
        let busy = [BusyBlock(start: at(22, 5), end: at(22, 21), title: "Travel", allDay: false)]
        XCTAssertNil(Scheduler.place(durations: [45], day: at(22, 0), busy: busy, calendar: cal).first!)
    }

    func testAllDayEventsDontBlockButAreDescribed() {
        let busy = [BusyBlock(start: at(22, 0), end: at(23, 0), title: "Flight to SFO", allDay: true)]
        XCTAssertNotNil(Scheduler.place(durations: [45], day: at(22, 0), busy: busy, calendar: cal).first!)
        let text = Scheduler.describe(busy + [BusyBlock(start: at(22, 9), end: at(22, 16), title: "Work", allDay: false)],
                                      days: [at(22, 0), at(23, 0)], calendar: cal)
        XCTAssertEqual(text, "Tue 2026-09-22: all day: Flight to SFO; 09:00–16:00 Work\nWed 2026-09-23: free")
    }

    func testTimeParsing() {
        XCTAssertEqual(Scheduler.time("06:15", on: at(22, 0), calendar: cal), at(22, 6, 15))
        XCTAssertNil(Scheduler.time("25:00", on: at(22, 0), calendar: cal))
        XCTAssertNil(Scheduler.time("soon", on: at(22, 0), calendar: cal))
    }
}

@MainActor
final class CalendarMarkerTests: XCTestCase {
    func testMarkerRoundTrip() {
        let url = CalendarSync.marker("2026-09-22#1")
        XCTAssertEqual(url.absoluteString, "coachbridge://session/2026-09-22/1")
        XCTAssertEqual(CalendarSync.key(from: url), "2026-09-22#1")
        XCTAssertNil(CalendarSync.key(from: URL(string: "https://example.com")))
    }

    func testTitleAndNotes() {
        var s = PlanSession(kind: .run, title: "Easy run", detail: "30 min")
        s.rx = Prescription(durationMin: 30, heartRate: "145–151 bpm", fuelDuring: "Water.")
        XCTAssertEqual(CalendarSync.title(for: s, placed: true), "Run: Easy run (30 min)")
        XCTAssertTrue(CalendarSync.title(for: s, placed: false).contains("no free slot"))
        let notes = CalendarSync.notes(for: s)
        XCTAssertTrue(notes.contains("Heart rate: 145–151 bpm"))
        XCTAssertTrue(notes.contains("During: Water."))
    }
}

final class WeatherPrivacyTests: XCTestCase {
    /// Only the rounded location goes to Apple Weather — typed-in coordinates included, which
    /// used to reach the old provider rounded but would otherwise reach WeatherKit exact.
    func testCoordinatesAreRoundedToAboutAKilometre() {
        XCTAssertEqual(WeatherPrivacy.rounded(32.62871), 32.63, accuracy: 1e-9)
        XCTAssertEqual(WeatherPrivacy.rounded(-117.09912), -117.10, accuracy: 1e-9)
        XCTAssertEqual(WeatherPrivacy.rounded(0.004), 0, accuracy: 1e-9)
    }

    func testAPermissionErrorReadsAsASetupProblem() {
        struct Offline: Error {}
        XCTAssertFalse(AppleWeather.isSetupProblem(Offline()))
    }
}
