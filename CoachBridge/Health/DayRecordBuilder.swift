import HealthKit
import os

/// One metric's result plus a human-readable explanation of how it was computed,
/// so M1 can be checked by hand against the Health app. Shown on screen only — never logged.
struct MetricReading: Identifiable, Sendable {
    let key: MetricKey
    let value: Double?
    let detail: String
    var id: MetricKey { key }
}

struct DayBuild: Sendable {
    let record: DayRecord
    let readings: [MetricReading]
}

/// Builds the DayRecord for check-in day D following the rules in coach-bridge-handoff.md.
@MainActor
final class DayRecordBuilder {
    private let store: HKHealthStore
    private let calendar: Calendar
    private let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "CoachBridge", category: "builder")

    init(store: HKHealthStore, calendar: Calendar = .current) {
        self.store = store
        self.calendar = calendar
    }

    func build(for day: Date, now: Date = .now) async -> DayBuild {
        let w = DayWindows(for: day, calendar: calendar)
        var readings: [MetricReading] = []
        for key in MetricKey.allCases {
            do {
                readings.append(try await read(key, w))
            } catch {
                readings.append(MetricReading(key: key, value: nil, detail: "Error: \(error.localizedDescription)"))
            }
        }
        var metrics: [MetricKey: Double] = [:]
        for r in readings { if let v = r.value { metrics[r.key] = v } }

        log.info("Built day record: \(metrics.count, privacy: .public) of \(MetricKey.allCases.count, privacy: .public) metrics present")
        let record = DayRecord(date: DayRecord.dateKey(for: day, calendar: calendar),
                               exportedAt: now,
                               metrics: metrics)
        return DayBuild(record: record, readings: readings)
    }

    // MARK: - Per-key rules

    private func read(_ key: MetricKey, _ w: DayWindows) async throws -> MetricReading {
        switch key {
        case .rhr:
            return try await latest(key, in: w.day, scope: "today")
        case .hrv, .resp:
            return try await mean(key, in: w.sleep, scope: "6 PM–noon")
        case .spo2:
            return try await mean(key, in: w.sleep, scope: "6 PM–noon", multiplier: 100)
        case .sleep:
            return try await sleep(w)
        case .wristTemp:
            return try await wristTemp(w)
        case .vo2, .cardioRecovery, .weight:
            return try await latest(key, in: w.last7Days, scope: "last 7 days")
        case .bodyFat:
            return try await latest(key, in: w.last7Days, scope: "last 7 days", multiplier: 100)
        case .walkHR:
            return try await latest(key, in: w.previousDay, scope: "yesterday")
        case .activeCal, .exerciseMin, .steps:
            return try await dailySum(key, in: w.previousDay)
        case .runPower, .gct, .vosc, .stride:
            return try await runningForm(key, w)
        }
    }

    // MARK: - Query helpers

    private func samplePredicate(_ interval: DateInterval) -> NSPredicate {
        HKQuery.predicateForSamples(withStart: interval.start, end: interval.end, options: .strictStartDate)
    }

    private func quantitySamples(_ key: MetricKey, in interval: DateInterval,
                                 newestFirst: Bool = false, limit: Int? = nil) async throws -> [HKQuantitySample] {
        let type = HKQuantityType(key.quantityIdentifier!)
        let descriptor = HKSampleQueryDescriptor(
            predicates: [.quantitySample(type: type, predicate: samplePredicate(interval))],
            sortDescriptors: [SortDescriptor(\.endDate, order: newestFirst ? .reverse : .forward)],
            limit: limit
        )
        return try await descriptor.result(for: store)
    }

    private func latest(_ key: MetricKey, in interval: DateInterval, scope: String,
                        multiplier: Double = 1) async throws -> MetricReading {
        guard let s = try await quantitySamples(key, in: interval, newestFirst: true, limit: 1).first else {
            return MetricReading(key: key, value: nil, detail: "No samples (\(scope))")
        }
        let v = s.quantity.doubleValue(for: key.healthUnit!) * multiplier
        return MetricReading(key: key, value: v,
                             detail: "Latest \(scope): \(when(s.endDate)) · \(sourceName(s))")
    }

    private func mean(_ key: MetricKey, in interval: DateInterval, scope: String,
                      multiplier: Double = 1) async throws -> MetricReading {
        let samples = try await quantitySamples(key, in: interval)
        let values = samples.map { $0.quantity.doubleValue(for: key.healthUnit!) * multiplier }
        guard let m = Stats.mean(values) else {
            return MetricReading(key: key, value: nil, detail: "No samples (\(scope))")
        }
        let lo = key.format(values.min()!), hi = key.format(values.max()!)
        return MetricReading(key: key, value: m,
                             detail: "Mean of \(values.count) samples \(scope), range \(lo)–\(hi)")
    }

    private func dailySum(_ key: MetricKey, in interval: DateInterval) async throws -> MetricReading {
        let type = HKQuantityType(key.quantityIdentifier!)
        let descriptor = HKStatisticsQueryDescriptor(
            predicate: .quantitySample(type: type, predicate: samplePredicate(interval)),
            options: .cumulativeSum
        )
        guard let sum = try await descriptor.result(for: store)?.sumQuantity() else {
            return MetricReading(key: key, value: nil, detail: "No samples yesterday")
        }
        return MetricReading(key: key, value: sum.doubleValue(for: key.healthUnit!),
                             detail: "Total for \(dayName(interval.start)), sources de-duplicated")
    }

    private func sleep(_ w: DayWindows) async throws -> MetricReading {
        let asleep: Set<Int> = [
            HKCategoryValueSleepAnalysis.asleepCore.rawValue,
            HKCategoryValueSleepAnalysis.asleepDeep.rawValue,
            HKCategoryValueSleepAnalysis.asleepREM.rawValue,
            HKCategoryValueSleepAnalysis.asleepUnspecified.rawValue,
        ]
        // Overlap predicate (no options): a session that began before 6 PM still counts, clipped.
        let predicate = HKQuery.predicateForSamples(withStart: w.sleep.start, end: w.sleep.end, options: [])
        let descriptor = HKSampleQueryDescriptor(
            predicates: [.categorySample(type: HKCategoryType(.sleepAnalysis), predicate: predicate)],
            sortDescriptors: [SortDescriptor(\.startDate)]
        )
        let samples = try await descriptor.result(for: store)
        let intervals = samples
            .filter { asleep.contains($0.value) }
            .map { SleepInterval(start: $0.startDate, end: $0.endDate, isWatch: isWatch($0)) }
        let excluded = samples.count - intervals.count

        guard let r = SleepMath.hoursAsleep(intervals, window: w.sleep) else {
            return MetricReading(key: .sleep, value: nil,
                                 detail: "No asleep samples 6 PM–noon (\(excluded) in-bed/awake ignored)")
        }
        var detail = "\(r.intervalsUsed) asleep segments merged"
        detail += r.usedWatchOnly ? ", Watch only" : ", no Watch data"
        if r.intervalsIgnored > 0 { detail += " (\(r.intervalsIgnored) non-Watch ignored)" }
        detail += "; \(excluded) in-bed/awake excluded"
        return MetricReading(key: .sleep, value: r.hours, detail: detail)
    }

    private func wristTemp(_ w: DayWindows) async throws -> MetricReading {
        let key = MetricKey.wristTemp
        guard let tonight = try await quantitySamples(key, in: w.sleep, newestFirst: true, limit: 1).first else {
            return MetricReading(key: key, value: nil, detail: "No wrist temperature last night")
        }
        let historyStart = calendar.date(byAdding: .day, value: -28, to: w.sleep.start)!
        let history = try await quantitySamples(key, in: DateInterval(start: historyStart, end: w.sleep.start))
        let histF = history.map { Stats.celsiusToFahrenheit($0.quantity.doubleValue(for: .degreeCelsius())) }
        guard histF.count >= 7, let baseline = Stats.median(histF) else {
            return MetricReading(key: key, value: nil,
                                 detail: "Only \(histF.count) prior nights; needs 7 before reporting")
        }
        let todayF = Stats.celsiusToFahrenheit(tonight.quantity.doubleValue(for: .degreeCelsius()))
        return MetricReading(key: key, value: todayF - baseline,
                             detail: String(format: "Last night %.2f °F vs %ld-night median %.2f °F", todayF, histF.count, baseline))
    }

    private func runningForm(_ key: MetricKey, _ w: DayWindows) async throws -> MetricReading {
        let predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [
            HKQuery.predicateForWorkouts(with: .running),
            samplePredicate(w.lastTwoDays),
        ])
        let descriptor = HKSampleQueryDescriptor(
            predicates: [.workout(predicate)],
            sortDescriptors: [SortDescriptor(\.endDate, order: .reverse)],
            limit: 1
        )
        guard let run = try await descriptor.result(for: store).first else {
            return MetricReading(key: key, value: nil, detail: "No run yesterday or today")
        }
        let interval = DateInterval(start: run.startDate, end: max(run.endDate, run.startDate))
        let values = try await quantitySamples(key, in: interval).map { $0.quantity.doubleValue(for: key.healthUnit!) }
        guard let m = Stats.mean(values) else {
            return MetricReading(key: key, value: nil, detail: "Run at \(when(run.startDate)) has no \(key.title.lowercased()) samples")
        }
        let minutes = Int(run.duration / 60)
        return MetricReading(key: key, value: m,
                             detail: "Mean of \(values.count) samples, run at \(when(run.startDate)) (\(minutes) min)")
    }

    // MARK: - Formatting

    private func isWatch(_ s: HKSample) -> Bool {
        s.sourceRevision.productType?.hasPrefix("Watch") ?? false
    }

    private func sourceName(_ s: HKSample) -> String {
        isWatch(s) ? "Apple Watch" : s.sourceRevision.source.name
    }

    private func when(_ d: Date) -> String {
        d.formatted(.dateTime.weekday(.abbreviated).hour().minute())
    }

    private func dayName(_ d: Date) -> String {
        d.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
    }
}
