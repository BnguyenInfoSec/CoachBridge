import XCTest
@testable import CoachBridge

final class PlanEngineTests: XCTestCase {
    private var cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        return c
    }()

    /// The plan is generated from a profile now, so the tests drive it from one.
    private func engine(_ p: AthleteProfile = .ironmanCalifornia,
                        _ s: PlanSettings = PlanSettings()) -> PlanEngine {
        PlanEngine(profile: p, settings: s, calendar: cal)
    }

    func testPhasesRunBackFromRaceDay() {
        let e = engine()
        XCTAssertEqual(e.startISO, "2026-09-13")
        XCTAssertEqual(e.raceISO, "2027-10-17")
        XCTAssertEqual(e.raceName, "IRONMAN California")
        XCTAssertEqual(e.phases.map(\.id), ["rec", "b1", "b2", "build", "taper"])
        // Contiguous, in order, ending on race day.
        for (a, b) in zip(e.phases, e.phases.dropFirst()) {
            XCTAssertLessThan(a.end, b.start)
        }
        XCTAssertEqual(e.phase(for: e.date("2026-09-21")).id, "rec")
        XCTAssertEqual(e.phase(for: e.date("2027-10-17")).id, "taper")
        XCTAssertEqual(e.daysToRace(from: e.date("2027-10-10")), 7)
    }

    func testShortPlanDropsRecoveryAndKeepsTaper() {
        var p = AthleteProfile()
        p.eventKind = .halfMarathon
        p.startDateISO = "2026-10-05"
        p.eventDateISO = "2026-12-13"          // 10 weeks
        let bp = PlanBlueprint.make(p, calendar: cal)
        XCTAssertFalse(bp.phases.contains { $0.id == "rec" })
        XCTAssertEqual(bp.phases.last?.id, "taper")
        XCTAssertEqual(bp.raceName, "Half marathon")
    }

    func testNoRaceDateStillMakesAPlan() {
        var p = AthleteProfile()
        p.eventKind = .general
        p.startDateISO = "2026-10-05"
        let bp = PlanBlueprint.make(p, calendar: cal)
        XCTAssertFalse(bp.hasEvent)
        XCTAssertFalse(bp.phases.isEmpty)
        XCTAssertGreaterThan(bp.endISO, bp.startISO)
    }

    func testVolumeRampsFromWhereTheAthleteActuallyIs() {
        var p = AthleteProfile.ironmanCalifornia
        p.currentWeeklyHours = 3
        p.maxWeeklyHours = 13
        let bp = PlanBlueprint.make(p, calendar: cal)
        let base1 = bp.hoursByPhase["b1"]!
        let build = bp.hoursByPhase["build"]!
        XCTAssertLessThan(base1.upperBound, build.lowerBound + 0.01)
        XCTAssertEqual(build.upperBound, 13, accuracy: 0.01)
    }

    func testUnavailableDaysStayRest() {
        var p = AthleteProfile.ironmanCalifornia
        p.availableDays = [1, 3, 6]            // Mon, Wed, Sat only
        p.longDay = 6
        let e = engine(p)
        let monday = e.monday(of: e.date("2027-03-08"))
        let week = e.rawWeek(monday)
        // Tue/Thu/Fri/Sun are index 1, 3, 4, 6 Monday-first.
        for i in [1, 3, 4, 6] {
            XCTAssertEqual(week[i].map(\.kind), [.rest], "index \(i) should be a rest day")
        }
        XCTAssertFalse(week[5].isEmpty)        // Saturday, the long day
    }

    func testLongSessionLandsOnTheChosenDay() {
        var p = AthleteProfile.ironmanCalifornia
        p.longDay = 0                          // Sunday
        let e = engine(p)
        let week = e.rawWeek(e.monday(of: e.date("2027-03-08")))
        XCTAssertTrue(week[6].contains { $0.title.hasPrefix("Long") })
    }

    func testTriathlonWithoutWaterAccessDropsSwimming() {
        var p = AthleteProfile.ironmanCalifornia
        p.set(.pool, false)
        p.set(.openWater, false)
        XCTAssertFalse(p.sports.contains(.swim))
        let e = engine(p)
        let week = e.rawWeek(e.monday(of: e.date("2027-03-08")))
        XCTAssertFalse(week.flatMap { $0 }.contains { $0.kind == .swim })
    }

    func testCommitmentMarksTheEvening() {
        let e = engine()                       // class Tue/Thu until 2026-12-18
        let tue = e.sessions(on: e.date("2026-10-13"))
        XCTAssertTrue(tue.contains { $0.title.hasPrefix("Class") })
        let laterTue = e.sessions(on: e.date("2027-01-05"))
        XCTAssertFalse(laterTue.contains { $0.title.hasPrefix("Class") })
    }

    func testBlackoutTakesOverTheDay() {
        var p = AthleteProfile.ironmanCalifornia
        p.blackouts = [Blackout(title: "Snowboarding", startISO: "2027-01-09",
                                endISO: "2027-01-10", mode: .crossTraining)]
        let e = engine(p)
        XCTAssertEqual(e.sessions(on: e.date("2027-01-09")).first?.kind, .snow)
        XCTAssertEqual(e.sessions(on: e.date("2027-01-10")).first?.kind, .snow)
        XCTAssertNotEqual(e.sessions(on: e.date("2027-01-11")).first?.kind, .snow)
    }

    func testAthleteEventReplacesTheDay() {
        let e = engine()                       // seeded with the SF 5K
        XCTAssertEqual(e.sessions(on: e.date("2026-10-18")).first?.kind, .fun)
    }

    func testOutsidePlanIsEmpty() {
        let e = engine()
        XCTAssertTrue(e.sessions(on: e.date("2026-09-01")).isEmpty)
    }

    func testGeneratedVolumeIsParseableByThePrescriber() {
        let e = engine()
        let rx = Prescriber(engine: e)
        let day = e.date("2027-03-13")
        for s in e.sessions(on: day) where s.kind == .run || s.kind == .bike {
            let p = rx.prescription(for: s, on: day)
            XCTAssertNotNil(p?.durationMin, "\(s.title) — \(s.detail) gave no duration")
        }
    }

    func testEveryWeekHasAtLeastOneSession() {
        let e = engine()
        var monday = e.monday(of: e.date(e.startISO))
        var checked = 0
        while e.iso(monday) < e.raceISO, checked < 60 {
            let week = e.rawWeek(monday)
            XCTAssertTrue(week.flatMap { $0 }.contains { $0.kind != .rest },
                          "week of \(e.iso(monday)) is entirely rest")
            monday = e.add(monday, days: 7)
            checked += 1
        }
    }
}

