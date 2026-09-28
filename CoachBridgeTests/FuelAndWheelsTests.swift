import XCTest
@testable import CoachBridge

final class FuelAndWheelsTests: XCTestCase {

    // MARK: Decoding — a new field must never wipe a saved profile

    func testAProfileSavedBeforeFuelStillLoads() throws {
        var p = AthleteProfile.ironmanCalifornia
        p.fuel = nil
        var json = try XCTUnwrap(try JSONSerialization.jsonObject(with: JSONEncoder().encode(p)) as? [String: Any])
        json.removeValue(forKey: "fuel")
        let loaded = try JSONDecoder().decode(AthleteProfile.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertEqual(loaded.eventName, p.eventName)
        XCTAssertNil(loaded.fuel)
    }

    func testFuelAndWheelsDecodeLeniently() throws {
        let fuel = try JSONDecoder().decode(FuelPreferences.self, from: Data(#"{"bike":{"during":"Maurten 320"},"caffeine":"bogus"}"#.utf8))
        XCTAssertEqual(fuel.bike.during, "Maurten 320")
        XCTAssertNil(fuel.caffeine, "an unknown value drops that field, not the record")
        XCTAssertTrue(fuel.run.isEmpty)

        let gear = try JSONDecoder().decode(Gear.self, from: Data(#"{"bike":"Speedmax"}"#.utf8))
        XCTAssertEqual(gear.bike, "Speedmax")
        XCTAssertTrue(gear.wheelsets.isEmpty, "gear saved before wheelsets still loads")
        let w = try JSONDecoder().decode(Gear.Wheelset.self, from: Data(#"{"name":"Zipp 404","use":"nonsense"}"#.utf8))
        XCTAssertEqual(w.name, "Zipp 404")
        XCTAssertEqual(w.use, .training)
    }

    // MARK: Fuel

    func testSanitisingCapsTextAndClampsCarbs() {
        let f = FuelPreferences(bike: .init(during: "Gel\nevery\u{0007} 30 min" + String(repeating: "x", count: 500), carbsPerHour: 400),
                                avoid: "gluten").sanitized()
        XCTAssertFalse(f.bike.during.contains("\n"))
        XCTAssertLessThanOrEqual(f.bike.during.count, FuelPreferences.maxText)
        XCTAssertNil(f.bike.carbsPerHour, "an impossible number is dropped, not trusted")
    }

    func testTheSessionNamesYourOwnProducts() {
        let plain: (before: String?, during: String?, after: String?) =
            ("60–100 g carbs 2–3 h before.", "80 g carbs/h from 20 min in — Bloks + Skratch every 15–20 min, one savory bite each hour.", "Carbs + protein.")
        let mine = FuelPreferences.Leg(during: "Maurten 320 + a gel every 40 min", before: "Bagel and honey", carbsPerHour: 60)
        let out = Prescriber.personalised(plain, with: mine, minutes: 150)
        XCTAssertEqual(out.before, "Your usual: Bagel and honey.")
        XCTAssertTrue(out.during?.contains("Maurten 320 + a gel every 40 min") == true)
        XCTAssertFalse(out.during?.contains("Bloks") == true, "the default products are replaced, not added to")
        XCTAssertTrue(out.during?.contains("60 g/h") == true, "says where your gut is")
        XCTAssertEqual(Prescriber.personalised(plain, with: mine, minutes: 40).during, plain.during,
                       "short sessions keep the plain advice")
        XCTAssertEqual(Prescriber.personalised(plain, with: nil, minutes: 150).during, plain.during)
    }

    func testThePlanUsesTheProfilesFuel() {
        var p = AthleteProfile.ironmanCalifornia
        p.fuel = FuelPreferences(bike: .init(during: "Tailwind, two bottles"))
        let e = PlanEngine(profile: p, settings: PlanSettings())
        let ride = PlanSession(kind: .bike, title: "Long ride", detail: "3:00")
        let rx = Prescriber(engine: e).prescription(for: ride, on: e.date(e.blueprint.startISO))
        XCTAssertTrue(rx?.fuelDuring?.contains("Tailwind, two bottles") == true, rx?.fuelDuring ?? "nil")
    }

    func testTheCoachHearsAboutFuelOnlyWhenThereIsSome() {
        XCTAssertTrue(FuelPreferences().coachLines.isEmpty)
        let lines = FuelPreferences(run: .init(during: "gel every 30 min", carbsPerHour: 70), caffeine: .raceOnly, avoid: "fructose").coachLines
        XCTAssertTrue(lines.contains { $0.hasPrefix("Run fuelling") && $0.contains("70 g") })
        XCTAssertTrue(lines.contains("Caffeine: race day only."))
        XCTAssertTrue(lines.contains("Avoid: fructose."))
    }

    // MARK: Wheels

    private let wheels = [Gear.Wheelset(name: "Hunt Aerodynamicist", use: .training, depthMM: 35),
                          Gear.Wheelset(name: "Zipp 858", use: .race, depthMM: 80, rim: .hookless)]

    func testGustsSuggestTheShallowerWheels() {
        var g = Gear()
        g.wheelsets = wheels
        let advice = g.wheelAdvice(gustMph: 26)
        XCTAssertTrue(advice?.contains("Hunt Aerodynamicist") == true)
        XCTAssertTrue(advice?.contains("Zipp 858") == true)
        XCTAssertNil(g.wheelAdvice(gustMph: 12), "no advice on a calm day")
        XCTAssertNil(g.wheelAdvice(gustMph: nil), "or without a forecast")
        g.wheelsets = [wheels[1]]
        XCTAssertNil(g.wheelAdvice(gustMph: 30), "no choice to make with one set")
    }

    func testADiscCountsAsDeep() {
        var g = Gear()
        g.wheelsets = [wheels[0], Gear.Wheelset(name: "Disc", use: .race, depthMM: Gear.Wheelset.disc)]
        XCTAssertTrue(g.wheelsets[1].isDeep)
        XCTAssertNotNil(g.wheelAdvice(gustMph: 25))
        XCTAssertTrue(g.wheelsets[1].line.contains("disc"))
    }

    func testTheCoachHearsAboutWheels() {
        var g = Gear()
        g.wheelsets = wheels
        let lines = g.coachLines
        XCTAssertTrue(lines.contains { $0.hasPrefix("Wheels:") && $0.contains("80 mm deep") && $0.contains("hookless") })
        XCTAssertTrue(lines.contains { $0.contains("gusty") })
        XCTAssertFalse(g.isEmpty)
    }
}
