import HealthKit
import WorkoutKit
import XCTest
@testable import CoachBridge

final class GolfTests: XCTestCase {
    private let day = Date(timeIntervalSince1970: 1_790_000_000)

    func testGolfIsItsOwnSportWhateverTheTitleSays() {
        let s = PlanSession(kind: .golf, title: "Golf, riding the cart")
        XCTAssertEqual(Prescriber.sport(of: s), .other, "\"riding\" must not turn a round into a bike session")
    }

    func testGolfGetsAGolfPrescriptionNotZones() {
        let rx = Prescriber(engine: PlanEngine()).prescription(for: PlanSession(kind: .golf, title: "18 holes"), on: day)
        XCTAssertNil(rx?.heartRate)
        XCTAssertNil(rx?.power)
        XCTAssertTrue(rx?.intensity?.contains("walking 18 holes") == true)
        XCTAssertNotNil(rx?.fuelDuring)
    }

    @MainActor
    func testGolfGoesToTheWatchAsAnOpenGolfWorkout() {
        let s = PlanSession(kind: .golf, title: "18 holes", rx: Prescription(durationMin: 240))
        let mapped = WatchScheduler.mapping(for: s)
        XCTAssertEqual(mapped?.0, .golf)
        XCTAssertEqual(mapped?.1, .outdoor)
        guard case .goal(let w)? = WatchScheduler.workout(for: s, fraction: 0.5) else {
            return XCTFail("expected a single-goal workout")
        }
        XCTAssertEqual(w.activity, .golf)
        XCTAssertEqual(w.goal, .open, "a round has no fixed length")
    }

    func testAthleteCanAddAGolfRound() {
        XCTAssertTrue(SessionFields.kinds.contains(.golf))
        let c = CustomSession(date: "2026-10-03", startTime: "07:30", durationMin: 270, kind: .golf, title: "Torrey Pines South")
        XCTAssertEqual(c.planSession().kind, .golf)
        XCTAssertEqual(c.line(), "2026-10-03 07:30 · golf · Torrey Pines South · 270 min")
    }
}
