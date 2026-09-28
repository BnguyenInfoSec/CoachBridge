import HealthKit
import os

struct TimePoint: Identifiable, Sendable, Equatable {
    let time: Date
    let value: Double
    var id: Date { time }
}

struct ZoneTime: Identifiable, Sendable, Equatable {
    let zone: Int
    let minutes: Double
    var id: Int { zone }
}

/// Everything shown on the workout screen. Read on demand, kept in memory only.
struct WorkoutDetail: Sendable {
    let summary: WorkoutSummary
    let end: Date
    let maxHR: Double?
    let activeKcal: Double?
    let elevationGainMeters: Double?
    let avgPower: Double?
    let maxPower: Double?
    let avgCadence: Double?
    let heartRate: [TimePoint]
    let power: [TimePoint]
    let zones: [ZoneTime]?
}

extension WorkoutDetail {
    /// The pieces of a merged workout as one: series end to end, zones added up, averages
    /// weighted by each piece's length. Nil when none of the pieces could be read.
    static func joined(_ pieces: [WorkoutDetail], as summary: WorkoutSummary) -> WorkoutDetail? {
        guard let last = pieces.max(by: { $0.end < $1.end }) else { return nil }
        func weighted(_ value: (WorkoutDetail) -> Double?) -> Double? {
            let known = pieces.compactMap { p in value(p).map { ($0, p.summary.duration) } }
            let time = known.reduce(0) { $0 + $1.1 }
            return time > 0 ? known.reduce(0) { $0 + $1.0 * $1.1 } / time : nil
        }
        func total(_ value: (WorkoutDetail) -> Double?) -> Double? {
            let known = pieces.compactMap(value)
            return known.isEmpty ? nil : known.reduce(0, +)
        }
        var zoneMinutes: [Int: Double] = [:]
        for z in pieces.compactMap(\.zones).joined() { zoneMinutes[z.zone, default: 0] += z.minutes }
        return WorkoutDetail(
            summary: summary, end: last.end,
            maxHR: pieces.compactMap(\.maxHR).max(),
            activeKcal: total(\.activeKcal),
            elevationGainMeters: total(\.elevationGainMeters),
            avgPower: weighted(\.avgPower),
            maxPower: pieces.compactMap(\.maxPower).max(),
            avgCadence: weighted(\.avgCadence),
            heartRate: pieces.flatMap(\.heartRate).sorted { $0.time < $1.time },
            power: pieces.flatMap(\.power).sorted { $0.time < $1.time },
            zones: zoneMinutes.isEmpty ? nil : zoneMinutes.keys.sorted().map { ZoneTime(zone: $0, minutes: zoneMinutes[$0]!) })
    }
}

enum WorkoutMath {
    /// Friel-style zones as fractions of LTHR (run and bike differ slightly at the bottom).
    static func zoneBounds(sport: Sport) -> [Double] {
        sport == .bike ? [0.81, 0.90, 0.94, 1.00] : [0.85, 0.90, 0.95, 1.00]
    }

    static func zone(of hr: Double, lthr: Double, sport: Sport) -> Int {
        let b = zoneBounds(sport: sport)
        for (i, f) in b.enumerated() where hr < lthr * f { return i + 1 }
        return 5
    }

    /// Minutes per HR zone. Each sample counts until the next one, capped at 60 s so gaps
    /// (auto-pause, lost signal) don't inflate a zone.
    static func timeInZones(_ hr: [TimePoint], lthr: Double, sport: Sport, end: Date) -> [ZoneTime] {
        var secs = [Double](repeating: 0, count: 5)
        for (i, p) in hr.enumerated() {
            let next = i + 1 < hr.count ? hr[i + 1].time : end
            let dt = min(60, max(0, next.timeIntervalSince(p.time)))
            secs[zone(of: p.value, lthr: lthr, sport: sport) - 1] += dt
        }
        return secs.enumerated().map { ZoneTime(zone: $0.offset + 1, minutes: $0.element / 60) }
    }

    /// Evenly thins a series to at most `max` points for charting.
    static func downsample(_ pts: [TimePoint], max: Int = 300) -> [TimePoint] {
        guard pts.count > max, max > 1 else { return pts }
        let step = Double(pts.count - 1) / Double(max - 1)
        return (0..<max).map { pts[Int((Double($0) * step).rounded())] }
    }
}

@MainActor
final class WorkoutDetailReader {
    private let store: HKHealthStore
    private let bpm = HKUnit.count().unitDivided(by: .minute())
    private let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "CoachBridge", category: "workout")

    init(store: HKHealthStore) { self.store = store }

    func load(_ summary: WorkoutSummary, lthr: Int?) async throws -> WorkoutDetail? {
        let byID = HKQuery.predicateForObject(with: summary.id)
        let found = try await HKSampleQueryDescriptor(predicates: [.workout(byID)], sortDescriptors: [], limit: 1)
            .result(for: store)
        guard let w = found.first else { return nil }
        let window = DateInterval(start: w.startDate, end: max(w.endDate, w.startDate))

        let hrStats = w.statistics(for: HKQuantityType(.heartRate))
        let kcal = w.statistics(for: HKQuantityType(.activeEnergyBurned))?.sumQuantity()?.doubleValue(for: .kilocalorie())
        let elevation = (w.metadata?[HKMetadataKeyElevationAscended] as? HKQuantity)?.doubleValue(for: .meter())

        let powerType: HKQuantityType? = switch summary.sport {
        case .run: HKQuantityType(.runningPower)
        case .bike: HKQuantityType(.cyclingPower)
        default: nil
        }
        let powerStats = powerType.flatMap { w.statistics(for: $0) }
        let cadence = summary.sport == .bike
            ? w.statistics(for: HKQuantityType(.cyclingCadence))?.averageQuantity()?.doubleValue(for: bpm)
            : nil

        let hr = try await series(HKQuantityType(.heartRate), unit: bpm, in: window)
        var power: [TimePoint] = []
        if let powerType { power = try await series(powerType, unit: .watt(), in: window) }
        let zones = lthr.map { WorkoutMath.timeInZones(hr, lthr: Double($0), sport: summary.sport, end: window.end) }

        log.info("Loaded workout detail: \(hr.count, privacy: .public) HR samples, \(power.count, privacy: .public) power samples")
        return WorkoutDetail(
            summary: summary, end: window.end,
            maxHR: hrStats?.maximumQuantity()?.doubleValue(for: bpm),
            activeKcal: kcal, elevationGainMeters: elevation,
            avgPower: powerStats?.averageQuantity()?.doubleValue(for: .watt()),
            maxPower: powerStats?.maximumQuantity()?.doubleValue(for: .watt()),
            avgCadence: cadence,
            heartRate: WorkoutMath.downsample(hr), power: WorkoutMath.downsample(power),
            zones: zones)
    }

    private func series(_ type: HKQuantityType, unit: HKUnit, in window: DateInterval) async throws -> [TimePoint] {
        let predicate = HKQuery.predicateForSamples(withStart: window.start, end: window.end, options: [])
        let samples = try await HKSampleQueryDescriptor(
            predicates: [.quantitySample(type: type, predicate: predicate)],
            sortDescriptors: [SortDescriptor(\.startDate)]
        ).result(for: store)
        return samples.map { TimePoint(time: $0.startDate, value: $0.quantity.doubleValue(for: unit)) }
    }
}
