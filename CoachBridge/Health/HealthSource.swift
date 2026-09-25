import Foundation
import HealthKit

/// Everything the app reads about the athlete's body and training, independent of where it came
/// from. HealthKit is the only source today; FIT import and other devices are meant to plug in
/// here, so nothing outside `Health/` should hold an `HKHealthStore` or build a reader itself.
///
/// Read-only by design — there is no write method, and there shouldn't be one.
@MainActor
protocol HealthSource: AnyObject {
    /// Trends behind the dashboard: resting HR, HRV, weekly load, recent workouts.
    func dashboard(now: Date) async throws -> DashboardData
    /// Recorded workouts in `[start, end)`, newest first.
    func workouts(from start: Date, to end: Date) async throws -> [WorkoutSummary]
    /// One calendar day's metrics, as exported to Drive.
    func day(_ day: Date) async -> DayBuild
    /// Heart rate, power and zones for one workout; nil if the source no longer has it.
    func workoutDetail(_ summary: WorkoutSummary, lthr: Int?) async throws -> WorkoutDetail?
}

/// Apple Health. The readers stay as they were; this only gives them one front door.
@MainActor
final class HealthKitSource: HealthSource {
    private let store: HKHealthStore

    init(store: HKHealthStore) { self.store = store }

    func dashboard(now: Date) async throws -> DashboardData {
        try await TrendReader(store: store).load(now: now)
    }

    func workouts(from start: Date, to end: Date) async throws -> [WorkoutSummary] {
        try await TrendReader(store: store).summaries(from: start, to: end)
    }

    func day(_ day: Date) async -> DayBuild {
        await DayRecordBuilder(store: store).build(for: day)
    }

    func workoutDetail(_ summary: WorkoutSummary, lthr: Int?) async throws -> WorkoutDetail? {
        try await WorkoutDetailReader(store: store).load(summary, lthr: lthr)
    }
}