final class PrescriberTests: XCTestCase {
    func testParseVolume() {
        typealias P = Prescriber
        XCTAssertEqual(P.parseVolume("40 → 60 min, conversational", fraction: 0.5, sport: .run).minutes, 50)
        XCTAssertEqual(P.parseVolume("9 → 12 mi, easy", fraction: 0, sport: .run),
                       .init(minutes: 104, distance: "9.0 mi"))
        XCTAssertEqual(P.parseVolume("1,500–2,000 yd, easy + 4×100 steady", fraction: 0, sport: .swim).distance, "1,800 yd")
        XCTAssertEqual(P.parseVolume("2:00 → 3:00 + 10-min run off", fraction: 1, sport: .bike).minutes, 180)
        XCTAssertEqual(P.parseVolume("75 min → 2:45, up to 16–18 mi", fraction: 0.5, sport: .run).minutes, 120)
        XCTAssertEqual(P.parseVolume("60 min: 3×12 → 2×20 @ 88–93% FTP", fraction: 0.5, sport: .bike).minutes, 60)
        XCTAssertEqual(P.parseVolume("60 min with 3×8 at IM effort", fraction: 0, sport: .bike).minutes, 60)
        XCTAssertNil(P.parseVolume("Full body, 2 sets each, light", fraction: 0, sport: .lift).minutes)
    }

