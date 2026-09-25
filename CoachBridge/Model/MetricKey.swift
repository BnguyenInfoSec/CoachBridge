import Foundation

/// The 18 metric keys in the coach data contract (schema 1).
/// Raw values ARE the JSON keys and the coach page's field names — never rename them.
/// Order here is the order they're written in the JSON file.
enum MetricKey: String, CaseIterable, Hashable, Sendable {
    case rhr, hrv, sleep, resp, wristTemp, spo2
    case vo2, cardioRecovery, walkHR
    case weight, bodyFat
    case activeCal, exerciseMin, steps
    case runPower, gct, vosc, stride

    /// Decimal places written to JSON (matches the contract example).
    var decimals: Int {
        switch self {
        case .sleep, .resp, .wristTemp, .vo2, .weight, .bodyFat, .vosc: return 1
        case .stride: return 2
        default: return 0
        }
    }

    var title: String {
        switch self {
        case .rhr: return "Resting HR"
        case .hrv: return "HRV (SDNN)"
        case .sleep: return "Sleep"
        case .resp: return "Respiratory rate"
        case .wristTemp: return "Wrist temp Δ"
        case .spo2: return "Blood oxygen"
        case .vo2: return "VO₂ max"
        case .cardioRecovery: return "HR recovery (1 min)"
        case .walkHR: return "Walking HR"
        case .weight: return "Weight"
        case .bodyFat: return "Body fat"
        case .activeCal: return "Active energy"
        case .exerciseMin: return "Exercise"
        case .steps: return "Steps"
        case .runPower: return "Running power"
        case .gct: return "Ground contact"
        case .vosc: return "Vertical oscillation"
        case .stride: return "Stride length"
        }
    }

    var unitLabel: String {
        switch self {
        case .rhr, .cardioRecovery, .walkHR: return "bpm"
        case .hrv, .gct: return "ms"
        case .sleep: return "h"
        case .resp: return "br/min"
        case .wristTemp: return "°F"
        case .spo2, .bodyFat: return "%"
        case .vo2: return "ml/kg/min"
        case .weight: return "lb"
        case .activeCal: return "kcal"
        case .exerciseMin: return "min"
        case .steps: return "steps"
        case .runPower: return "W"
        case .vosc: return "cm"
        case .stride: return "m"
        }
    }

    /// Fixed-precision, locale-independent number text for JSON. Never "-0".
    func format(_ value: Double) -> String {
        let s = String(format: "%.\(decimals)f", value)
        if s.hasPrefix("-"), let d = Double(s), d == 0 { return String(s.dropFirst()) }
        return s
    }
}
