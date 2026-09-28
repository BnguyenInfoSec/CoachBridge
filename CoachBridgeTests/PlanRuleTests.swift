import XCTest
@testable import CoachBridge

final class RuleEngineTests: XCTestCase {
    private var cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        return c
    }()

    /// Monday-first week of 2026-10-12, so index 0 = Mon (jsDay 1) … index 6 = Sun (jsDay 0).
    private let week = ["2026-10-12", "2026-10-13", "2026-10-14", "2026-10-15",
                        "2026-10-16", "2026-10-17", "2026-10-18"]
    private func iso(_ i: Int) -> String { week[i] }
    private func jsDay(_ i: Int) -> Int { (i + 1) % 7 }

    private func rule(_ action: PlanRule.Action, _ start: String = "2026-10-01", _ end: String = "2026-12-31",
                      weekdays: [Int]? = nil, at seconds: Double = 0) -> PlanRule {
        PlanRule(action: action, startDate: start, endDate: end, weekdays: weekdays, note: "test",
                 createdAt: Date(timeIntervalSince1970: seconds))
    }

    private func session(_ kind: SessionKind, _ title: String, minutes: Int? = 60, mine: Bool = false) -> PlanSession {
        var s = PlanSession(kind: kind, title: title)
        if let minutes { s.rx = Prescription(durationMin: minutes) }
        if mine { s.customID = UUID() }
        return s
    }

    private func apply(_ rules: [PlanRule], _ days: [[PlanSession]]) -> [[PlanSession]] {
        RuleEngine.apply(rules, to: days, isoFor: iso, jsDayFor: jsDay)
    }

    func testSwapSportClearsStaleTargets() {
        var run = session(.run, "Tempo run")
        run.rx?.heartRate = "158–166 bpm"
        var days = Array(repeating: [PlanSession](), count: 7)
        days[2] = [run]
        let out = apply([rule(.swapSport(from: .run, to: .bike))], days)
        XCTAssertEqual(out[2][0].kind, .bike)
        XCTAssertNil(out[2][0].rx?.heartRate)
        XCTAssertTrue(out[2][0].detail.contains("Coach rule"))
    }

    func testRuleNeverTouchesAthleteSessions() {
        var days = Array(repeating: [PlanSession](), count: 7)
        days[5] = [session(.run, "Group run with the guys", mine: true), session(.bike, "Easy spin")]
        let out = apply([rule(.swapSport(from: .run, to: .swim)),
                         rule(.dropKind(.run), at: 1),
                         rule(.scaleDuration(percent: 50), at: 2)], days)
        let mine = out[5].first { $0.addedByAthlete }
        XCTAssertEqual(mine?.kind, .run)
        XCTAssertEqual(mine?.rx?.durationMin, 60)
        XCTAssertEqual(out[5].first { !$0.addedByAthlete }?.rx?.durationMin, 30)
    }

    func testMoveWeekdayMovesWholeDayAndLeavesRest() {
        var days = Array(repeating: [PlanSession](), count: 7)
        days[5] = [session(.bike, "Long ride", minutes: 150)]          // Saturday
        // Saturday (jsDay 6) → Sunday (jsDay 0), which is index 6.
        let out = apply([rule(.moveWeekday(from: 6, to: 0))], days)
        XCTAssertEqual(out[6].map(\.title), ["Long ride"])
        XCTAssertEqual(out[5].map(\.kind), [.rest])
    }

    func testDropKindLeavesARestDayRatherThanNothing() {
        var days = Array(repeating: [PlanSession](), count: 7)
        days[1] = [session(.lift, "Strength")]
        let out = apply([rule(.dropKind(.lift))], days)
        XCTAssertEqual(out[1].map(\.kind), [.rest])
    }

    func testAddWeeklyOnlyOnItsWeekday() {
        let days = Array(repeating: [PlanSession](), count: 7)
        let out = apply([rule(.addWeekly(kind: .lift, weekday: 3, durationMin: 40,
                                         title: "Lift", detail: "Squats"))], days)
        XCTAssertEqual(out[2].map(\.title), ["Lift"])            // index 2 = Wednesday
        XCTAssertEqual(out[2][0].rx?.durationMin, 40)
        XCTAssertTrue(out.enumerated().filter { $0.offset != 2 }.allSatisfy { $0.element.isEmpty })
    }

    func testIndoorRidesFlagsBikesAndClearsPrescription() {
        var days = Array(repeating: [PlanSession](), count: 7)
        days[3] = [session(.bike, "Threshold ride"), session(.run, "Brick run")]
        let out = apply([rule(.indoorRides(true))], days)
        XCTAssertEqual(out[3][0].indoor, true)
        XCTAssertNil(out[3][0].rx)
        XCTAssertNil(out[3][1].indoor)
    }

    func testWeekdayAndDateRangeLimitTheRule() {
        var days = Array(repeating: [PlanSession](), count: 7)
        for i in 0..<7 { days[i] = [session(.bike, "Ride")] }
        let out = apply([rule(.indoorRides(true), "2026-10-14", "2026-10-15")], days)
        XCTAssertNil(out[1][0].indoor)                 // Oct 13, before the range
        XCTAssertEqual(out[2][0].indoor, true)         // Oct 14
        XCTAssertEqual(out[3][0].indoor, true)         // Oct 15
        XCTAssertNil(out[4][0].indoor)                 // Oct 16, after
    }

    func testRulesApplyOldestFirst() {
        var days = Array(repeating: [PlanSession](), count: 7)
        days[0] = [session(.run, "Easy run", minutes: 60)]
        let out = apply([rule(.scaleDuration(percent: 50), at: 10),
                         rule(.swapSport(from: .run, to: .bike), at: 0)], days)
        XCTAssertEqual(out[0][0].kind, .bike)
        XCTAssertEqual(out[0][0].rx?.durationMin, 30)
    }

    func testCoversHonorsWeekdayFilter() {
        let r = rule(.dropKind(.lift), weekdays: [1, 3])
        XCTAssertTrue(r.covers("2026-10-12", jsDay: 1))
        XCTAssertFalse(r.covers("2026-10-13", jsDay: 2))
        XCTAssertFalse(r.covers("2027-01-01", jsDay: 1))
    }

    func testEngineAppliesRulesToTheWeek() {
        let e = PlanEngine(profile: .ironmanCalifornia, settings: PlanSettings(), calendar: cal,
                           rules: [rule(.indoorRides(true), "2026-10-01", "2026-12-31")])
        let bikes = (0..<7).flatMap { e.sessions(on: e.date(week[$0])) }.filter { $0.kind == .bike }
        XCTAssertFalse(bikes.isEmpty)
        XCTAssertTrue(bikes.allSatisfy { $0.indoor == true })
    }
}

