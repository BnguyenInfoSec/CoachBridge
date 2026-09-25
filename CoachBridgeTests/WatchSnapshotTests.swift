import XCTest
@testable import CoachBridge

@MainActor
private final class NoHealth: HealthSource {
    func dashboard(now: Date) async throws -> DashboardData { DemoData.dashboard(now: now) }
    func workouts(from start: Date, to end: Date) async throws -> [WorkoutSummary] { [] }
    func day(_ day: Date) async -> DayBuild { fatalError("not used") }
    func workoutDetail(_ summary: WorkoutSummary, lthr: Int?) async throws -> WorkoutDetail? { nil }
}

@MainActor
final class WatchSnapshotTests: XCTestCase {
    private var savedDemo = false

    override func setUp() async throws {
        savedDemo = DemoData.isOn
        DemoData.isOn = true            // the demo plan: a real plan without anyone's data
    }

    override func tearDown() async throws { DemoData.isOn = savedDemo }

    private func build(now: Date = .now, answered: Set<UUID> = []) -> WatchSnapshot {
        let plan = PlanModel(source: NoHealth())
        return WatchLink.snapshot(plan: plan, calendar: CalendarSync(), dashboard: DemoData.dashboard(now: now),
                                  answered: { answered.contains($0) }, isDemo: true, now: now)
    }

    func testSnapshotCarriesTheComingDaysInOrder() {
        let s = build()
        XCTAssertTrue(s.isDemo)
        XCTAssertNotNil(s.phase)
        XCTAssertNotNil(s.daysToRace)
        XCTAssertFalse(s.sessions.isEmpty)
        XCTAssertEqual(s.sessions.map(\.dateISO), s.sessions.map(\.dateISO).sorted(), "sessions in day order")
        XCTAssertFalse(s.sessions.contains { $0.kind == SessionKind.rest.rawValue }, "rest isn't a session")
        XCTAssertEqual(Set(s.sessions.map(\.id)).count, s.sessions.count, "ids are unique")
    }

    func testRoundTripsThroughTheWireFormat() throws {
        // ISO-8601 on the wire is whole seconds; nothing on the watch needs finer.
        let s = build(now: Date(timeIntervalSince1970: Date.now.timeIntervalSince1970.rounded(.down)))
        XCTAssertEqual(WatchSnapshot.decode(try s.encoded()), s)
    }

    func testAnOlderOrNewerVersionIsRejectedNotHalfRead() throws {
        var s = build()
        s.version = WatchSnapshot.currentVersion + 1
        XCTAssertNil(WatchSnapshot.decode(try s.encoded()))
        XCTAssertNil(WatchSnapshot.decode(Data("not json".utf8)))
    }

    func testFitsTheTransportEvenWhenOversized() throws {
        var s = build()
        let big = s.sessions.first!
        s.sessions = (0..<200).map { i in
            var x = big
            x.id = "big#\(i)"
            x.workoutPlan = Data(repeating: 7, count: 2_000)
            return x
        }
        let fitted = s.fitting()
        XCTAssertLessThanOrEqual(try fitted.encoded().count, WatchSnapshot.maxBytes)
        XCTAssertFalse(fitted.sessions.isEmpty, "shrinking keeps at least the first session")
        XCTAssertEqual(fitted.sessions.first?.id, "big#0", "later sessions go first")
    }

    /// Complications draw on a locked watch, so the glance is stored with weaker protection.
    /// It must never carry anything from Health.
    func testGlanceCarriesNoHealthData() throws {
        let s = build()
        let json = String(decoding: try JSONEncoder().encode(s.glance), as: UTF8.self)
        for reason in s.recovery?.reasons ?? [] { XCTAssertFalse(json.contains(reason)) }
        for banned in ["bpm", "HRV", "recovery", "Resting", " ms"] {
            XCTAssertFalse(json.contains(banned), "glance mentions \(banned)")
        }
    }

    func testAnsweredWorkoutsDropOutOfAwaitingFeel() {
        let now = Date.now
        let before = build(now: now)
        guard let first = before.awaitingFeel.first else { return }      // demo may have none in the window
        let after = build(now: now, answered: [first.id])
        XCTAssertFalse(after.awaitingFeel.contains { $0.id == first.id })
        XCTAssertLessThanOrEqual(after.awaitingFeel.count, 3)
    }

    func testOnlyRecentWorkoutsAreAskedAbout() {
        let s = build()
        for w in s.awaitingFeel {
            XCTAssertLessThan(Date.now.timeIntervalSince(w.start), WorkoutFeel.askWindow)
        }
    }

    // MARK: Reports from the watch are untrusted

    func testFeelReportValidation() {
        let id = UUID()
        let ok = WatchFeelReport(workoutID: id, mood: "good", rpe: 6, sentAt: .now)
        XCTAssertTrue(ok.isValid(knownWorkouts: [id]))
        XCTAssertFalse(ok.isValid(knownWorkouts: []), "unknown workout")
        for rpe in [0, 11, -3, 1_000] {
            XCTAssertFalse(WatchFeelReport(workoutID: id, mood: "good", rpe: rpe, sentAt: .now).isValid(knownWorkouts: [id]), "rpe \(rpe)")
        }
        for mood in ["", "GOOD", "ecstatic", "good; drop table"] {
            XCTAssertFalse(WatchFeelReport(workoutID: id, mood: mood, rpe: 5, sentAt: .now).isValid(knownWorkouts: [id]), mood)
        }
        XCTAssertNil(WatchFeelReport.decode(Data("{\"workoutID\":\"nope\"}".utf8)))
    }

    /// The watch sends moods as strings; they must stay the phone's mood cases exactly.
    func testWatchMoodsMatchThePhone() {
        XCTAssertEqual(WatchFeelReport.moods, WorkoutFeel.Mood.allCases.map(\.rawValue))
    }
}
