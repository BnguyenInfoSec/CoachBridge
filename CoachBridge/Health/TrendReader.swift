import HealthKit
import os

struct DashboardData: Sendable {
    let today: DayRecord
    let rhr: [DailyPoint]
    let hrv: [DailyPoint]
    let hrvRolling: [DailyPoint]
    let weekly: [WeeklyLoad]
    let recent: [WorkoutSummary]
    let recovery: RecoverySignal
    /// Sessions too long to be real (a workout left running), excluded from the weekly hours.
    let ignoredLongSessions: Int
    let generatedAt: Date
    /// Apple Health's HRV is SDNN. Carried with the numbers so nothing downstream — the coach
    /// above all — reads them against RMSSD norms from Whoop, Garmin or Oura.
    var hrvMethod: HRVMethod = .sdnn
}

/// Reads the trend data behind the phone dashboard. Everything stays in memory.
@MainActor
final class TrendReader {
    private let store: HKHealthStore
    private let calendar: Calendar
    private let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "CoachBridge", category: "trends")
    private let bpm = HKUnit.count().unitDivided(by: .minute())

    init(store: HKHealthStore, calendar: Calendar = .current) {
        self.store = store
        self.calendar = calendar
    }

    func load(now: Date = .now, days: Int = 28, weeks: Int = 8) async throws -> DashboardData {
        let todayStart = calendar.startOfDay(for: now)
        let end = calendar.date(byAdding: .day, value: 1, to: todayStart)!
        let start = calendar.date(byAdding: .day, value: -(days - 1), to: todayStart)!

        let today = await DayRecordBuilder(store: store, calendar: calendar).build(for: now).record
        let rhr = try await daily(.restingHeartRate, unit: bpm, from: start, to: end)
        let hrv = try await daily(.heartRateVariabilitySDNN, unit: .secondUnit(with: .milli), from: start, to: end)
        let hrvRolling = Stats.rollingAverage(hrv, days: 7, calendar: calendar)

        let weekStart = calendar.dateInterval(of: .weekOfYear, for: now)!.start
        let workoutsFrom = calendar.date(byAdding: .weekOfYear, value: -(weeks - 1), to: weekStart)!
        let workouts = try await fetchWorkouts(from: workoutsFrom, to: end)
        let loadInput = workouts.map { (start: $0.startDate, duration: $0.duration,
                                        sport: Self.sport(for: $0.workoutActivityType)) }
        let weekly = Stats.weeklyLoad(loadInput, calendar: calendar)
        let ignored = Stats.implausibleCount(loadInput)
        let recent = workouts.prefix(5).map(summary)

        // Baselines: resting HR from the days before today; HRV last 7 days vs the whole window.
        let rhrBaseline = rhr.filter { $0.day < todayStart }.map(\.value)
        let sevenDaysAgo = calendar.date(byAdding: .day, value: -6, to: todayStart)!
        let recovery = RecoverySignal.evaluate(
            rhrToday: today.metrics[.rhr],
            rhrBaseline: rhrBaseline,
            hrvRecent: hrv.filter { $0.day >= sevenDaysAgo }.map(\.value),
            hrvBaseline: hrv.map(\.value)
        )

        log.info("Dashboard loaded: \(rhr.count, privacy: .public) RHR days, \(hrv.count, privacy: .public) HRV days, \(workouts.count, privacy: .public) workouts")
        return DashboardData(today: today, rhr: rhr, hrv: hrv, hrvRolling: hrvRolling,
                             weekly: weekly, recent: recent, recovery: recovery,
                             ignoredLongSessions: ignored, generatedAt: now)
    }

    // MARK: - Queries

    private func daily(_ id: HKQuantityTypeIdentifier, unit: HKUnit, from start: Date, to end: Date) async throws -> [DailyPoint] {
        let type = HKQuantityType(id)
        let predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: .strictStartDate)
        let descriptor = HKStatisticsCollectionQueryDescriptor(
            predicate: .quantitySample(type: type, predicate: predicate),
            options: .discreteAverage,
            anchorDate: start,
            intervalComponents: DateComponents(day: 1)
        )
        let collection = try await descriptor.result(for: store)
        return collection.statistics().compactMap { s in
            guard let q = s.averageQuantity() else { return nil }
            return DailyPoint(day: s.startDate, value: q.doubleValue(for: unit))
        }
    }

    private func fetchWorkouts(from start: Date, to end: Date) async throws -> [HKWorkout] {
        let predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: .strictStartDate)
        let descriptor = HKSampleQueryDescriptor(
            predicates: [.workout(predicate)],
            sortDescriptors: [SortDescriptor(\.startDate, order: .reverse)]
        )
        return try await descriptor.result(for: store)
    }

    /// Summaries of every workout that started in [start, end), newest first.
    func summaries(from start: Date, to end: Date) async throws -> [WorkoutSummary] {
        try await fetchWorkouts(from: start, to: end).map(summary)
    }

    private func summary(_ w: HKWorkout) -> WorkoutSummary {
        let sport = Self.sport(for: w.workoutActivityType)
        let distanceType: HKQuantityType? = switch sport {
        case .run: HKQuantityType(.distanceWalkingRunning)
        case .bike: HKQuantityType(.distanceCycling)
        case .swim: HKQuantityType(.distanceSwimming)
        case .other: nil
        }
        let distance = distanceType.flatMap { w.statistics(for: $0)?.sumQuantity()?.doubleValue(for: .meter()) }
        let hr = w.statistics(for: HKQuantityType(.heartRate))?.averageQuantity()?.doubleValue(for: bpm)
        return WorkoutSummary(id: w.uuid, sport: sport, name: Self.name(for: w.workoutActivityType),
                              start: w.startDate, duration: w.duration, distanceMeters: distance, avgHR: hr,
                              origin: Origin(kind: .appleHealth, name: w.sourceRevision.source.name))
    }

    static func sport(for type: HKWorkoutActivityType) -> Sport {
        switch type {
        case .swimming: return .swim
        case .cycling, .handCycling: return .bike
        case .running: return .run
        default: return .other
        }
    }

    static func name(for type: HKWorkoutActivityType) -> String {
        switch type {
        case .swimming: return "Swim"
        case .cycling: return "Ride"
        case .running: return "Run"
        case .walking: return "Walk"
        case .hiking: return "Hike"
        case .traditionalStrengthTraining, .functionalStrengthTraining: return "Strength"
        case .pilates: return "Pilates"
        case .yoga: return "Yoga"
        case .tennis: return "Tennis"
        case .golf: return "Golf"
        case .coreTraining: return "Core"
        case .swimBikeRun: return "Multisport"
        case .highIntensityIntervalTraining: return "HIIT"
        default: return "Workout"
        }
    }
}
