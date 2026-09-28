import XCTest
@testable import CoachBridge

final class RaceProjectionTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_790_000_000)

    private func w(_ sport: Sport, km: Double, minutes: Double, day: Int = 0) -> WorkoutSummary {
        WorkoutSummary(id: UUID(), sport: sport, name: sport.rawValue, start: t0.addingTimeInterval(Double(day) * 86_400),
                       duration: minutes * 60, distanceMeters: km * 1_000, avgHR: nil)
    }

    /// Riegel by hand: 50:00 for 10 km → 50 × (21.0975/10)^1.06 = 110.3 min for the half.
    func testRunUsesRiegelFromYourBestRun() throws {
        let p = try XCTUnwrap(RaceProjection.make(event: .halfMarathon, recent: [w(.run, km: 10, minutes: 50), w(.run, km: 8, minutes: 48)]))
        XCTAssertEqual(p.legs.count, 1)
        XCTAssertEqual(p.total / 60, 110.3, accuracy: 0.2)
        XCTAssertTrue(p.legs[0].basis.text.hasPrefix("best of 2 recent runs"))
    }

    func testTriathlonRunIsSlowedOffTheBike() throws {
        let runs = [w(.run, km: 10, minutes: 50)]
        let open = try XCTUnwrap(RaceProjection.make(event: .halfMarathon, recent: runs)).legs[0].seconds
        let tri = try XCTUnwrap(RaceProjection.make(event: .half703, recent: runs)).legs.first { $0.sport == .run }!.seconds
        XCTAssertEqual(tri / open, 1.08, accuracy: 0.001)
    }

    func testSwimUsesMedianPaceAtRaceEffort() throws {
        let swims = [w(.swim, km: 2, minutes: 40), w(.swim, km: 1.5, minutes: 33), w(.swim, km: 1, minutes: 25)]   // 2:00, 2:12, 2:30 /100
        let leg = try XCTUnwrap(RaceProjection.make(event: .half703, recent: swims)).legs.first { $0.sport == .swim }!
        XCTAssertEqual(leg.seconds, 132 * 0.97 * 19, accuracy: 1, "median 2:12/100 m, 3% faster, 1.9 km")
    }

    func testBikeUsesYourQuickerRidesAdjustedForTheDistance() throws {
        let rides = (0..<8).map { i in w(.bike, km: 30 + Double(i) * 2, minutes: 60, day: i) }  // 30…44 km/h
        let leg = try XCTUnwrap(RaceProjection.make(event: .olympic, recent: rides)).legs.first { $0.sport == .bike }!
        let p75 = 40.0 / 3.6                                      // index round(7 × 0.75) = 5 → 40 km/h
        XCTAssertEqual(leg.seconds, 40_000 / (p75 * 1.08), accuracy: 1)
    }

    func testImplausibleWorkoutsAreIgnored() throws {
        let junk = [w(.bike, km: 90, minutes: 60),               // 90 km/h: a car, or a trainer's fantasy
                    w(.run, km: 10, minutes: 10),                 // 1:00/km
                    w(.swim, km: 2, minutes: 5)]                  // 0:15/100 m
        let p = try XCTUnwrap(RaceProjection.make(event: .olympic, recent: junk))
        XCTAssertEqual(p.legsFromData, 0)
        XCTAssertTrue(p.legs.allSatisfy { $0.basis == .typical })
    }

    func testNoDataMeansTypicalTimesAndAWiderRange() throws {
        let p = try XCTUnwrap(RaceProjection.make(event: .ironman, recent: []))
        XCTAssertEqual(p.legs.map(\.sport), [.swim, .bike, .run])
        XCTAssertEqual(p.range.upperBound / p.total, 1.10, accuracy: 0.0001)
        XCTAssertNil(RaceProjection.make(event: .general, recent: []))
    }

    func testFullDataGivesTheNarrowerRange() throws {
        let all = [w(.swim, km: 2, minutes: 40), w(.bike, km: 60, minutes: 120), w(.run, km: 12, minutes: 60)]
        let p = try XCTUnwrap(RaceProjection.make(event: .half703, recent: all))
        XCTAssertEqual(p.legsFromData, 3)
        XCTAssertEqual(p.range.upperBound / p.total, 1.05, accuracy: 0.0001)
    }

    func testRaceDayFuelFollowsTheProjection() throws {
        let all = [w(.swim, km: 2, minutes: 40), w(.bike, km: 60, minutes: 120), w(.run, km: 12, minutes: 60)]
        let proj = try XCTUnwrap(RaceProjection.make(event: .half703, recent: all))
        let plan = try XCTUnwrap(RaceDayPlan.make(event: .half703, raceName: "70.3", ftp: nil, lthr: nil, projection: proj))
        let swimMinutes = Int((proj.legs[0].seconds / 60).rounded())
        XCTAssertEqual(plan.legs[0].minutes, swimMinutes)
        XCTAssertEqual(plan.fuel.first { $0.leg == plan.legs[1].label }?.at, swimMinutes + 20, "bike fuel starts 20 min into the projected bike")
        XCTAssertTrue(plan.notes.contains { $0.contains("projected from your recent training") })
    }

    /// Races saved before they had a distance must still load.
    func testAnEventSavedWithoutADistanceDecodes() throws {
        let e = try JSONDecoder().decode(AthleteEvent.self, from: Data(#"{"id":"6F1C7C3A-8E5B-4C8B-9D2A-1B2C3D4E5F60","dateISO":"2027-04-12","title":"Oceanside 70.3","detail":"","isRace":true}"#.utf8))
        XCTAssertNil(e.kind)
    }
}