    func testZonesFromSettings() {
        var s = PlanSettings()
        s.lthrBpm = 170
        s.ftpWatts = 200
        let rx = Prescriber(engine: PlanEngine(profile: .ironmanCalifornia, settings: s))
        let d = PlanEngine(profile: .ironmanCalifornia, settings: s).date("2026-10-10")
        let ride = rx.prescription(for: PlanSession(kind: .bike, title: "Long ride", detail: "2:00 → 3:00 + 10-min run off"), on: d)!
        XCTAssertEqual(ride.power, "112–150 W (Z2)")
        XCTAssertEqual(ride.heartRate, "138–151 bpm (Z2)")
        XCTAssertTrue(ride.fuelDuring!.contains("60 g carbs/h"))
        let run = rx.prescription(for: PlanSession(kind: .run, title: "Easy run", detail: "30 min"), on: d)!
        XCTAssertEqual(run.heartRate, "145–151 bpm (Z2)")
        XCTAssertEqual(run.fuelDuring, "Water.")
        let ss = rx.prescription(for: PlanSession(kind: .bike, title: "Sweet spot", detail: "60 min: 3×12"), on: d)!
        XCTAssertEqual(ss.power, "176–186 W intervals")
    }

    func testByFeelWithoutZones() {
        let e = PlanEngine()
        let rx = Prescriber(engine: e).prescription(for: PlanSession(kind: .run, title: "Easy run", detail: "30 min"), on: e.date("2026-10-07"))!
        XCTAssertTrue(rx.heartRate!.contains("LTHR"))
        XCTAssertNil(rx.power)
    }

    func testRestHasNoTargetsButHasFood() {
        let e = PlanEngine()
        let rx = Prescriber(engine: e).prescription(for: PlanSession(kind: .rest, title: "Off"), on: e.date("2026-10-11"))!
        XCTAssertNil(rx.durationMin)
        XCTAssertNotNil(rx.fuelAfter)
    }
}

final class PlanAdjusterTests: XCTestCase {
    func testParseKeepsWindowAndSanitizes() throws {
        let json = """
        {"today_call":"Go easy today: RHR +6.","week_note":"Light week.",
         "days":[
           {"date":"2026-09-22","reason":"RHR up","changed_sessions":true,
            "sessions":[{"kind":"run","title":"Easy run","detail":"30 min","duration_min":30,"heart_rate":"under 145 bpm","fuel_during":"Water."}]},
           {"date":"2026-12-25","reason":"outside window","changed_sessions":true,"sessions":[]},
           {"date":"2026-09-23","reason":"x","sessions":[{"kind":"yoga","title":"Stretch"}]}
         ]}
        """
        let u = try PlanAdjuster.parse(Data(json.utf8), window: ["2026-09-22", "2026-09-23"], model: "m", now: .now)
        XCTAssertEqual(u.todayCall, "Go easy today: RHR +6.")
        XCTAssertEqual(u.days.count, 2)
        XCTAssertEqual(u.days["2026-09-22"]?.sessions.first?.rx?.heartRate, "under 145 bpm")
        XCTAssertEqual(u.days["2026-09-23"]?.sessions.first?.kind, .flex)       // unknown kind → optional
        XCTAssertEqual(u.days["2026-09-23"]?.changedSessions, true)             // missing → assume changed
        XCTAssertNil(u.days["2026-12-25"])
    }

    func testGarbageThrows() {
        XCTAssertThrowsError(try PlanAdjuster.parse(Data("{}".utf8), window: [], model: "m", now: .now))
    }