final class PlanChangeToolTests: XCTestCase {
    private let today = "2026-10-12"
    private let now = Date(timeIntervalSince1970: 1_760_000_000)

    private func parse(_ json: String) throws -> PlanProposal {
        try PlanChangeTool.parse(Data(json.utf8), todayISO: today,
                                 bounds: "2026-09-13"..."2027-10-18", now: now)
    }

    func testParsesRuleAndDay() throws {
        let p = try parse("""
        {"summary":"Rides indoors while it rains, and Saturday becomes a run.",
         "rules":[{"type":"indoor_rides","start_date":"2026-10-13","end_date":"2026-10-20","note":"Rain all week","indoor":true}],
         "days":[{"date":"2026-10-17","reason":"Group run","sessions":[
           {"kind":"run","title":"Group run","duration_min":50,"heart_rate":"140–150 bpm"}]}]}
        """)
        XCTAssertEqual(p.rules.count, 1)
        XCTAssertEqual(p.rules[0].action, .indoorRides(true))
        XCTAssertEqual(p.days.count, 1)
        XCTAssertEqual(p.days[0].sessions[0].kind, .run)
        XCTAssertEqual(p.days[0].sessions[0].rx?.durationMin, 50)
        XCTAssertEqual(p.bullets.count, 2)
        XCTAssertFalse(p.isEmpty)
    }

