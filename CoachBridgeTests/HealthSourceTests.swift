import XCTest
@testable import CoachBridge

/// A source that returns fixed "real" data and can hold a read open, to reproduce a slow
/// HealthKit query finishing after the athlete has flipped demo mode.
@MainActor
private final class FakeSource: HealthSource {
    /// 42 ignored sessions marks data as coming from here; demo data always has 0.
    static let real = DashboardData(
        today: DayRecord(date: "2026-09-22", exportedAt: .now, metrics: [.rhr: 51]),
        rhr: [], hrv: [], hrvRolling: [], weekly: [], recent: [],
        recovery: RecoverySignal(level: .normal, reasons: []),
        ignoredLongSessions: 42, generatedAt: .now)

    var holdReads = false
    private(set) var pending: CheckedContinuation<Void, Never>?
    private(set) var dashboardReads = 0

    func release() { pending?.resume(); pending = nil }

    func dashboard(now: Date) async throws -> DashboardData {
        dashboardReads += 1
        if holdReads { await withCheckedContinuation { pending = $0 } }
        return Self.real
    }
    func workouts(from start: Date, to end: Date) async throws -> [WorkoutSummary] { [] }
    func day(_ day: Date) async -> DayBuild { fatalError("not used") }
    func workoutDetail(_ summary: WorkoutSummary, lthr: Int?) async throws -> WorkoutDetail? { nil }
}

@MainActor
final class HealthSourceTests: XCTestCase {
    private var savedDemo = false

    override func setUp() async throws {
        savedDemo = DemoData.isOn
        DemoData.isOn = false
    }

    override func tearDown() async throws {
        DemoData.isOn = savedDemo
    }

    func testDashboardReadsThroughTheSource() async {
        let source = FakeSource()
        let model = DashboardModel(source: source)
        await model.refresh()
        XCTAssertEqual(source.dashboardReads, 1)
        XCTAssertEqual(model.data?.ignoredLongSessions, 42)
    }

    /// The shipped bug: real Health numbers stayed on screen after demo mode was switched on.
    /// A real read still in flight when the switch happens must be thrown away when it lands.
    func testRealReadLandingAfterDemoSwitchIsDiscarded() async {
        let source = FakeSource()
        source.holdReads = true
        let model = DashboardModel(source: source)

        let slowRealRead = Task { await model.refresh() }
        while source.pending == nil { await Task.yield() }

        DemoData.isOn = true
        await model.demoModeChanged()
        XCTAssertEqual(model.data?.ignoredLongSessions, 0, "demo data is on screen after the switch")

        source.release()
        await slowRealRead.value
        XCTAssertEqual(model.data?.ignoredLongSessions, 0, "the late real read must not replace demo data")
    }
}