    func testToolInputExtraction() throws {
        let resp = #"{"content":[{"type":"tool_use","id":"t1","name":"update_week","input":{"today_call":"Go","days":[]}}],"stop_reason":"tool_use"}"#
        let data = try AnthropicClient.toolInput(from: Data(resp.utf8), name: "update_week")
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertEqual(obj?["today_call"] as? String, "Go")
    }

    func testTruncatedResponseThrows() {
        let resp = #"{"content":[{"type":"tool_use","id":"t1","name":"update_week","input":{}}],"stop_reason":"max_tokens"}"#
        XCTAssertThrowsError(try AnthropicClient.toolInput(from: Data(resp.utf8), name: "update_week"))
    }

    func testRateLimitOncePerMinute() {
        let now = Date()
        XCTAssertEqual(RateLimit.secondsRemaining(last: nil, now: now), 0)
        XCTAssertEqual(RateLimit.secondsRemaining(last: now.addingTimeInterval(-30), now: now), 30)
        XCTAssertEqual(RateLimit.secondsRemaining(last: now.addingTimeInterval(-59.2), now: now), 1)
        XCTAssertEqual(RateLimit.secondsRemaining(last: now.addingTimeInterval(-60), now: now), 0)
        XCTAssertEqual(RateLimit.secondsRemaining(last: now.addingTimeInterval(-3600), now: now), 0)
    }

    func testPromptIncludesRulesAndPlan() {
        let e = PlanEngine()
        let msg = PlanAdjuster.userMessage(engine: e, today: e.date("2026-10-07"),
                                           planned: [.init(date: "2026-10-07", day: "Wed", sessions: [PlanSession(kind: .run, title: "Easy run")])],
                                           profile: "Me", healthSummary: nil, recentWork: [])
        XCTAssertTrue(msg.contains("\"title\":\"Easy run\""))
        XCTAssertTrue(msg.contains("Not shared"))
        XCTAssertTrue(PlanAdjuster.systemPrompt(engine: e).contains("minimum week is three"))
    }
}

final class WorkoutMathTests: XCTestCase {
    // MARK: Training blocks

    func testSuggestedBlocksFillTheRunway() {
        // Every runway from a 4-week crash plan to a two-year build has to add up exactly,
        // with a taper that is never cut to nothing.
        for weeks in 4...104 {
            var p = AthleteProfile.ironmanCalifornia
            p.blockWeeks = nil
            let lengths = PlanBlueprint.blockLengths(p, totalWeeks: weeks)
            XCTAssertEqual(lengths.reduce(0) { $0 + $1.1 }, weeks, "runway \(weeks)")
            XCTAssertGreaterThanOrEqual(lengths.first { $0.0 == "taper" }?.1 ?? 0, 1, "runway \(weeks)")
        }
    }

    func testBlockOverridesAreHonouredWhenTheyFit() {
        var p = AthleteProfile.ironmanCalifornia
        p.blockWeeks = ["rec": 2, "b1": 10, "b2": 8, "build": 8, "taper": 3]
        let lengths = Dictionary(uniqueKeysWithValues: PlanBlueprint.blockLengths(p, totalWeeks: 31))
        XCTAssertEqual(lengths["rec"], 2)
        XCTAssertEqual(lengths["b1"], 10)
        XCTAssertEqual(lengths["build"], 8)
        XCTAssertEqual(lengths["taper"], 3)
    }

    func testOverAskingCutsBaseBeforeBuildAndNeverTheTaper() {
        var p = AthleteProfile.ironmanCalifornia
        p.blockWeeks = ["rec": 4, "b1": 12, "b2": 12, "build": 12, "taper": 3]   // 43 asked, 20 available
        let lengths = Dictionary(uniqueKeysWithValues: PlanBlueprint.blockLengths(p, totalWeeks: 20))
        XCTAssertEqual(lengths.values.reduce(0, +), 20)
        XCTAssertEqual(lengths["taper"], 3, "the taper is never cut")
        XCTAssertEqual(lengths["build"], 12, "build is the last block to lose weeks")
        XCTAssertEqual(lengths["rec"], 0, "the easy weeks up front go first")
        XCTAssertGreaterThanOrEqual(lengths["b1"] ?? 0, 1)
    }

