import XCTest
@testable import CoachBridge

final class WorkoutShapeTests: XCTestCase {
    func testRangeParsing() {
        XCTAssertEqual(WorkoutShaper.range(in: "138–151 bpm (Z2)", unit: "bpm"), 138...151)
        XCTAssertEqual(WorkoutShaper.range(in: "176-186 W intervals", unit: "W"), 176...186)
        XCTAssertNil(WorkoutShaper.range(in: "Easy: nose-breathing", unit: "bpm"))
        XCTAssertNil(WorkoutShaper.range(in: nil, unit: "W"))
    }

    func testIntervalProgression() {
        let d = "60 min: 3×12 → 2×20 @ 88–93% FTP"
        XCTAssertEqual(WorkoutShaper.intervals(in: d, fraction: 0.2)?.reps, 3)
        XCTAssertEqual(WorkoutShaper.intervals(in: d, fraction: 0.8)?.minutes, 20)
        XCTAssertNil(WorkoutShaper.intervals(in: "45 min easy", fraction: 0))
    }

    func testSweetSpotShape() {
        var s = PlanSession(kind: .bike, title: "Sweet spot", detail: "60 min: 3×12 → 2×20 @ 88–93% FTP")
        s.rx = Prescription(durationMin: 70, power: "176–186 W intervals")
        let shape = WorkoutShaper.shape(for: s, fraction: 0.1)
        XCTAssertEqual(shape.warmup?.minutes, 10)
        XCTAssertEqual(shape.blocks.first?.iterations, 3)
        XCTAssertEqual(shape.blocks.first?.work.target, .init(metric: .power, range: 176...186))
        XCTAssertEqual(shape.blocks.first?.recovery?.minutes, 5)
        XCTAssertEqual(shape.totalMinutes, 70, accuracy: 0.01)   // 10 + 3×17 + 9 cool-down
    }

    func testKeyRunEndsSteady() {
        var s = PlanSession(kind: .run, title: "Key run", detail: "60 → 80 min, last 15–20 min steady")
        s.rx = Prescription(durationMin: 70, heartRate: "145–151 bpm easy parts · 153–160 bpm work")
        let shape = WorkoutShaper.shape(for: s, fraction: 0.5)
        XCTAssertEqual(shape.blocks.count, 2)
        XCTAssertEqual(shape.blocks[0].work.target?.range, 145...151)
        XCTAssertEqual(shape.blocks[1].work.minutes, 18)
        XCTAssertEqual(shape.blocks[1].work.target?.range, 153...160)
    }

    func testEasyRidePrefersPowerOverHR() {
        var s = PlanSession(kind: .bike, title: "Long ride", detail: "2:00 → 3:00")
        s.rx = Prescription(durationMin: 150, heartRate: "138–151 bpm (Z2)", power: "112–150 W (Z2)")
        let shape = WorkoutShaper.shape(for: s, fraction: 0.5)
        XCTAssertEqual(shape.blocks.first?.work.target?.metric, .power)
        XCTAssertEqual(shape.totalMinutes, 150)
    }

    func testIdentityChangesWithContentOrTime() {
        let s = PlanSession(kind: .run, title: "Easy run", detail: "30 min")
        let t = Date(timeIntervalSince1970: 1_800_000_000)
        let a = WorkoutShaper.identity(key: "2026-09-22#0", session: s, start: t)
        XCTAssertEqual(a, WorkoutShaper.identity(key: "2026-09-22#0", session: s, start: t))
        XCTAssertNotEqual(a, WorkoutShaper.identity(key: "2026-09-22#0", session: s, start: t.addingTimeInterval(600)))
        var s2 = s; s2.detail = "40 min"
        XCTAssertNotEqual(a, WorkoutShaper.identity(key: "2026-09-22#0", session: s2, start: t))
    }

    @MainActor
    func testDeterministicUUID() {
        XCTAssertEqual(WatchScheduler.uuid("x"), WatchScheduler.uuid("x"))
        XCTAssertNotEqual(WatchScheduler.uuid("x"), WatchScheduler.uuid("y"))
    }

    @MainActor
    func testOnlyTrainingKindsGoToWatch() {
        XCTAssertNotNil(WatchScheduler.mapping(for: PlanSession(kind: .run, title: "Easy run")))
        XCTAssertNotNil(WatchScheduler.mapping(for: PlanSession(kind: .flex, title: "Optional easy spin")))
        XCTAssertNil(WatchScheduler.mapping(for: PlanSession(kind: .rest, title: "Off")))
        XCTAssertNil(WatchScheduler.mapping(for: PlanSession(kind: .fun, title: "Race day")))
        // Since v2.10 a snowboard day is a workout you can record: it goes to the Watch as an
        // open-ended snowboarding workout, like golf.
        XCTAssertEqual(WatchScheduler.mapping(for: PlanSession(kind: .snow, title: "Snowboarding"))?.0, .snowboarding)
    }
}
