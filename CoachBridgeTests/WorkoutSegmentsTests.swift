import XCTest
@testable import CoachBridge

final class WorkoutSegmentsTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_790_000_000)

    private func run(at m: Double, for d: Double, hr: Double? = nil, km: Double? = nil) -> WorkoutSummary {
        WorkoutSummary(id: UUID(), sport: .run, name: "Run", start: t0.addingTimeInterval(m * 60),
                       duration: d * 60, distanceMeters: km.map { $0 * 1000 }, avgHR: hr,
                       activitySymbol: "figure.run")
    }

    private func walk(at m: Double, for d: Double, hr: Double? = nil, km: Double? = nil) -> WorkoutSummary {
        WorkoutSummary(id: UUID(), sport: .other, name: "Walk", start: t0.addingTimeInterval(m * 60),
                       duration: d * 60, distanceMeters: km.map { $0 * 1000 }, avgHR: hr,
                       activitySymbol: "figure.walk")
    }

    private func ride(at m: Double, for d: Double) -> WorkoutSummary {
        WorkoutSummary(id: UUID(), sport: .bike, name: "Ride", start: t0.addingTimeInterval(m * 60),
                       duration: d * 60, distanceMeters: nil, avgHR: nil, activitySymbol: "figure.outdoor.cycle")
    }

    /// The Sat Sep 26 case: run, walk, run, walk back to back becomes one session.
    func testRunWalkIntervalsBecomeOneWorkout() {
        let first = run(at: 0, for: 20, hr: 150, km: 4)
        let pieces = [first, walk(at: 21, for: 3, hr: 120, km: 0.3),
                      run(at: 24, for: 20, hr: 154, km: 4), walk(at: 45, for: 5, hr: 118, km: 0.5)]
        let out = WorkoutSegments.consolidated(pieces.reversed())       // sources give newest first

        XCTAssertEqual(out.count, 1)
        let m = out[0]
        XCTAssertEqual(m.id, first.id, "keeps the first piece's id so a saved feel or note still attaches")
        XCTAssertEqual(m.name, "Run/walk")
        XCTAssertEqual(m.sport, .run, "most of the time was running")
        XCTAssertEqual(m.icon, "figure.run")
        XCTAssertEqual(m.duration, 48 * 60, accuracy: 0.1, "moving time, not the gaps")
        XCTAssertEqual(m.distanceMeters ?? 0, 8800, accuracy: 0.1)
        XCTAssertEqual(m.segments.count, 4)
        // Weighted by duration: (150*20 + 120*3 + 154*20 + 118*5) / 48
        let beats: Double = 150 * 20 + 120 * 3 + 154 * 20 + 118 * 5
        XCTAssertEqual(m.avgHR ?? 0, beats / 48, accuracy: 0.01)
    }

    func testABrickStaysTwoSessions() {
        let out = WorkoutSegments.consolidated([ride(at: 0, for: 90), run(at: 92, for: 30)])
        XCTAssertEqual(out.count, 2, "bike then run is a brick; the transition is the point of it")
    }

    func testAGapLongerThanTenMinutesSplitsTheOuting() {
        let out = WorkoutSegments.consolidated([run(at: 0, for: 30), walk(at: 41, for: 10)])
        XCTAssertEqual(out.count, 2)
        XCTAssertEqual(WorkoutSegments.consolidated([run(at: 0, for: 30), walk(at: 40, for: 10)]).count, 1)
    }

    func testTwoRidesBackToBackJoinButAWalkDoesNotJoinARide() {
        XCTAssertEqual(WorkoutSegments.consolidated([ride(at: 0, for: 60), ride(at: 62, for: 30)]).count, 1)
        XCTAssertEqual(WorkoutSegments.consolidated([ride(at: 0, for: 60), walk(at: 61, for: 10)]).count, 2)
    }

    func testSinglesAndOrderAreUntouched() {
        let a = run(at: 0, for: 30), b = ride(at: 600, for: 60)
        let out = WorkoutSegments.consolidated([a, b])
        XCTAssertEqual(out.map(\.id), [b.id, a.id], "newest first")
        XCTAssertTrue(out.allSatisfy { $0.segments.isEmpty })
    }

    func testMissingNumbersStayMissing() {
        let m = WorkoutSegments.merge([run(at: 0, for: 10), walk(at: 11, for: 5)])
        XCTAssertNil(m.avgHR)
        XCTAssertNil(m.distanceMeters)
    }

    func testTheCoachIsToldAboutThePieces() {
        let m = WorkoutSegments.merge([run(at: 0, for: 20), walk(at: 21, for: 3)])
        XCTAssertEqual(WorkoutSegments.describe(m), "Recorded as 2 back-to-back pieces: run 20 min, walk 3 min")
        XCTAssertNil(WorkoutSegments.describe(run(at: 0, for: 20)))
    }

    func testJoinedDetailAddsZonesAndWeightsAverages() {
        let a = run(at: 0, for: 20), b = walk(at: 21, for: 10)
        let da = WorkoutDetail(summary: a, end: a.start.addingTimeInterval(a.duration), maxHR: 170, activeKcal: 200,
                               elevationGainMeters: 10, avgPower: 250, maxPower: 400, avgCadence: 170,
                               heartRate: [TimePoint(time: a.start, value: 150)], power: [],
                               zones: [ZoneTime(zone: 2, minutes: 15), ZoneTime(zone: 3, minutes: 5)])
        let db = WorkoutDetail(summary: b, end: b.start.addingTimeInterval(b.duration), maxHR: 125, activeKcal: 50,
                               elevationGainMeters: nil, avgPower: 100, maxPower: 150, avgCadence: nil,
                               heartRate: [TimePoint(time: b.start, value: 120)], power: [],
                               zones: [ZoneTime(zone: 1, minutes: 10)])
        let merged = WorkoutSegments.merge([a, b])
        let j = WorkoutDetail.joined([db, da], as: merged)!
        XCTAssertEqual(j.maxHR, 170)
        XCTAssertEqual(j.activeKcal, 250)
        XCTAssertEqual(j.elevationGainMeters, 10)
        XCTAssertEqual(j.avgPower ?? 0, (250.0 * 20 + 100 * 10) / 30, accuracy: 0.01)
        XCTAssertEqual(j.avgCadence, 170, "a piece without cadence doesn't drag the average to zero")
        XCTAssertEqual(j.heartRate.map(\.value), [150, 120], "series in time order")
        XCTAssertEqual(j.zones?.map(\.zone), [1, 2, 3])
        XCTAssertEqual(j.end, b.start.addingTimeInterval(b.duration))
        XCTAssertNil(WorkoutDetail.joined([], as: merged))
    }
}
