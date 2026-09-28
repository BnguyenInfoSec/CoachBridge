import XCTest
@testable import CoachBridge

@MainActor
private final class OneRideHealth: HealthSource {
    let ride: WorkoutSummary
    init(ride: WorkoutSummary) { self.ride = ride }

    func dashboard(now: Date) async throws -> DashboardData {
        DashboardData(today: DayRecord(date: "2026-09-20", exportedAt: now, metrics: [:]),
                      rhr: [], hrv: [], hrvRolling: [],
                      weekly: Stats.weeklyLoad([(start: ride.start, duration: ride.duration, sport: ride.sport)]),
                      recent: [ride], recovery: RecoverySignal(level: .unknown, reasons: []),
                      ignoredLongSessions: 0, generatedAt: now)
    }
    func workouts(from start: Date, to end: Date) async throws -> [WorkoutSummary] {
        ride.start >= start && ride.start < end ? [ride] : []
    }
    func day(_ day: Date) async -> DayBuild { fatalError("not used") }
    func workoutDetail(_ summary: WorkoutSummary, lthr: Int?) async throws -> WorkoutDetail? { nil }
}

@MainActor
final class FITImportTests: XCTestCase {
    private let rideStart = Date(timeIntervalSince1970: 1_789_887_600)       // 2026-09-20 07:00 UTC
    private var now: Date { rideStart.addingTimeInterval(86_400) }
    private var store: FITWorkoutStore!

    override func setUp() async throws {
        store = FITWorkoutStore()
        store.deleteAll()
    }

    override func tearDown() async throws { store.deleteAll() }

    private func rideFile(minutes: UInt32 = 120) -> Data {
        var w = FITWriter()
        w.message(local: 0, global: 0, [(0, .u8(4)), (1, .u16(32)), (8, .str("ELEMNT BOLT", 16))])
        w.message(local: 1, global: 18, [(2, .u32(UInt32(rideStart.timeIntervalSince1970 - 631_065_600))),
                                          (7, .u32(minutes * 60_000)), (9, .u32(6_000_000)), (5, .u8(2)), (16, .u8(140))])
        return w.file()
    }

    func testImportKeepsTotalsAndIgnoresTheSameFileTwice() throws {
        XCTAssertEqual(try store.importFile(rideFile(), now: now), .added(1))
        XCTAssertEqual(try store.importFile(rideFile(), now: now), .alreadyImported)
        let w = try XCTUnwrap(store.workouts.first)
        XCTAssertEqual(w.sport, .bike)
        XCTAssertEqual(w.duration, 7_200)
        XCTAssertEqual(w.distanceMeters, 60_000)
        XCTAssertEqual(w.device, "ELEMNT BOLT")
        XCTAssertEqual(w.summary.origin.kind, .fitFile)
    }

    func testABadFileAddsNothing() {
        XCTAssertThrowsError(try store.importFile(Data("definitely not a fit file".utf8), now: now))
        XCTAssertTrue(store.workouts.isEmpty)
    }

    func testIdsAreStableAcrossReimport() throws {
        try store.importFile(rideFile(), now: now)
        let first = store.workouts.map(\.id)
        store.deleteAll()
        try store.importFile(rideFile(), now: now)
        XCTAssertEqual(store.workouts.map(\.id), first)
    }

    /// The ride Garmin Connect synced into Health and the same ride's FIT file: one session in
    /// the recent list, and the week's hours aren't doubled.
    func testTheSameRideFromHealthAndAFileCountsOnce() async throws {
        let synced = WorkoutSummary(id: UUID(), sport: .bike, name: "Ride", start: rideStart.addingTimeInterval(90),
                                    duration: 7_150, distanceMeters: nil, avgHR: nil,
                                    origin: Origin(kind: .appleHealth, name: "Wahoo"))
        try store.importFile(rideFile(), now: now)
        let source = CombinedSource(health: OneRideHealth(ride: synced), fit: store)

        let d = try await source.dashboard(now: now)
        XCTAssertEqual(d.recent.count, 1)
        XCTAssertEqual(d.recent.first?.origin.kind, .fitFile, "the file has distance and HR; the synced copy doesn't")
        let hours = d.weekly.reduce(0) { $0 + $1.hours }
        XCTAssertEqual(hours, 2, accuracy: 0.05, "two hours, not four")
    }

    func testWithNothingImportedTheDashboardIsHealthsOwn() async throws {
        let synced = WorkoutSummary(id: UUID(), sport: .run, name: "Run", start: rideStart, duration: 3_000,
                                    distanceMeters: 9_000, avgHR: 150)
        let health = OneRideHealth(ride: synced)
        let d = try await CombinedSource(health: health, fit: store).dashboard(now: now)
        XCTAssertEqual(d.recent.map(\.id), [synced.id])
    }

    func testImportedWorkoutsHaveNoDetailSeries() async throws {
        try store.importFile(rideFile(), now: now)
        let source = CombinedSource(health: OneRideHealth(ride: store.workouts[0].summary), fit: store)
        let detail = try await source.workoutDetail(store.workouts[0].summary, lthr: nil)
        XCTAssertNil(detail)
    }
}

@MainActor
final class FITPruneTests: XCTestCase {
    func testOldImportsArePrunedRecentOnesKept() throws {
        let store = FITWorkoutStore()
        store.deleteAll()
        defer { store.deleteAll() }
        var w = FITWriter()
        w.message(local: 0, global: 0, [(0, .u8(4))])
        w.message(local: 1, global: 18, [(2, .u32(UInt32(1_789_887_600 - 631_065_600))), (7, .u32(3_600_000)), (5, .u8(1))])
        try store.importFile(w.file(), now: Date(timeIntervalSince1970: 1_790_000_000))
        store.prune(before: Date(timeIntervalSince1970: 1_700_000_000))
        XCTAssertEqual(store.workouts.count, 1, "recent import kept")
        store.prune(before: Date(timeIntervalSince1970: 1_800_000_000))
        XCTAssertTrue(store.workouts.isEmpty, "older than the cut-off, pruned")
    }
}
