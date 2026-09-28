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
