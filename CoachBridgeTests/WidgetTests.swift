import XCTest
@testable import CoachBridge

final class GoNoGoTests: XCTestCase {
    private let easy = PlanSession(kind: .run, title: "Easy run", detail: "Zone 2")
    private let hard = PlanSession(kind: .bike, title: "Sweet spot intervals", detail: "3 × 12 min sweet spot")
    private let rest = PlanSession(kind: .rest, title: "Off")

    func testRecoveredMeansGo() {
        XCTAssertEqual(GoNoGo.decide(recovery: .good, today: [hard]), .go)
        XCTAssertEqual(GoNoGo.decide(recovery: .normal, today: [easy]), .go)
    }

    func testPoorRecoveryTurnsAHardDayEasy() {
        XCTAssertEqual(GoNoGo.decide(recovery: .caution, today: [easy, hard]), .swapToEasy)
        XCTAssertEqual(GoNoGo.decide(recovery: .caution, today: [easy]), .goEasy)
    }

    func testRestDaysAndMissingData() {
        XCTAssertEqual(GoNoGo.decide(recovery: .caution, today: [rest]), .rest)
        XCTAssertEqual(GoNoGo.decide(recovery: .good, today: []), .rest)
        XCTAssertEqual(GoNoGo.decide(recovery: .unknown, today: [easy]), .byFeel)
        XCTAssertEqual(GoNoGo.decide(recovery: nil, today: [easy]), .byFeel)
    }

    func testGolfAndSnowAreNeverHard() {
        XCTAssertFalse(GoNoGo.isHard(PlanSession(kind: .golf, title: "Steady 18 at race pace")))
        XCTAssertFalse(GoNoGo.isHard(PlanSession(kind: .snow, title: "Snowboard")))
    }
}

@MainActor
private final class NoHealth: HealthSource {
    func dashboard(now: Date) async throws -> DashboardData { DemoData.dashboard(now: now) }
    func workouts(from start: Date, to end: Date) async throws -> [WorkoutSummary] { [] }
    func day(_ day: Date) async -> DayBuild { fatalError("not used") }
    func workoutDetail(_ summary: WorkoutSummary, lthr: Int?) async throws -> WorkoutDetail? { nil }
}

@MainActor
final class PhoneWidgetTests: XCTestCase {
    private var savedDemo = false
    override func setUp() async throws { savedDemo = DemoData.isOn; DemoData.isOn = true }
    override func tearDown() async throws { DemoData.isOn = savedDemo }

    /// The widget draws on the Lock Screen: a word and a session, never a health number.
    func testTheWidgetCarriesNoHealthNumbers() throws {
        let plan = PlanModel(source: NoHealth())
        let g = PhoneGlancePublisher.glance(plan: plan, recovery: .caution, isDemo: true, now: .now)
        let json = String(decoding: try JSONEncoder().encode(g), as: UTF8.self)
        for banned in ["bpm", "HRV", " ms", "Resting"] { XCTAssertFalse(json.contains(banned), banned) }
        XCTAssertNotNil(GoNoGo(rawValue: g.verdict))
    }

    func testLongSessionsGetFuelCadenceShortOnesDont() {
        var long = PlanSession(kind: .bike, title: "Long ride", rx: Prescription(durationMin: 180))
        long.rx?.fuelDuring = "80 g carbs/h — Bloks every 20 min"
        let a = LiveSession.attributes(for: long)
        XCTAssertEqual(a.fuelEveryMinutes, 20)
        XCTAssertEqual(a.fuelText, "80 g carbs/h")
        XCTAssertNil(LiveSession.attributes(for: PlanSession(kind: .run, title: "Easy", rx: Prescription(durationMin: 40))).fuelEveryMinutes)
    }

    func testRaceActivityUsesTheRacePlan() throws {
        let race = try XCTUnwrap(RaceDayPlan.make(event: .half703, raceName: "Oceanside 70.3", ftp: 250, lthr: 165))
        let a = LiveSession.attributes(for: race)
        XCTAssertEqual(a.title, "Oceanside 70.3")
        XCTAssertEqual(a.plannedMinutes, race.totalMinutes)
        XCTAssertEqual(a.fuelEveryMinutes, 20)
    }
}