    func testShortfallGoesIntoBaseOne() {
        var p = AthleteProfile.ironmanCalifornia
        p.blockWeeks = ["rec": 1, "b1": 4, "b2": 4, "build": 4, "taper": 2]      // 15 asked, 24 available
        let lengths = Dictionary(uniqueKeysWithValues: PlanBlueprint.blockLengths(p, totalWeeks: 24))
        XCTAssertEqual(lengths.values.reduce(0, +), 24)
        XCTAssertEqual(lengths["b1"], 13)
        XCTAssertEqual(lengths["build"], 4)
    }

    func testBlocksBecomePhasesWithRealDates() {
        var p = AthleteProfile.ironmanCalifornia
        p.blockWeeks = ["rec": 0, "b1": 10, "b2": 10, "build": 10, "taper": 3]
        let e = PlanEngine(profile: p, settings: PlanSettings(), calendar: cal)
        XCTAssertFalse(e.phases.contains { $0.id == "rec" }, "a zero-week block is dropped entirely")
        XCTAssertEqual(e.phases.last?.end, e.raceISO)
        for (a, b) in zip(e.phases, e.phases.dropFirst()) {
            XCTAssertLessThan(a.end, b.start)
        }
    }

    // MARK: Equipment

    func testEquipmentRoundTrips() {
        var p = AthleteProfile()
        XCTAssertFalse(p.hasTrainer)
        p.set(.trainer, true)
        p.set(.trainer, true)                       // twice must not duplicate
        XCTAssertEqual(p.equipment.filter { $0 == Equipment.trainer.rawValue }.count, 1)
        XCTAssertTrue(p.hasTrainer)
        p.set(.trainer, false)
        XCTAssertFalse(p.hasTrainer)
    }

    func testEveryEquipmentItemIsInExactlyOneGroup() {
        for item in Equipment.allCases {
            let groups = Equipment.groups.filter { Equipment.inGroup($0).contains(item) }
            XCTAssertEqual(groups.count, 1, "\(item.rawValue) is in \(groups)")
        }
    }

    func testZones() {
        XCTAssertEqual(WorkoutMath.zone(of: 140, lthr: 170, sport: .run), 1)
        XCTAssertEqual(WorkoutMath.zone(of: 150, lthr: 170, sport: .run), 2)
        XCTAssertEqual(WorkoutMath.zone(of: 160, lthr: 170, sport: .run), 3)
        XCTAssertEqual(WorkoutMath.zone(of: 165, lthr: 170, sport: .run), 4)
        XCTAssertEqual(WorkoutMath.zone(of: 175, lthr: 170, sport: .run), 5)
    }

    func testTimeInZonesCapsGaps() {
        let t0 = Date(timeIntervalSince1970: 0)
        let hr = [TimePoint(time: t0, value: 150), TimePoint(time: t0.addingTimeInterval(30), value: 150),
                  TimePoint(time: t0.addingTimeInterval(600), value: 175)]   // 570 s gap → capped at 60
        let z = WorkoutMath.timeInZones(hr, lthr: 170, sport: .run, end: t0.addingTimeInterval(630))
        XCTAssertEqual(z[1].minutes, 1.5, accuracy: 0.001)   // 30 s + 60 s in Z2
        XCTAssertEqual(z[4].minutes, 0.5, accuracy: 0.001)   // last 30 s in Z5
    }

    func testDownsample() {
        let pts = (0..<1000).map { TimePoint(time: Date(timeIntervalSince1970: Double($0)), value: Double($0)) }
        let d = WorkoutMath.downsample(pts, max: 300)
        XCTAssertEqual(d.count, 300)
        XCTAssertEqual(d.first?.value, 0)
        XCTAssertEqual(d.last?.value, 999)
    }
}
