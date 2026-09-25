import HealthKit

/// HealthKit side of the contract: which type each key reads, and in what unit.
extension MetricKey {
    var quantityIdentifier: HKQuantityTypeIdentifier? {
        switch self {
        case .rhr:            return .restingHeartRate
        case .hrv:            return .heartRateVariabilitySDNN
        case .sleep:          return nil
        case .resp:           return .respiratoryRate
        case .wristTemp:      return .appleSleepingWristTemperature
        case .spo2:           return .oxygenSaturation
        case .vo2:            return .vo2Max
        case .cardioRecovery: return .heartRateRecoveryOneMinute
        case .walkHR:         return .walkingHeartRateAverage
        case .weight:         return .bodyMass
        case .bodyFat:        return .bodyFatPercentage
        case .activeCal:      return .activeEnergyBurned
        case .exerciseMin:    return .appleExerciseTime
        case .steps:          return .stepCount
        case .runPower:       return .runningPower
        case .gct:            return .runningGroundContactTime
        case .vosc:           return .runningVerticalOscillation
        case .stride:         return .runningStrideLength
        }
    }

    /// The HealthKit type each key is computed from.
    var sourceType: HKObjectType {
        if let id = quantityIdentifier { return HKQuantityType(id) }
        return HKCategoryType(.sleepAnalysis)
    }

    /// Unit HealthKit values are read in. Percent types come back as 0–1 and are ×100 later;
    /// wrist temperature comes back in °C and is converted to a °F delta later.
    var healthUnit: HKUnit? {
        let bpm = HKUnit.count().unitDivided(by: .minute())
        switch self {
        case .rhr, .cardioRecovery, .walkHR, .resp: return bpm
        case .hrv, .gct:        return .secondUnit(with: .milli)
        case .sleep:            return nil
        case .wristTemp:        return .degreeCelsius()
        case .spo2, .bodyFat:   return .percent()
        case .vo2:              return HKUnit(from: "ml/kg*min")
        case .weight:           return .pound()
        case .activeCal:        return .kilocalorie()
        case .exerciseMin:      return .minute()
        case .steps:            return .count()
        case .runPower:         return .watt()
        case .vosc:             return .meterUnit(with: .centi)
        case .stride:           return .meter()
        }
    }

    /// Running-form keys need the most recent run workout to scope their samples.
    var needsWorkouts: Bool {
        switch self {
        case .runPower, .gct, .vosc, .stride: return true
        default: return false
        }
    }
}

enum HealthTypes {
    /// Everything the app asks to read: the 18 metric sources, workouts (needed to find
    /// "the most recent run"), and the dashboard's workout-detail types.
    static var read: Set<HKObjectType> {
        var types = Set(MetricKey.allCases.map(\.sourceType))
        types.insert(HKObjectType.workoutType())
        types.formUnion(dashboardExtras)
        return types
    }

    /// Extra types the dashboard and calendar read for workout details (never exported to Drive).
    static var dashboardExtras: Set<HKObjectType> {
        [
            HKQuantityType(.heartRate),
            HKQuantityType(.distanceWalkingRunning),
            HKQuantityType(.distanceCycling),
            HKQuantityType(.distanceSwimming),
            HKQuantityType(.cyclingPower),
            HKQuantityType(.cyclingCadence),
        ]
    }

    /// Read-only app: never request write access.
    static var share: Set<HKSampleType> { [] }

    /// Types M3 will register observer queries + daily background delivery for.
    static var backgroundDelivery: [HKSampleType] {
        [
            HKQuantityType(.restingHeartRate),
            HKQuantityType(.heartRateVariabilitySDNN),
            HKCategoryType(.sleepAnalysis),
        ]
    }
}
