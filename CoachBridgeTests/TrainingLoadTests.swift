import XCTest
@testable import CoachBridge

final class TrainingLoadTests: XCTestCase {
    private var cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        return c
    }()
    private let day0 = Date(timeIntervalSince1970: 1_780_000_000)

    private func w(_ day: Int, hours: Double, hr: Double?) -> WorkoutSummary {
        WorkoutSummary(id: UUID(), sport: .bike, name: "Ride", start: cal.date(byAdding: .day, value: day, to: day0)!,
                       duration: hours * 3600, distanceMeters: nil, avgHR: hr)
    }

    func testAnHourAtThresholdIsAHundred() {
        let (s, m) = TrainingLoad.stress(w(0, hours: 1, hr: 160), lthr: 160)
        XCTAssertEqual(s, 100, accuracy: 0.001)
        XCTAssertEqual(m, .heartRateWithThreshold)
    }

    func testEasyHourScoresFarLess() {
        XCTAssertEqual(TrainingLoad.stress(w(0, hours: 1, hr: 120), lthr: 160).0, 56.25, accuracy: 0.01)
    }

    func testFallbacksSayHowTheyWereComputed() {
        XCTAssertEqual(TrainingLoad.stress(w(0, hours: 2, hr: nil), lthr: 160).0, 100)
        XCTAssertEqual(TrainingLoad.stress(w(0, hours: 2, hr: nil), lthr: 160).1, .durationOnly)
        XCTAssertEqual(TrainingLoad.stress(w(0, hours: 1, hr: 150), lthr: nil).1, .heartRateEstimatedThreshold)
    }

    func testRunawayWorkoutsAndBadSensorsAreContained() {
        XCTAssertEqual(TrainingLoad.stress(w(0, hours: 900, hr: 90), lthr: 160).0, 0, "a watch left running adds nothing")
        XCTAssertLessThanOrEqual(TrainingLoad.stress(w(0, hours: 1, hr: 400), lthr: 160).0, 144.01, "intensity is capped at 1.2")
    }

    /// Train 100 a day for long enough and fitness and fatigue both converge on 100, and form
    /// on zero. Stop, and fatigue falls faster than fitness, so form turns positive.
    func testConvergesAndRecovers() {
        let ride = (0..<200).map { w($0, hours: 1, hr: 160) }
        let end = cal.date(byAdding: .day, value: 199, to: day0)!
        let trained = TrainingLoad.summary(ride, lthr: 160, from: end, to: end, calendar: cal).today!
        XCTAssertEqual(trained.fitness, 100, accuracy: 1)
        XCTAssertEqual(trained.fatigue, 100, accuracy: 0.01)
        XCTAssertEqual(trained.form, 0, accuracy: 1)

        let rested = cal.date(byAdding: .day, value: 10, to: end)!
        let after = TrainingLoad.summary(ride, lthr: 160, from: rested, to: rested, calendar: cal).today!
        XCTAssertLessThan(after.fatigue, after.fitness)
        XCTAssertGreaterThan(after.form, 10)
    }

    func testFormIsYesterdaysBalanceNotTodays() {
        let s = TrainingLoad.summary([w(0, hours: 3, hr: 160)], lthr: 160, from: day0,
                                     to: cal.date(byAdding: .day, value: 1, to: day0)!, calendar: cal)
        XCTAssertEqual(s.points[0].form, 0, "today's session doesn't change how fresh you came into it")
        XCTAssertLessThan(s.points[1].form, 0)
    }

    func testEveryDayIsPresentIncludingRestDays() {
        let to = cal.date(byAdding: .day, value: 13, to: day0)!
        let s = TrainingLoad.summary([w(0, hours: 1, hr: 150), w(10, hours: 1, hr: 150)], lthr: 160,
                                     from: day0, to: to, calendar: cal)
        XCTAssertEqual(s.points.count, 14)
        XCTAssertEqual(s.points.filter { $0.stress > 0 }.count, 2)
    }

    func testTheWeakestMethodIsReported() {
        let s = TrainingLoad.summary([w(0, hours: 1, hr: 150), w(1, hours: 1, hr: nil)], lthr: 160,
                                     from: day0, to: day0, calendar: cal)
        XCTAssertEqual(s.method, .durationOnly)
    }

    func testTheCoachSeesLoadWithItsMethod() {
        var d = DemoData.dashboard(now: day0)
        d.load = TrainingLoad.summary((0..<60).map { w($0 - 60, hours: 1, hr: 150) }, lthr: 160,
                                      from: day0, to: day0, calendar: cal)
        let text = CoachContext.healthSummary(d)
        XCTAssertTrue(text.contains("fitness (CTL)"))
        XCTAssertTrue(text.contains("from heart rate against your threshold"))
    }
}