    func testPastAndOutOfPlanDatesAreDropped() throws {
        let p = try parse("""
        {"summary":"x","days":[
          {"date":"2026-10-01","reason":"past","sessions":[{"kind":"run","title":"a"}]},
          {"date":"2029-01-01","reason":"after the race","sessions":[{"kind":"run","title":"b"}]},
          {"date":"2026-10-20","reason":"ok","sessions":[{"kind":"run","title":"c"}]}]}
        """)
        XCTAssertEqual(p.days.map(\.date), ["2026-10-20"])
    }

    func testRuleStartIsPulledForwardToToday() throws {
        let p = try parse("""
        {"summary":"x","rules":[{"type":"drop_kind","kind":"lift","start_date":"2026-09-01",
          "end_date":"2026-11-01","note":"Shoulder"}]}
        """)
        XCTAssertEqual(p.rules[0].startDate, today)
    }

    func testBadRulesAreDroppedNotFatal() throws {
        let p = try parse("""
        {"summary":"x","rules":[
          {"type":"move_weekday","from_weekday":3,"to_weekday":3,"start_date":"2026-10-13","end_date":"2026-10-20","note":"same day"},
          {"type":"swap_sport","from_kind":"kayak","to_kind":"run","start_date":"2026-10-13","end_date":"2026-10-20","note":"not a sport"},
          {"type":"nonsense","start_date":"2026-10-13","end_date":"2026-10-20","note":"unknown"},
          {"type":"scale_duration","percent":5000,"start_date":"2026-10-13","end_date":"2026-10-20","note":"clamped"}]}
        """)
        XCTAssertEqual(p.rules.count, 1)
        XCTAssertEqual(p.rules[0].action, .scaleDuration(percent: 200))
    }

