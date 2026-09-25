import SwiftUI
import UIKit

/// Chart colors from the validated reference palette (categorical slots 1–4, light/dark steps)
/// and the fixed status palette. Status colors always ship with an icon and a label.
enum Palette {
    static let series1 = Color(light: 0x2a78d6, dark: 0x3987e5)   // blue
    static let series2 = Color(light: 0xeb6834, dark: 0xd95926)   // orange
    static let series3 = Color(light: 0x1baf7a, dark: 0x199e70)   // aqua
    static let series4 = Color(light: 0xeda100, dark: 0xc98500)   // yellow
    static let series5 = Color(light: 0xe87ba4, dark: 0xd55181)   // magenta
    static let series7 = Color(light: 0x4a3aa7, dark: 0x9085e9)   // violet
    static let neutral = Color(light: 0x9a9892, dark: 0x6f6e69)

    static let good = Color(hex: 0x0ca30c)
    static let warning = Color(hex: 0xfab219)
    static let muted = Color.secondary

    /// The backdrop behind the glass. Light stays near-paper so text keeps its contrast;
    /// dark is a blue-black rather than pure black, which is what the glass reads against.
    static let canvasLight = Color(hex: 0xF3F5FA)
    static let canvasDark = Color(hex: 0x0B111C)

    /// Background-only versions of the hues. The chart palette is calibrated for contrast
    /// against a card; behind glass those same colors read as neon, so the wash uses them
    /// lifted most of the way toward white. Nothing that carries data uses this.
    static func wash(_ c: Color, pastel: Bool) -> Color {
        pastel ? c.blended(with: .white, amount: 0.55) : c
    }

    /// The hue each tab washes its background with.
    enum Tab {
        static let today = series1
        static let coach = series7
        static let plan = series3
        static let sync = series2
        static let settings = neutral
    }

    /// A sport's color at card-tint strength.
    static func tint(for kind: SessionKind) -> Color { color(for: kind) }

    /// Sport gradient for headers and accents.
    static func gradient(for kind: SessionKind) -> LinearGradient {
        let c = color(for: kind)
        return LinearGradient(colors: [c, c.opacity(0.55)], startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    /// A hue per metric family, so the stat grid reads as groups rather than one wall of tiles:
    /// heart magenta, recovery aqua, overnight violet, body yellow, activity orange.
    static func color(for key: MetricKey) -> Color {
        switch key {
        case .rhr, .walkHR, .cardioRecovery: return series5
        case .hrv, .vo2: return series3
        case .sleep, .resp, .wristTemp, .spo2: return series7
        case .weight, .bodyFat: return series4
        case .activeCal, .exerciseMin, .steps: return series2
        case .runPower, .gct, .vosc, .stride: return series1
        }
    }

    /// Status color for a recovery level, so the dashboard isn't all one hue.
    static func color(for level: RecoverySignal.Level) -> Color {
        switch level {
        case .good: return good
        case .normal: return series1
        case .caution: return warning
        case .unknown: return neutral
        }
    }

    /// Plan session colors: sports keep the dashboard's slots; lifting magenta; snow/events violet.
    static func color(for kind: SessionKind) -> Color {
        switch kind {
        case .swim: return series1
        case .bike: return series2
        case .run: return series3
        case .lift: return series5
        case .snow, .fun: return series7
        case .rest, .flex: return neutral
        }
    }

    /// Training phases as one ramp of a single hue, light to deep as the load builds and back
    /// down for the taper. A ramp rather than the sport palette, so a phase band never reads as
    /// "swim week" next to the sport-colored session dots.
    static func color(forPhase id: String) -> Color {
        switch id {
        // Spread wide enough to tell adjacent phases apart in a 5 pt stripe, in both schemes.
        case "rec": return Color(light: 0x7fcbd9, dark: 0x4aa7b8)
        case "b1": return Color(light: 0x3f9be0, dark: 0x3f95da)
        case "b2": return Color(light: 0x2f63c8, dark: 0x6a8ff0)
        case "build": return Color(light: 0x23307f, dark: 0xa9b8ff)
        case "taper": return Color(light: 0x9a7be0, dark: 0xc3a8ff)
        default: return neutral
        }
    }

    /// Fixed sport → slot mapping, so a sport keeps its color whatever else is on screen.
    static func color(for sport: Sport) -> Color {
        switch sport {
        case .swim: return series1
        case .bike: return series2
        case .run: return series3
        case .other: return series4
        }
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(uiColor: UIColor(hex: hex))
    }

    init(light: UInt32, dark: UInt32) {
        self.init(uiColor: UIColor { $0.userInterfaceStyle == .dark ? UIColor(hex: dark) : UIColor(hex: light) })
    }

    /// Blend toward another color, keeping light/dark dynamism.
    /// (`Color.mix(with:by:)` is iOS 18+; this app targets 17.)
    func blended(with other: Color, amount: Double) -> Color {
        Color(uiColor: UIColor(self).blended(with: UIColor(other), amount: CGFloat(amount)))
    }
}

extension UIColor {
    /// Resolved per trait collection, so a dynamic color stays dynamic after blending.
    func blended(with other: UIColor, amount: CGFloat) -> UIColor {
        UIColor { traits in
            let a = self.resolvedColor(with: traits)
            let b = other.resolvedColor(with: traits)
            var r1: CGFloat = 0, g1: CGFloat = 0, b1: CGFloat = 0, a1: CGFloat = 0
            var r2: CGFloat = 0, g2: CGFloat = 0, b2: CGFloat = 0, a2: CGFloat = 0
            a.getRed(&r1, green: &g1, blue: &b1, alpha: &a1)
            b.getRed(&r2, green: &g2, blue: &b2, alpha: &a2)
            let t = max(0, min(1, amount))
            return UIColor(red: r1 + (r2 - r1) * t, green: g1 + (g2 - g1) * t,
                           blue: b1 + (b2 - b1) * t, alpha: a1 + (a2 - a1) * t)
        }
    }

    convenience init(hex: UInt32) {
        self.init(red: CGFloat((hex >> 16) & 0xff) / 255,
                  green: CGFloat((hex >> 8) & 0xff) / 255,
                  blue: CGFloat(hex & 0xff) / 255,
                  alpha: 1)
    }
}
