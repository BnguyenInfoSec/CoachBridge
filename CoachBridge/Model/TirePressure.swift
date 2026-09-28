import Foundation

/// A starting tire pressure from rider weight, bike, tire width, setup, rim and what you're
/// riding. Pure, so it's tested.
///
/// The model: each wheel's load (rider + bike + kit, about 48 / 52 front to rear) times a factor
/// for the tire's width. The factors are calibrated to the modern calculators (SRAM / Zipp, Silca)
/// — a 75 kg rider on 28 mm road tubeless lands near 60 / 65 psi — rather than the old "100 psi
/// for everything" rule, which modern tires and rims have left behind. Then:
///   • inner tubes +5% (pinch-flat margin); tubeless and tubular as calculated
///   • race day on smooth roads +3%, rough roads −5%, wet −7%, rough gravel or trail −5%
///   • hookless rims are capped at 72.5 psi (5 bar, the ETRTO limit), and it says so
///   • never below a floor that keeps a tube off the rim
/// It's a starting point, and the app says that too: the tire's and rim's printed limits win.
enum TirePressure {
    enum Bike: String, Codable, CaseIterable, Identifiable, Sendable {
        case road, tri, gravel, mountain
        var id: String { rawValue }
        var label: String {
            switch self {
            case .road: return "Road"
            case .tri: return "Tri / TT"
            case .gravel: return "Gravel"
            case .mountain: return "Mountain"
            }
        }
        /// Bike plus bottles, tools and shoes, kg.
        var kitKg: Double {
            switch self {
            case .road: return 10
            case .tri: return 11
            case .gravel: return 11.5
            case .mountain: return 15.5
            }
        }
        /// Share of the load on the front wheel. A tri position puts a little more forward.
        var frontShare: Double { self == .tri ? 0.49 : 0.48 }
        var defaultWidth: Int {
            switch self {
            case .road, .tri: return 28
            case .gravel: return 40
            case .mountain: return 58
            }
        }
    }

    enum Rim: String, Codable, CaseIterable, Identifiable, Sendable {
        case hooked, hookless
        var id: String { rawValue }
        var label: String { self == .hooked ? "Hooked" : "Hookless" }
    }

    enum Riding: String, Codable, CaseIterable, Identifiable, Sendable {
        case roadTraining, raceDay, roughRoads, wet, gravel, trail
        var id: String { rawValue }
        var label: String {
            switch self {
            case .roadTraining: return "Road training"
            case .raceDay: return "Race day (smooth roads)"
            case .roughRoads: return "Rough roads"
            case .wet: return "Wet roads"
            case .gravel: return "Rough gravel"
            case .trail: return "Trail"
            }
        }
        var factor: Double {
            switch self {
            case .roadTraining: return 1.0
            case .raceDay: return 1.03
            case .roughRoads, .gravel, .trail: return 0.95
            case .wet: return 0.93
            }
        }
    }

    struct Result: Equatable, Sendable {
        let frontPSI: Double
        let rearPSI: Double
        let notes: [String]
        var frontBar: Double { frontPSI / psiPerBar }
        var rearBar: Double { rearPSI / psiPerBar }
    }

    static let psiPerBar = 14.5038
    /// ETRTO's limit for hookless rims.
    static let hooklessMaxPSI = 72.5

    /// Roughly the most tires of this width are rated for. A heavy rider on narrow tires would
    /// otherwise be told 150 psi; the honest answer is a wider tire.
    static func typicalMaxPSI(widthMM: Int) -> Double {
        switch widthMM {
        case ...25: return 120
        case ...28: return 110
        case ...32: return 100
        case ...38: return 80
        case ...45: return 65
        case ...56: return 50
        default: return 45
        }
    }

    /// psi per kg on one wheel, by tire width (mm). Linear between the points.
    static let widthFactors: [(mm: Double, k: Double)] = [
        (23, 1.96), (25, 1.72), (28, 1.50), (30, 1.35), (32, 1.23), (35, 1.08), (38, 0.93),
        (40, 0.84), (45, 0.72), (50, 0.63), (56, 0.53), (61, 0.48), (66, 0.43),
    ]

    static func factor(widthMM: Double) -> Double {
        let pts = widthFactors
        if widthMM <= pts.first!.mm { return pts.first!.k }
        if widthMM >= pts.last!.mm { return pts.last!.k }
        for (a, b) in zip(pts, pts.dropFirst()) where widthMM <= b.mm {
            return a.k + (b.k - a.k) * (widthMM - a.mm) / (b.mm - a.mm)
        }
        return pts.last!.k
    }

    static func recommend(riderKg: Double, bike: Bike, widthMM: Int, setup: Gear.TireSetup?,
                          rim: Rim?, riding: Riding) -> Result? {
        guard (30...200).contains(riderKg), (18...80).contains(widthMM) else { return nil }
        let load = riderKg + bike.kitKg
        let k = factor(widthMM: Double(widthMM))
        var tweak = riding.factor
        var notes: [String] = []
        if setup == .clincher || setup == nil {
            tweak *= 1.05
            notes.append("A little higher for inner tubes, to keep them off the rim on a pothole.")
        }
        var front = load * bike.frontShare * k * tweak
        var rear = load * (1 - bike.frontShare) * k * tweak

        // A tube needs enough air not to pinch; tubeless can go much lower.
        let floor: Double = (setup == .tubeless) ? 15 : (widthMM >= 35 ? 25 : 45)
        front = max(front, floor)
        rear = max(rear, floor)

        // Round before capping: capping at 72.5 and then rounding produced 73 — over the limit.
        front = front.rounded()
        rear = rear.rounded()
        let tireMax = typicalMaxPSI(widthMM: widthMM)
        if max(front, rear) > tireMax {
            front = min(front, tireMax)
            rear = min(rear, tireMax)
            notes.append("That's the top of what \(widthMM) mm tires are usually rated for. A wider tire would let you run a comfortable pressure.")
        }
        if rim == .hookless, max(front, rear) > hooklessMaxPSI {
            front = min(front, hooklessMaxPSI)
            rear = min(rear, hooklessMaxPSI)
            notes.append("Capped at 72.5 psi (5 bar): the most a hookless rim is rated for.")
        }
        if rim == .hookless, setup == .clincher || setup == nil {
            notes.append("Hookless rims need tubeless-ready tires — check yours are.")
        }
        notes.append("A starting point: the limits printed on your tire and rim always win.")
        return Result(frontPSI: front, rearPSI: rear, notes: notes)
    }
}