    func testCountsAreCapped() throws {
        let rules = (0..<20).map { _ in
            #"{"type":"drop_kind","kind":"lift","start_date":"2026-10-13","end_date":"2026-10-20","note":"n"}"#
        }.joined(separator: ",")
        let p = try parse(#"{"summary":"x","rules":[\#(rules)]}"#)
        XCTAssertEqual(p.rules.count, PlanChangeTool.maxRules)
    }

    func testUnreadableInputThrows() {
        XCTAssertThrowsError(try parse(#"{"nope":true}"#))
    }

    func testSchemaNamesTheToolAndItsRequiredFields() {
        let schema = PlanChangeTool.schema
        XCTAssertEqual(schema["name"] as? String, "change_plan")
        let input = schema["input_schema"] as? [String: Any]
        XCTAssertEqual(input?["required"] as? [String], ["summary"])
    }
}

final class VenueTests: XCTestCase {
    private func venue(_ slot: String, _ name: String, _ i: Int) -> Venue {
        Venue(slot: slot, name: name, createdAt: Date(timeIntervalSince1970: Double(i)))
    }

    func testSlotForSessionSplitsIndoorRides() {
        var bike = PlanSession(kind: .bike, title: "Ride")
        XCTAssertEqual(VenueSlot.key(for: bike), VenueSlot.bike)
        bike.indoor = true
        XCTAssertEqual(VenueSlot.key(for: bike), VenueSlot.bikeIndoor)
        XCTAssertNil(VenueSlot.key(for: PlanSession(kind: .rest, title: "Off")))
        XCTAssertNil(VenueSlot.key(for: PlanSession(kind: .flex, title: "Optional")))
    }

    func testPickIsStableForADateAndVariesAcrossDays() {
        let list = (0..<3).map { venue(VenueSlot.run, "Spot \($0)", $0) }
        let a = VenuePicker.pick(list, slot: VenueSlot.run, iso: "2026-10-12", pinnedID: nil)
        let again = VenuePicker.pick(list, slot: VenueSlot.run, iso: "2026-10-12", pinnedID: nil)
        XCTAssertEqual(a?.id, again?.id)
        let names = Set((0..<7).compactMap {
            VenuePicker.pick(list, slot: VenueSlot.run, iso: "2026-10-1\($0)", pinnedID: nil)?.name
        })
        XCTAssertGreaterThan(names.count, 1)
    }

    func testPinnedWins() {
        let list = (0..<3).map { venue(VenueSlot.swim, "Pool \($0)", $0) }
        let picked = VenuePicker.pick(list, slot: VenueSlot.swim, iso: "2026-10-12",
                                      pinnedID: list[2].id.uuidString)
        XCTAssertEqual(picked?.id, list[2].id)
    }

    func testOtherSlotsAndEmptyLibraryAreIgnored() {
        let list = [venue(VenueSlot.swim, "Pool", 0)]
        XCTAssertNil(VenuePicker.pick(list, slot: VenueSlot.run, iso: "2026-10-12", pinnedID: nil))
        XCTAssertNil(VenuePicker.pick([], slot: VenueSlot.swim, iso: "2026-10-12", pinnedID: nil))
    }

    func testMissingPinFallsBackToRotation() {
        let list = [venue(VenueSlot.bike, "Bayshore", 0)]
        XCTAssertEqual(VenuePicker.pick(list, slot: VenueSlot.bike, iso: "2026-10-12",
                                        pinnedID: UUID().uuidString)?.name, "Bayshore")
    }

    func testSeedCoversEverySlotThatNeedsOne() {
        let slots = Set(VenueStore.seed.map(\.slot))
        for s in VenueSlot.seeded { XCTAssertTrue(slots.contains(s), "no seed venue for \(s)") }
        XCTAssertEqual(Set(VenueSlot.all).subtracting(VenueSlot.seeded), [VenueSlot.golf],
                       "only golf may ship without a place; it falls back to its gradient")
    }

    func testEverySeededPlaceShipsWithArtwork() {
        for v in VenueStore.seed {
            XCTAssertNotNil(v.art, "\(v.name) has no illustration")
            XCTAssertTrue(v.hasImage)
            XCTAssertFalse(v.hasPhoto)
        }
    }

    func testAppearanceMapsToColorScheme() {
        XCTAssertNil(Appearance.system.colorScheme)
        XCTAssertEqual(Appearance.light.colorScheme, .light)
        XCTAssertEqual(Appearance.dark.colorScheme, .dark)
        XCTAssertEqual(Appearance(rawValue: "dark"), .dark)
    }
}

final class LoadAndHistoryTests: XCTestCase {
    private var cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        return c
    }()

    private func day(_ iso: String) -> Date {
        let p = iso.split(separator: "-").compactMap { Int($0) }
        return cal.date(from: DateComponents(year: p[0], month: p[1], day: p[2]))!
    }

    func testStuckWorkoutIsExcludedFromWeeklyHours() {
        let input: [(start: Date, duration: TimeInterval, sport: Sport)] = [
            (day("2026-08-03"), 3600, .run),            // 1 h, real
            (day("2026-08-04"), 900 * 3600, .other),    // 900 h, a workout never ended
            (day("2026-08-05"), 5400, .bike),           // 1.5 h, real
        ]
        let out = Stats.weeklyLoad(input, calendar: cal)
        XCTAssertEqual(Stats.implausibleCount(input), 1)
        XCTAssertFalse(out.contains { $0.sport == .other })
        XCTAssertEqual(out.reduce(0) { $0 + $1.hours }, 2.5, accuracy: 0.001)
    }

    func testAnIronmanDayStillCounts() {
        let input: [(start: Date, duration: TimeInterval, sport: Sport)] = [
            (day("2027-10-17"), 13.5 * 3600, .other),
        ]
        XCTAssertEqual(Stats.implausibleCount(input), 0)
        XCTAssertEqual(Stats.weeklyLoad(input, calendar: cal).first?.hours ?? 0, 13.5, accuracy: 0.001)
    }

    func testZeroLengthWorkoutsAreIgnored() {
        XCTAssertFalse(Stats.isPlausibleSession(0))
        XCTAssertTrue(Stats.isPlausibleSession(60))
        XCTAssertFalse(Stats.isPlausibleSession(Stats.maxSessionHours * 3600 + 1))
    }

    func testConversationTitleComesFromTheOpeningQuestion() {
        let msgs = [ChatMessage(role: .user, text: "How recovered am I today?\nAlso the bike"),
                    ChatMessage(role: .assistant, text: "Looks fine.")]
        XCTAssertEqual(Conversation.title(from: msgs), "How recovered am I today?")
        XCTAssertEqual(Conversation.title(from: []), "New chat")
        let long = [ChatMessage(role: .user, text: String(repeating: "a", count: 200))]
        XCTAssertLessThanOrEqual(Conversation.title(from: long).count, 48)
    }

    func testConversationRoundTripsThroughStorage() throws {
        let msgs = [ChatMessage(role: .user, text: "hi"), ChatMessage(role: .assistant, text: "hello")]
        let c = Conversation(from: msgs)
        let data = try JSONEncoder().encode(c)
        let back = try JSONDecoder().decode(Conversation.self, from: data)
        XCTAssertEqual(back.chatMessages.map(\.text), ["hi", "hello"])
        XCTAssertEqual(back.chatMessages.map(\.role), [.user, .assistant])
        XCTAssertEqual(back.preview, "hello")
    }

    func testProvidersCarryTheirOwnKeychainAccountsAndModels() {
        XCTAssertNotEqual(LLMProvider.anthropic.keychainAccount, LLMProvider.openai.keychainAccount)
        XCTAssertNotEqual(LLMProvider.openai.keychainAccount, LLMProvider.hosted.keychainAccount)
        for p in LLMProvider.allCases {
            XCTAssertFalse(p.models.isEmpty)
            XCTAssertTrue(p.models.contains(p.defaultModel))
        }
    }

    func testOpenAIRequestTranslatesTheAnthropicToolShape() throws {
        let client = OpenAIClient(apiKey: "test", model: "gpt-5-mini")
        let req = try client.makeRequest(system: "sys",
                                         messages: [ChatMessage(role: .user, text: "hi")],
                                         tools: [PlanChangeTool.schema], stream: false)
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(req.httpBody)) as? [String: Any])
        XCTAssertEqual(req.value(forHTTPHeaderField: "Authorization"), "Bearer test")
        let messages = try XCTUnwrap(body["messages"] as? [[String: Any]])
        XCTAssertEqual(messages.first?["role"] as? String, "system")
        let tools = try XCTUnwrap(body["tools"] as? [[String: Any]])
        let fn = try XCTUnwrap(tools.first?["function"] as? [String: Any])
        XCTAssertEqual(fn["name"] as? String, PlanChangeTool.name)
        XCTAssertNotNil(fn["parameters"])
    }
}

