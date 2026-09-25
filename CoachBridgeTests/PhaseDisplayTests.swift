import XCTest
@testable import CoachBridge

final class PhaseDisplayTests: XCTestCase {
    private var cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        return c
    }()

    private func engine() -> PlanEngine {
        var p = AthleteProfile.ironmanCalifornia
        p.blockWeeks = ["rec": 1, "b1": 16, "b2": 16, "build": 16, "taper": 3]
        return PlanEngine(profile: p, settings: PlanSettings(), calendar: cal)
    }

    /// Every day of the plan gets a label that agrees with the engine's own phase lookup, and a
    /// week number that never runs past the phase's length.
    func testEveryPlanDayHasAConsistentPhaseWeek() {
        let e = engine()
        var d = e.date(e.startISO)
        let last = e.date(e.raceISO)
        var days = 0
        while d <= last {
            guard let pw = e.phaseWeek(d) else { return XCTFail("no phase week for \(e.iso(d))") }
            XCTAssertEqual(pw.phase, e.phase(for: d), e.iso(d))
            XCTAssertTrue((1...pw.weeks).contains(pw.week), "\(e.iso(d)): week \(pw.week) of \(pw.weeks)")
            d = e.add(d, days: 1)
            days += 1
        }
        XCTAssertGreaterThan(days, 300)
    }

    func testPhaseBoundariesCountFromOne() {
        let e = engine()
        for p in e.phases {
            XCTAssertEqual(e.phaseWeek(e.date(p.start))?.week, 1, "\(p.id) starts at week 1")
            let end = e.phaseWeek(e.date(p.end))
            XCTAssertEqual(end?.week, end?.weeks, "\(p.id) ends on its last week")
        }
        XCTAssertEqual(e.phaseWeek(e.date(e.raceISO))?.phase.id, "taper", "race day is in the taper")
    }

    func testNothingOutsideThePlan() {
        let e = engine()
        XCTAssertNil(e.phaseWeek(e.add(e.date(e.startISO), days: -1)))
        XCTAssertNil(e.phaseWeek(e.add(e.date(e.endISO), days: 1)))
    }

    func testLabelSaysWhenTheWeekEasesOff() {
        let e = engine()
        let b1 = e.phases.first { $0.id == "b1" }!
        var d = e.date(b1.start)
        while !(e.phaseWeek(d)?.isRecovery ?? true) { d = e.add(d, days: 7) }
        let pw = e.phaseWeek(d)!
        XCTAssertTrue(pw.label.hasSuffix("· easier week"), pw.label)
        XCTAssertTrue(pw.label.hasPrefix("Base 1 · week "), pw.label)
    }

    // MARK: Calendar banners

    func testBannersCoverThePlanWithNoGapsOrOverlaps() {
        let e = engine()
        let banners = PhaseBanner.all(e)
        XCTAssertEqual(banners.map(\.id), e.phases.map(\.id))
        XCTAssertEqual(banners.first?.startISO, e.startISO)
        XCTAssertEqual(banners.last?.endISO, e.raceISO)
        for (a, b) in zip(banners, banners.dropFirst()) {
            XCTAssertEqual(e.iso(e.add(e.date(a.endISO), days: 1)), b.startISO, "\(a.id) → \(b.id)")
        }
    }

    func testBannerTitleCountsWeeks() {
        let e = engine()
        let b1 = PhaseBanner.all(e).first { $0.id == "b1" }!
        // 57 weeks to the race, 52 asked for: Base 1 absorbs the other 5.
        XCTAssertEqual(b1.title, "Base 1 · 21 weeks")
    }
}
