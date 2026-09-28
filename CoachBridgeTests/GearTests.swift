import XCTest
@testable import CoachBridge

final class GearTests: XCTestCase {
    private let sample = Gear(bike: "Canyon Speedmax CF 8", tires: "GP5000 S TR, 28 mm", tireSetup: .tubeless,
                              shoes: [Gear.Shoe(category: .superTrainer, model: "Adidas Evo SL"),
                                      Gear.Shoe(category: .maxCushion, model: "Hoka Bondi 9")])

    /// The profile decodes all or nothing, and a failed load returns an empty profile. A profile
    /// saved before gear existed must still load with everything else intact.
    func testAProfileSavedBeforeGearStillLoads() throws {
        var p = AthleteProfile.ironmanCalifornia
        p.gear = nil
        var json = try XCTUnwrap(try JSONSerialization.jsonObject(with: JSONEncoder().encode(p)) as? [String: Any])
        json.removeValue(forKey: "gear")
        let old = try JSONSerialization.data(withJSONObject: json)
        let loaded = try JSONDecoder().decode(AthleteProfile.self, from: old)
        XCTAssertEqual(loaded.eventName, "IRONMAN California", "the rest of the profile survives")
        XCTAssertNil(loaded.gear)
    }

    func testGearWithMissingOrUnknownFieldsDecodesWhatItCan() throws {
        let g = try JSONDecoder().decode(Gear.self, from: Data(#"{"bike":"Cervélo P5","tireSetup":"tubular-ish","future":1}"#.utf8))
        XCTAssertEqual(g.bike, "Cervélo P5")
        XCTAssertNil(g.tireSetup, "an unknown value is dropped, not fatal")
        XCTAssertTrue(g.shoes.isEmpty)
    }

    func testGearRoundTripsInTheProfile() throws {
        var p = AthleteProfile.ironmanCalifornia
        p.gear = sample
        let back = try JSONDecoder().decode(AthleteProfile.self, from: JSONEncoder().encode(p))
        XCTAssertEqual(back.gear, sample)
    }

    func testTheCoachHearsAboutTheBikeTiresAndShoes() {
        var p = AthleteProfile.ironmanCalifornia
        p.gear = sample
        let text = CoachContext.athleteText(p, engine: PlanEngine(profile: p))
        XCTAssertTrue(text.contains("Bike: Canyon Speedmax CF 8."))
        XCTAssertTrue(text.contains("Tires: GP5000 S TR, 28 mm, tubeless."))
        XCTAssertTrue(text.contains("super trainer (Adidas Evo SL)"))
        XCTAssertTrue(text.contains("max cushion (Hoka Bondi 9)"))
        XCTAssertTrue(text.contains("which of these shoes suits a run"))
        XCTAssertTrue(PlanAdjuster.systemPrompt(engine: PlanEngine(profile: p)).contains("Bike: Canyon Speedmax CF 8."),
                      "the weekly adjustment sees it too")
    }

    func testNoGearMeansNoGearLines() {
        let text = CoachContext.athleteText(AthleteProfile.ironmanCalifornia, engine: PlanEngine())
        XCTAssertFalse(text.contains("Bike:"))
        XCTAssertFalse(text.contains("Run shoes"))
    }

    func testTypedGearIsCappedAndCleaned() {
        let g = Gear(bike: "Canyon\nSpeedmax\u{0007}" + String(repeating: "x", count: 500),
                     shoes: (0..<20).map { _ in Gear.Shoe(category: .dailyTrainer, model: "Pegasus") }).sanitized()
        XCTAssertFalse(g.bike.contains("\n"))
        XCTAssertFalse(g.bike.contains("\u{0007}"))
        XCTAssertLessThanOrEqual(g.bike.count, 80)
        XCTAssertEqual(g.shoes.count, 8)
    }

    func testEmptyGearIsntSaved() {
        var p = AthleteProfile.ironmanCalifornia
        p.gear = Gear()
        let suite = UserDefaults(suiteName: "gear-test-\(UUID().uuidString)")!
        p.save(suite)
        XCTAssertNil(AthleteProfile.load(suite).gear)
    }
}

final class GroupsetAndPressureGearTests: XCTestCase {
    func testGroupsetFacts() {
        XCTAssertTrue(Gear.Groupset.rivalXPLRAXS.isOneBy)
        XCTAssertTrue(Gear.Groupset.rivalXPLRAXS.isElectronic)
        XCTAssertFalse(Gear.Groupset.ultegraDi2.isOneBy)
        XCTAssertFalse(Gear.Groupset.shimano105.isElectronic)
        XCTAssertNil(Gear.Groupset.shimano105.batteryNote)
        XCTAssertTrue(Gear.Groupset.forceAXS.batteryNote?.contains("AXS") == true)
        XCTAssertTrue(Gear.Groupset.duraAceDi2.batteryNote?.contains("Di2") == true)
    }

    func testTheCoachHearsGroupsetTiresAndPressures() {
        var g = Gear(bike: "Canyon Grizl", tires: "Terra Speed", tireSetup: .tubeless, groupset: .rivalXPLRAXS, gearing: "40T, 10–44")
        g.tireWidthMM = 40
        g.rim = .hookless
        g.frontPSI = 34; g.rearPSI = 36
        g.riderWeightKg = 75
        let text = g.coachLines.joined(separator: "\n")
        XCTAssertTrue(text.contains("Groupset: SRAM Rival XPLR AXS (1×, electronic); gearing 40T, 10–44."), text)
        XCTAssertTrue(text.contains("Tires: Terra Speed, 40 mm, tubeless, hookless rims."), text)
        XCTAssertTrue(text.contains("34 psi front / 36 psi rear"), text)
        XCTAssertFalse(text.contains("75"), "rider weight stays on the phone")
    }

    func testOlderGearWithoutTheNewFieldsDecodes() throws {
        let g = try JSONDecoder().decode(Gear.self, from: Data(#"{"bike":"Speedmax","tires":"GP5000","shoes":[]}"#.utf8))
        XCTAssertNil(g.groupset)
        XCTAssertFalse(g.pressuresCustom)
    }

    func testRecommendationPrefersTypedWeightOverHealth() {
        var g = Gear()
        g.tireWidthMM = 28
        g.tireSetup = .tubeless
        let fromHealth = g.recommendedPressure(riderKg: 75)
        g.riderWeightKg = 95
        let typed = g.recommendedPressure(riderKg: 75)
        XCTAssertGreaterThan(typed!.rearPSI, fromHealth!.rearPSI)
        XCTAssertNil(Gear().recommendedPressure(riderKg: nil), "no weight, no recommendation")
    }

    func testRaceDayRemindsYouToChargeAndSetPressures() throws {
        var g = Gear(groupset: .ultegraDi2)
        g.frontPSI = 70; g.rearPSI = 74
        let p = try XCTUnwrap(RaceDayPlan.make(event: .half703, raceName: "70.3", ftp: nil, lthr: nil, gear: g))
        XCTAssertTrue(p.notes.contains { $0.contains("Di2") })
        XCTAssertTrue(p.notes.contains { $0.contains("70 psi front / 74 rear") })
        let run = try XCTUnwrap(RaceDayPlan.make(event: .marathon, raceName: "M", ftp: nil, lthr: nil, gear: g))
        XCTAssertFalse(run.notes.contains { $0.contains("Di2") }, "no bike, no battery note")
    }
}

final class RidePressureTests: XCTestCase {
    private var gear: Gear {
        var g = Gear(tireSetup: .tubeless)
        g.tireWidthMM = 28
        g.rim = .hooked
        return g
    }
    private let ride = PlanSession(kind: .bike, title: "Endurance ride")

    func testARideGetsTheRecommendation() throws {
        let p = try XCTUnwrap(gear.pressure(forRide: ride, wet: false, riderKg: 75))
        let rec = try XCTUnwrap(gear.recommendedPressure(riderKg: 75))
        XCTAssertEqual(p.front, rec.frontPSI)
        XCTAssertNil(p.note)
    }

    func testRainLowersItAndSaysWhy() throws {
        let dry = try XCTUnwrap(gear.pressure(forRide: ride, wet: false, riderKg: 75))
        let wet = try XCTUnwrap(gear.pressure(forRide: ride, wet: true, riderKg: 75))
        XCTAssertLessThan(wet.rear, dry.rear)
        XCTAssertNotNil(wet.note)
    }

    func testYourOwnPressuresWinAndStillEaseForRain() throws {
        var g = gear
        g.frontPSI = 70; g.rearPSI = 75; g.pressuresCustom = true
        XCTAssertEqual(g.pressure(forRide: ride, wet: false, riderKg: 75)?.rear, 75)
        XCTAssertEqual(g.pressure(forRide: ride, wet: true, riderKg: 75)?.rear, 70)
    }

    func testIndoorRidesAndRunsGetNone() {
        var indoor = ride
        indoor.indoor = true
        XCTAssertNil(gear.pressure(forRide: indoor, wet: false, riderKg: 75))
        XCTAssertNil(gear.pressure(forRide: PlanSession(kind: .run, title: "Easy run"), wet: false, riderKg: 75))
    }
}