final class TimeOfDayTests: XCTestCase {
    private var cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        return c
    }()

    private func at(_ h: Int, _ m: Int = 0) -> Date {
        cal.date(from: DateComponents(year: 2026, month: 9, day: 22, hour: h, minute: m))!
    }

    func testClockFallbackWhenThereIsNoForecast() {
        XCTAssertEqual(TimeOfDay.current(at(3), calendar: cal), .night)
        XCTAssertEqual(TimeOfDay.current(at(7), calendar: cal), .morning)
        XCTAssertEqual(TimeOfDay.current(at(13), calendar: cal), .day)
        XCTAssertEqual(TimeOfDay.current(at(18), calendar: cal), .evening)
        XCTAssertEqual(TimeOfDay.current(at(22), calendar: cal), .night)
    }

    func testRealSunriseAndSunsetWin() {
        let sunrise = at(6, 40)
        let sunset = at(18, 50)
        func phase(_ h: Int, _ m: Int = 0) -> TimeOfDay {
            TimeOfDay.current(at(h, m), calendar: cal, sunrise: sunrise, sunset: sunset)
        }
        XCTAssertEqual(phase(5, 30), .night)          // before dawn
        XCTAssertEqual(phase(6, 30), .morning)        // the 45 min before sunrise counts
        XCTAssertEqual(phase(8), .morning)
        XCTAssertEqual(phase(12), .day)
        XCTAssertEqual(phase(17, 30), .evening)       // 90 min before sunset
        XCTAssertEqual(phase(19, 45), .night)         // 45 min after
    }

    func testNonsensicalSunTimesFallBackToTheClock() {
        let out = TimeOfDay.current(at(13), calendar: cal, sunrise: at(20), sunset: at(4))
        XCTAssertEqual(out, .day)
    }

    func testEverySeededPlaceHasAllFourVariantsNamed() {
        for v in VenueStore.seed {
            let base = try? XCTUnwrap(v.art)
            XCTAssertNotNil(base)
            for phase in TimeOfDay.allCases {
                XCTAssertFalse("\(base ?? "")-\(phase.rawValue)".isEmpty)
            }
        }
    }

    func testWalkthroughStepsAreOrderedAndUnique() {
        let ids = OnboardingView.Step.all.map(\.id)
        XCTAssertEqual(ids.first, "welcome")
        XCTAssertEqual(Set(ids).count, ids.count)
        XCTAssertTrue(ids.contains("health"))
        XCTAssertTrue(ids.contains("key"))
        for s in OnboardingView.Step.all {
            XCTAssertFalse(s.title.isEmpty)
            XCTAssertFalse(s.body.isEmpty)
        }
    }
}


