import Foundation

/// What the athlete actually eats and drinks, by sport. The plan's fuelling targets used to name
/// one athlete's products ("Bloks + Skratch") for everyone; now they name yours, and the coach
/// knows what your gut is trained to handle.
///
/// Optional on the profile and decoded leniently: the profile decodes all or nothing, so a strict
/// new field would wipe everyone's setup (CLAUDE.md §3).
struct FuelPreferences: Codable, Equatable, Sendable {
    /// One sport's fuelling.
    struct Leg: Codable, Equatable, Sendable {
        /// What you use during the session: "Maurten 320 + a gel every 30 min".
        var during: String = ""
        /// What you eat before: "Bagel with honey 2 h out".
        var before: String = ""
        /// Carbs per hour your gut handles now. Nil when you haven't said.
        var carbsPerHour: Int? = nil

        init(during: String = "", before: String = "", carbsPerHour: Int? = nil) {
            self.during = during
            self.before = before
            self.carbsPerHour = carbsPerHour
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            during = (try? c.decodeIfPresent(String.self, forKey: .during)) ?? ""
            before = (try? c.decodeIfPresent(String.self, forKey: .before)) ?? ""
            carbsPerHour = try? c.decodeIfPresent(Int.self, forKey: .carbsPerHour)
        }

        var isEmpty: Bool { during.isEmpty && before.isEmpty && carbsPerHour == nil }
    }

    enum Caffeine: String, Codable, CaseIterable, Identifiable, Sendable {
        case yes, raceOnly, none
        var id: String { rawValue }
        var label: String {
            switch self {
            case .yes: return "Yes, in training and racing"
            case .raceOnly: return "Race day only"
            case .none: return "No caffeine"
            }
        }
    }

    var swim = Leg()
    var bike = Leg()
    var run = Leg()
    var caffeine: Caffeine? = nil
    /// Anything to stay away from: an allergy, a product that upsets your stomach.
    var avoid: String = ""

    static let maxText = 120
    static let carbRange = 0...150

    init(swim: Leg = Leg(), bike: Leg = Leg(), run: Leg = Leg(), caffeine: Caffeine? = nil, avoid: String = "") {
        self.swim = swim
        self.bike = bike
        self.run = run
        self.caffeine = caffeine
        self.avoid = avoid
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        swim = (try? c.decodeIfPresent(Leg.self, forKey: .swim)) ?? Leg()
        bike = (try? c.decodeIfPresent(Leg.self, forKey: .bike)) ?? Leg()
        run = (try? c.decodeIfPresent(Leg.self, forKey: .run)) ?? Leg()
        caffeine = try? c.decodeIfPresent(Caffeine.self, forKey: .caffeine)
        avoid = (try? c.decodeIfPresent(String.self, forKey: .avoid)) ?? ""
    }

    var isEmpty: Bool { swim.isEmpty && bike.isEmpty && run.isEmpty && caffeine == nil && avoid.isEmpty }

    /// Typed text is capped and flattened, and carbs clamped: all of it reaches the coach's
    /// prompt, the calendar and the Watch through the session's fuelling line.
    func sanitized() -> FuelPreferences {
        func clean(_ l: Leg) -> Leg {
            Leg(during: CustomSession.oneLine(l.during, max: Self.maxText),
                before: CustomSession.oneLine(l.before, max: Self.maxText),
                carbsPerHour: l.carbsPerHour.flatMap { Self.carbRange.contains($0) ? $0 : nil })
        }
        return FuelPreferences(swim: clean(swim), bike: clean(bike), run: clean(run), caffeine: caffeine,
                               avoid: CustomSession.oneLine(avoid, max: Self.maxText))
    }

    func leg(for sport: Prescriber.Sport) -> Leg? {
        switch sport {
        case .swim: return swim
        case .bike: return bike
        case .run: return run
        case .lift, .other: return nil
        }
    }

    /// Lines for the coach.
    var coachLines: [String] {
        let f = sanitized()
        var lines: [String] = []
        for (name, leg) in [("Swim", f.swim), ("Bike", f.bike), ("Run", f.run)] where !leg.isEmpty {
            let parts = [leg.before.isEmpty ? nil : "before: \(leg.before)",
                         leg.during.isEmpty ? nil : "during: \(leg.during)",
                         leg.carbsPerHour.map { "gut trained to about \($0) g carbs/h" }].compactMap { $0 }
            lines.append("\(name) fuelling — " + parts.joined(separator: "; ") + ".")
        }
        if let c = f.caffeine { lines.append("Caffeine: \(c.label.lowercased()).") }
        if !f.avoid.isEmpty { lines.append("Avoid: \(f.avoid).") }
        if !lines.isEmpty {
            lines.append("Suggest fuelling with the athlete's own products. Don't push carbs per hour far past what their gut is trained to; build it up across sessions.")
        }
        return lines
    }
}
