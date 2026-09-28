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

/// Apple Health plus imported FIT files, each session counted once. Daily metrics — and so the
/// Drive export and its fixed contract — come from Apple Health alone; FIT files add workouts.
@MainActor
final class CombinedSource: HealthSource {
    private let health: any HealthSource
    private let fit: FITWorkoutStore
    private let calendar: Calendar

    init(health: any HealthSource, fit: FITWorkoutStore, calendar: Calendar = .current) {
        self.health = health
        self.fit = fit
        self.calendar = calendar
    }

    /// Weekly load and recent workouts are rebuilt from both sources, over the same eight-week
    /// window TrendReader uses. With nothing imported this is exactly Apple Health's dashboard.
    func dashboard(now: Date) async throws -> DashboardData {
        let d = try await health.dashboard(now: now)
        guard !fit.workouts.isEmpty else {
            return DashboardData(today: d.today, rhr: d.rhr, hrv: d.hrv, hrvRolling: d.hrvRolling,
                                 weekly: d.weekly, recent: Array(WorkoutSegments.consolidated(d.recent).prefix(5)),
                                 recovery: d.recovery, ignoredLongSessions: d.ignoredLongSessions,
                                 generatedAt: d.generatedAt, hrvMethod: d.hrvMethod)
        }
        let weekStart = calendar.dateInterval(of: .weekOfYear, for: now)!.start
        let from = calendar.date(byAdding: .weekOfYear, value: -7, to: weekStart)!
        let to = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now))!
        let all = try await workouts(from: from, to: to)
        let load = all.map { (start: $0.start, duration: $0.duration, sport: $0.sport) }
        return DashboardData(today: d.today, rhr: d.rhr, hrv: d.hrv, hrvRolling: d.hrvRolling,
                             weekly: Stats.weeklyLoad(load, calendar: calendar), recent: Array(all.prefix(5)),
                             recovery: d.recovery, ignoredLongSessions: Stats.implausibleCount(load),
                             generatedAt: d.generatedAt, hrvMethod: d.hrvMethod)
    }

    func workouts(from start: Date, to end: Date) async throws -> [WorkoutSummary] {
        let fromHealth = try await health.workouts(from: start, to: end)
        return WorkoutSegments.consolidated(
            WorkoutReconciler.merged([fromHealth, fit.summaries(from: start, to: end)]))
    }

    func day(_ day: Date) async -> DayBuild { await health.day(day) }

    /// FIT imports keep totals only, so there's no series to chart.
    func workoutDetail(_ summary: WorkoutSummary, lthr: Int?) async throws -> WorkoutDetail? {
        guard summary.segments.count > 1 else {
            return summary.origin.kind == .fitFile ? nil : try await health.workoutDetail(summary, lthr: lthr)
        }
        var pieces: [WorkoutDetail] = []
        for s in summary.segments where s.origin.kind != .fitFile {
            if let d = try await health.workoutDetail(s, lthr: lthr) { pieces.append(d) }
        }
        return WorkoutDetail.joined(pieces, as: summary)
    }
}