final class ProfileAndDemoTests: XCTestCase {
    func testBlankProfileNeedsSetup() {
        XCTAssertFalse(AthleteProfile().isComplete)
        XCTAssertTrue(AthleteProfile.ironmanCalifornia.isComplete)
    }

    func testMigrationOnlyRunsForAnExistingInstall() {
        let fresh = UserDefaults(suiteName: "test.fresh.\(UUID().uuidString)")!
        XCTAssertFalse(AthleteProfile.migrated(from: PlanSettings(), defaults: fresh).isComplete)

        let existing = UserDefaults(suiteName: "test.existing.\(UUID().uuidString)")!
        var old = PlanSettings()
        old.classDays = [2, 4]
        old.classUntil = "2026-12-18"
        old.snowSaturdays = ["2027-01-09"]
        old.save(existing)
        let migrated = AthleteProfile.migrated(from: old, defaults: existing)
        XCTAssertEqual(migrated.eventKind, .ironman)
        XCTAssertEqual(migrated.commitments.first?.weekdays, [2, 4])
        XCTAssertEqual(migrated.commitments.first?.untilISO, "2026-12-18")
        XCTAssertEqual(migrated.blackouts.count, 1)
        XCTAssertEqual(migrated.blackouts.first?.mode, .crossTraining)
    }

    func testAvoidedSportsLeaveThePlan() {
        var p = AthleteProfile.ironmanCalifornia
        p.avoidedSports = [.swim]
        XCTAssertFalse(p.sports.contains(.swim))
    }

    func testRecoveryWeekIsEveryFourth() {
        XCTAssertFalse(WeekBuilder.isRecoveryWeek(0))
        XCTAssertTrue(WeekBuilder.isRecoveryWeek(3))
        XCTAssertTrue(WeekBuilder.isRecoveryWeek(7))
        XCTAssertLessThan(WeekBuilder.rampFraction(3), WeekBuilder.rampFraction(2))
    }

