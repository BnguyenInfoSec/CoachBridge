import HealthKit
import XCTest
@testable import CoachBridge

final class ProvenanceTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_790_000_000)

    private func w(_ sport: Sport, at minutes: Double, for duration: Double, hr: Double? = nil,
                   distance: Double? = nil, _ origin: Origin = .appleHealth) -> WorkoutSummary {
        WorkoutSummary(id: UUID(), sport: sport, name: sport.rawValue, start: t0.addingTimeInterval(minutes * 60),
                       duration: duration * 60, distanceMeters: distance, avgHR: hr, origin: origin)
    }

    private let fit = Origin(kind: .fitFile, name: "Edge 540")
    private let garmin = Origin(kind: .appleHealth, name: "Garmin Connect")

    func testTheSameRideFromTwoSourcesCountsOnce() {
        let file = w(.bike, at: 0, for: 120, hr: 138, distance: 60_000, fit)
        let synced = w(.bike, at: 2, for: 118, hr: 137, distance: 59_800, garmin)   // clock drift, auto-pause
        let merged = WorkoutReconciler.merged([[synced], [file]])
        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged.first?.origin.kind, .fitFile, "on a tie the device's own file wins")
    }

    func testTheRicherCopyWins() {
        let bare = w(.bike, at: 0, for: 60, fit)                                  // no HR, no distance
        let full = w(.bike, at: 1, for: 60, hr: 140, distance: 30_000, garmin)
        XCTAssertEqual(WorkoutReconciler.merged([[bare], [full]]).first?.avgHR, 140)
    }

    func testDifferentSessionsStayApart() {
        let morning = w(.run, at: 0, for: 45)
        let evening = w(.run, at: 600, for: 45)
        let brickBike = w(.bike, at: 0, for: 90)
        let brickRun = w(.run, at: 92, for: 20)
        let longer = w(.run, at: 3, for: 90)                                       // same start, twice as long
        XCTAssertEqual(WorkoutReconciler.merged([[morning, evening]]).count, 2)
        XCTAssertEqual(WorkoutReconciler.merged([[brickBike, brickRun]]).count, 2)
        XCTAssertEqual(WorkoutReconciler.merged([[morning], [longer]]).count, 2)
        XCTAssertEqual(WorkoutReconciler.merged([[morning], [brickBike]]).count, 2, "different sports")
    }

    func testAnUnknownSportMatchesEitherSide() {
        let generic = w(.other, at: 1, for: 60, fit)
        let run = w(.run, at: 0, for: 60, hr: 150, distance: 10_000)
        let merged = WorkoutReconciler.merged([[run], [generic]])
        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged.first?.sport, .run, "the copy that knows the sport wins")
    }

    func testMergedIsNewestFirst() {
        let merged = WorkoutReconciler.merged([[w(.run, at: 0, for: 30)], [w(.swim, at: 2_000, for: 30)]])
        XCTAssertEqual(merged.map(\.sport), [.swim, .run])
    }

    /// Every pair of the same session under drift and pause noise merges; nothing within a day
    /// that's really separate does. Swept rather than spot-checked.
    func testSweepOfDriftAndSeparation() {
        for drift in stride(from: -9.0, through: 9.0, by: 1.5) {
            for scale in [0.9, 0.95, 1.0, 1.05, 1.1] {
                let a = w(.bike, at: 0, for: 100)
                let b = w(.bike, at: drift, for: 100 * scale)
                XCTAssertEqual(WorkoutReconciler.merged([[a], [b]]).count, 1, "drift \(drift) scale \(scale)")
            }
        }
        for gap in stride(from: 11.0, through: 720, by: 30) {
            XCTAssertEqual(WorkoutReconciler.merged([[w(.bike, at: 0, for: 100)], [w(.bike, at: gap, for: 100)]]).count, 2, "gap \(gap)")
        }
    }

    func testTheCoachIsToldWhichHRVItSees() {
        var d = DemoData.dashboard(now: t0)
        XCTAssertEqual(d.hrvMethod, .sdnn)
        let text = CoachContext.healthSummary(d)
        XCTAssertTrue(text.contains("HRV (SDNN)"))
        XCTAssertTrue(text.contains("isn't comparable with RMSSD"))
        d.hrvMethod = .rmssd
        XCTAssertFalse(CoachContext.healthSummary(d).contains("isn't comparable"))
    }

    func testOriginsAreRecorded() {
        XCTAssertTrue(DemoData.dashboard(now: t0).recent.allSatisfy { $0.origin == .demo })
        XCTAssertEqual(fit.label, "FIT file · Edge 540")
    }
}

final class WorkoutIconTests: XCTestCase {
    /// A walk used to show the dumbbell, because everything that isn't swim/bike/run shares
    /// the `.other` bucket. Each activity now carries its own symbol.
    func testWalksHikesAndGolfDontLookLikeLifting() {
        let lifting = Sport.other.symbol
        for t: HKWorkoutActivityType in [.walking, .hiking, .golf, .snowboarding, .yoga] {
            XCTAssertNotEqual(TrendReader.symbol(for: t), lifting, "\(t.rawValue)")
        }
        XCTAssertEqual(TrendReader.symbol(for: .walking), "figure.walk")
        XCTAssertEqual(TrendReader.symbol(for: .traditionalStrengthTraining), lifting)
    }

    func testFITWalksKeepTheirIconToo() {
        let s = FITParser.Session(sport: 11, subSport: nil, start: .now, elapsed: 60)
        XCTAssertEqual(FITParser.describe(s).symbol, "figure.walk")
    }

    func testIconFallsBackToTheSport() {
        let w = WorkoutSummary(id: UUID(), sport: .run, name: "Run", start: .now, duration: 60, distanceMeters: nil, avgHR: nil)
        XCTAssertEqual(w.icon, "figure.run")
    }
}
