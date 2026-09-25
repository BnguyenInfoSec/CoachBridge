import SwiftUI

// MARK: - Appearance

/// Light / dark / follow the phone. Stored in UserDefaults and applied at the root.
enum Appearance: String, CaseIterable, Identifiable {
    case system, light, dark

    static let key = "app.appearance"
    var id: String { rawValue }

    var label: String {
        switch self {
        case .system: return "System"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }

    var symbol: String {
        switch self {
        case .system: return "circle.lefthalf.filled"
        case .light: return "sun.max.fill"
        case .dark: return "moon.fill"
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}

// MARK: - Background

/// The app's backdrop: a deep base with soft colored light behind it, so the glass
/// surfaces on top have something to pick up. Both schemes are hand-tuned rather than
/// one being a wash of the other.
struct AppBackground: View {
    @Environment(\.colorScheme) private var scheme
    /// The tab's hue, so each tab reads slightly differently without changing the furniture.
    var accent: Color = Palette.series1

    var body: some View {
        ZStack {
            (scheme == .dark ? Palette.canvasDark : Palette.canvasLight)
                .ignoresSafeArea()

            // Light mode uses pastels — the chart hues lifted toward white — because the
            // saturated versions read as neon behind glass. Dark keeps the full hues, which
            // it needs to show up at all.
            let pastel = scheme != .dark
            blob(Palette.wash(accent, pastel: pastel), x: 0.08, y: 0.02, r: 0.90,
                 opacity: scheme == .dark ? 0.40 : 0.30)
            blob(Palette.wash(Palette.series3, pastel: pastel), x: 0.95, y: 0.22, r: 0.75,
                 opacity: scheme == .dark ? 0.28 : 0.24)
            blob(Palette.wash(Palette.series2, pastel: pastel), x: 0.78, y: 0.92, r: 0.85,
                 opacity: scheme == .dark ? 0.26 : 0.20)
            blob(Palette.wash(Palette.series7, pastel: pastel), x: 0.05, y: 0.78, r: 0.70,
                 opacity: scheme == .dark ? 0.30 : 0.18)

            // Keeps text legible over the brightest part of the wash.
            LinearGradient(colors: [.clear, (scheme == .dark ? Color.black : Color.white).opacity(0.35)],
                           startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
        }
        .drawingGroup()
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }

    private func blob(_ color: Color, x: CGFloat, y: CGFloat, r: CGFloat, opacity: Double) -> some View {
        GeometryReader { geo in
            let side = max(geo.size.width, geo.size.height) * r
            RadialGradient(colors: [color.opacity(opacity), color.opacity(0)],
                           center: .center, startRadius: 0, endRadius: side / 2)
                .frame(width: side, height: side)
                .position(x: geo.size.width * x, y: geo.size.height * y)
        }
        .ignoresSafeArea()
    }
}

// MARK: - Liquid Glass

/// Liquid Glass where the phone has it (iOS 26), a material that reads the same way where it
/// doesn't. Every glass surface in the app goes through here, so there's one place to change.
struct GlassSurface: ViewModifier {
    var radius: CGFloat = 18
    var tint: Color? = nil
    var interactive = false
    @Environment(\.colorScheme) private var scheme

    /// Card tints follow the same rule as the background wash: pastel in light, full hue in dark.
    private var effectiveTint: Color? {
        tint.map { Palette.wash($0, pastel: scheme != .dark) }
    }

    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.glassEffect(Self.glass(tint: effectiveTint, interactive: interactive),
                                in: .rect(cornerRadius: radius, style: .continuous))
        } else {
            content
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
                .background(
                    RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .fill(effectiveTint?.opacity(scheme == .dark ? 0.22 : 0.30) ?? .clear)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .strokeBorder(.white.opacity(scheme == .dark ? 0.12 : 0.55), lineWidth: 0.7)
                )
                .shadow(color: .black.opacity(scheme == .dark ? 0.30 : 0.07), radius: 10, y: 4)
        }
    }

    @available(iOS 26.0, *)
    private static func glass(tint: Color?, interactive: Bool) -> Glass {
        var g = Glass.regular
        if let tint { g = g.tint(tint) }
        if interactive { g = g.interactive() }
        return g
    }
}

extension View {
    /// A glass panel. Pass a tint to colour it (Claude's cards, a sport's card).
    func glassSurface(radius: CGFloat = 18, tint: Color? = nil, interactive: Bool = false) -> some View {
        modifier(GlassSurface(radius: radius, tint: tint, interactive: interactive))
    }

    /// The standard card: padding, then glass.
    func glassCard(radius: CGFloat = 18, tint: Color? = nil, padding: CGFloat = 16) -> some View {
        self.padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassSurface(radius: radius, tint: tint)
    }

    /// Prominent buttons pick up Liquid Glass on iOS 26 and stay bordered-prominent below it.
    @ViewBuilder
    func glassButton(prominent: Bool = false) -> some View {
        if #available(iOS 26.0, *) {
            if prominent { self.buttonStyle(.glassProminent) } else { self.buttonStyle(.glass) }
        } else {
            if prominent { self.buttonStyle(.borderedProminent) } else { self.buttonStyle(.bordered) }
        }
    }

    /// The tab bar shrinks out of the way as you scroll, the way system apps do on iOS 26.
    @ViewBuilder
    func minimizingTabBar() -> some View {
        if #available(iOS 26.0, *) {
            self.tabBarMinimizeBehavior(.onScrollDown)
        } else {
            self
        }
    }

    /// Softens where scrolling content meets the bars, so the wash doesn't cut off hard.
    @ViewBuilder
    func softScrollEdges() -> some View {
        if #available(iOS 26.0, *) {
            self.scrollEdgeEffectStyle(.soft, for: .all)
        } else {
            self
        }
    }

    /// Lays a screen's content over the app's backdrop with the tab's accent.
    func screenBackground(_ accent: Color) -> some View {
        self.scrollContentBackground(.hidden)
            .background(AppBackground(accent: accent))
    }
}