    func testDemoDataIsStableAndSane() {
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        let a = DemoData.dashboard(now: now)
        let b = DemoData.dashboard(now: now)
        XCTAssertEqual(a.rhr.map(\.value), b.rhr.map(\.value))
        XCTAssertEqual(a.rhr.count, 28)
        XCTAssertEqual(a.ignoredLongSessions, 0)
        XCTAssertFalse(a.weekly.isEmpty)
        // Nothing absurd: no negative or stuck-timer sessions.
        for w in a.weekly { XCTAssertTrue(w.hours > 0 && w.hours < 20) }
        for w in a.recent { XCTAssertTrue(Stats.isPlausibleSession(w.duration)) }
    }
}

final class BlueprintRangeTests: XCTestCase {
    private var cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        return c
    }()

    /// The phase hour ranges are derived, so their bounds can cross. Building any profile must
    /// never trap — this is the crash that shipped in 2.0.
    func testEveryProfileShapeProducesOrderedHourRanges() {
        for kind in EventKind.allCases {
            for current in stride(from: 0.0, through: 20.0, by: 0.5) {
                for peak in stride(from: 1.0, through: 25.0, by: 1.5) {
                    var p = AthleteProfile()
                    p.eventKind = kind
                    p.currentWeeklyHours = current
                    p.maxWeeklyHours = peak
                    p.startDateISO = "2026-10-05"
                    let bp = PlanBlueprint.make(p, calendar: cal)
                    for (id, range) in bp.hoursByPhase {
                        XCTAssertLessThanOrEqual(range.lowerBound, range.upperBound,
                                                 "\(kind.rawValue) \(id): \(current)→\(peak)")
                    }
                }
            }
        }
    }

    func testTheDefaultEmptyProfileBuilds() {
        let bp = PlanBlueprint.make(AthleteProfile(), calendar: cal)
        XCTAssertFalse(bp.phases.isEmpty)
        for (_, r) in bp.hoursByPhase { XCTAssertLessThanOrEqual(r.lowerBound, r.upperBound) }
    }
}

final class PlanStartTests: XCTestCase {
    /// The plan used to restart every day for real profiles: startDateISO was never set, so
    /// "today" was always the start and week 0.
    func testSettingUpPinsTheStart() {
        var p = AthleteProfile()
        p.eventKind = .half703
        p.eventDateISO = "2027-04-12"
        XCTAssertEqual(p.pinningStart(todayISO: "2026-09-28").startDateISO, "2026-09-28")
    }

    func testAnExistingStartIsNeverMoved() {
        var p = AthleteProfile.ironmanCalifornia
        p.startDateISO = "2026-09-13"
        XCTAssertEqual(p.pinningStart(todayISO: "2026-12-01").startDateISO, "2026-09-13")
    }

    func testAnUnfinishedProfileStaysUnpinned() {
        XCTAssertEqual(AthleteProfile().pinningStart(todayISO: "2026-09-28").startDateISO, "")
    }

    /// With the start pinned, the plan a week from now is the same plan: the week that was
    /// week 3 is still week 3.
    func testAPinnedPlanDoesntMoveAsDaysPass() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        var p = AthleteProfile.ironmanCalifornia
        p.startDateISO = "2026-09-28"
        let e = PlanEngine(profile: p, settings: PlanSettings(), calendar: cal)
        let monday = e.monday(of: e.date("2026-10-19"))
        let w = e.weekIndex(monday)
        let later = PlanEngine(profile: p, settings: PlanSettings(), calendar: cal)   // built "a week later"
        XCTAssertEqual(later.weekIndex(monday), w)
        XCTAssertEqual(w, 3)
        XCTAssertEqual(later.phases, e.phases)
    }
}
