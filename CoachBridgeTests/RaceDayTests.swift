import XCTest
@testable import CoachBridge

final class RaceDayTests: XCTestCase {
    func testIronmanPacingUsesYourNumbers() throws {
        let p = try XCTUnwrap(RaceDayPlan.make(event: .ironman, raceName: "IRONMAN California", ftp: 250, lthr: 165))
        XCTAssertEqual(p.legs.map(\.sport), [.swim, .bike, .run])
        XCTAssertTrue(p.legs[1].target.hasPrefix("170–183 W"), p.legs[1].target)
        XCTAssertTrue(p.legs[2].target.hasPrefix("132–144 bpm"), p.legs[2].target)
    }

    func testWithoutNumbersItSaysWhatToAdd() throws {
        let p = try XCTUnwrap(RaceDayPlan.make(event: .half703, raceName: "70.3", ftp: nil, lthr: nil))
        XCTAssertTrue(p.legs[1].target.contains("add your FTP"))
        XCTAssertTrue(p.legs[2].target.contains("add your LTHR"))
    }

    func testBikeFuelEveryTwentyMinutesInsideTheLeg() throws {
        let p = try XCTUnwrap(RaceDayPlan.make(event: .ironman, raceName: "IM", ftp: nil, lthr: nil))
        let swim = p.legs[0].minutes, bike = p.legs[1].minutes
        let bikeFuel = p.fuel.filter { $0.leg == p.legs[1].label }
        XCTAssertEqual(bikeFuel.first?.at, swim + 20)
        XCTAssertTrue(bikeFuel.allSatisfy { $0.at > swim && $0.at < swim + bike }, "no bike fuel outside the bike")
        XCTAssertEqual(Set(zip(bikeFuel, bikeFuel.dropFirst()).map { $1.at - $0.at }), [20])
        XCTAssertTrue(bikeFuel.filter { ($0.at - swim) % 60 == 0 }.allSatisfy { $0.text.contains("savory") },
                      "a savory bite every hour, as trained")
        XCTAssertTrue(bikeFuel.allSatisfy { $0.text.hasPrefix("~26 g") }, "80 g/h in thirds")
    }

    func testTimelineIsInOrderAndStartsBeforeTheGun() throws {
        for event in EventKind.allCases where event != .general {
            let p = try XCTUnwrap(RaceDayPlan.make(event: event, raceName: "Race", ftp: 250, lthr: 165), "\(event)")
            XCTAssertEqual(p.fuel.map(\.at), p.fuel.map(\.at).sorted(), "\(event)")
            XCTAssertLessThan(p.fuel.first?.at ?? 0, 0, "\(event): breakfast comes first")
            XCTAssertLessThanOrEqual(p.fuel.last?.at ?? 0, p.totalMinutes, "\(event): nothing after the finish")
        }
    }

    func testShortRacesDontGetARaceFeed() throws {
        let p = try XCTUnwrap(RaceDayPlan.make(event: .sprintTri, raceName: "Sprint", ftp: 250, lthr: 165))
        XCTAssertFalse(p.fuel.contains { $0.text.contains("g carbs") && $0.at > 0 })
        XCTAssertNil(RaceDayPlan.make(event: .general, raceName: "x", ftp: nil, lthr: nil))
    }

    func testTrainingFuelCues() {
        XCTAssertTrue(FuelCue.every20(minutes: 60, text: "x").isEmpty, "an hour doesn't need reminders")
        XCTAssertEqual(FuelCue.every20(minutes: 120, text: "Bloks").map(\.at), [20, 40, 60, 80, 100])
    }

    /// Snapshots from before race data existed must still decode.
    func testSnapshotWithoutRaceStillDecodes() throws {
        let s = WatchSnapshot(generatedAt: Date(timeIntervalSince1970: 1_790_000_000), isDemo: false,
                              sessions: [], awaitingFeel: [])
        var json = try XCTUnwrap(try JSONSerialization.jsonObject(with: s.encoded()) as? [String: Any])
        json["race"] = nil
        let data = try JSONSerialization.data(withJSONObject: json)
        XCTAssertNotNil(WatchSnapshot.decode(data))
    }
}
