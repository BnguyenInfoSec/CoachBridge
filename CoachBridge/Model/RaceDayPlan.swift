import Foundation

/// Race day on one page: how hard to go on each leg, and what to eat when. Built from the
/// athlete's event, FTP and threshold HR, and the fuelling they practised in the build.
///
/// Intensities are the usual coaching guidance for each distance (an Ironman bike at 68–73% of
/// FTP, a 70.3 at 75–80%...). Leg durations are typical age-group times, used only to lay out
/// the fuelling timeline; they're labelled as estimates. Pure, so it's tested.
struct RaceDayPlan: Equatable, Sendable {
    struct Leg: Equatable, Sendable, Identifiable {
        let sport: SessionKind
        let label: String
        /// Typical duration, for laying out fuelling. An estimate.
        let minutes: Int
        let target: String
        let cue: String
        var id: String { label }
    }

    struct FuelStep: Equatable, Sendable, Identifiable {
        /// Minutes from the start of the race; negative is before the gun.
        let at: Int
        let leg: String
        let text: String
        var id: String { "\(at)-\(leg)-\(text)" }
    }

    let raceName: String
    let legs: [Leg]
    let fuel: [FuelStep]
    /// Carbs per hour on the bike (or for the whole race, for single-sport events).
    let carbsPerHour: Int
    let notes: [String]

    var totalMinutes: Int { legs.reduce(0) { $0 + $1.minutes } }

    /// The gut-trained rate from the build phase (80–90 g/h), at its lower end: race nerves
    /// make the top of the range harder to hold than in training.
    static let raceCarbsPerHour = 80

    static func make(event: EventKind, raceName: String, ftp: Int?, lthr: Int?) -> RaceDayPlan? {
        func watts(_ lo: Double, _ hi: Double) -> String {
            ftp.map { "\(Int((Double($0) * lo).rounded()))–\(Int((Double($0) * hi).rounded())) W (\(Int(lo * 100))–\(Int(hi * 100))% of FTP)" }
                ?? "\(Int(lo * 100))–\(Int(hi * 100))% of FTP — add your FTP in Plan settings for watts"
        }
        func bpm(_ lo: Double, _ hi: Double) -> String {
            lthr.map { "\(Int((Double($0) * lo).rounded()))–\(Int((Double($0) * hi).rounded())) bpm" }
                ?? "\(Int(lo * 100))–\(Int(hi * 100))% of threshold HR — add your LTHR for bpm"
        }
        let swimCue = "Start wide and easy, sight every 6–8 strokes, find feet. No heroics in the first 200 m."

        let legs: [Leg]
        switch event {
        case .ironman:
            legs = [Leg(sport: .swim, label: "Swim 3.8 km", minutes: 80, target: "Steady, all-day effort", cue: swimCue),
                    Leg(sport: .bike, label: "Bike 180 km", minutes: 390, target: watts(0.68, 0.73),
                        cue: "Cap the climbs. If it feels like work in the first hour, it's too hard."),
                    Leg(sport: .run, label: "Run 42.2 km", minutes: 300, target: bpm(0.80, 0.87),
                        cue: "First 10 km should feel too easy. Walk the aid stations from the start.")]
        case .half703:
            legs = [Leg(sport: .swim, label: "Swim 1.9 km", minutes: 40, target: "Steady, controlled", cue: swimCue),
                    Leg(sport: .bike, label: "Bike 90 km", minutes: 180, target: watts(0.75, 0.80),
                        cue: "Even power; spin up the last 10 minutes to ready the legs."),
                    Leg(sport: .run, label: "Run 21.1 km", minutes: 135, target: bpm(0.87, 0.92),
                        cue: "Settle in the first 3 km, then hold. Build only in the last 5 km.")]
        case .olympic:
            legs = [Leg(sport: .swim, label: "Swim 1.5 km", minutes: 30, target: "Strong, sustainable", cue: swimCue),
                    Leg(sport: .bike, label: "Bike 40 km", minutes: 75, target: watts(0.85, 0.90), cue: "Comfortably hard; no surges."),
                    Leg(sport: .run, label: "Run 10 km", minutes: 55, target: bpm(0.92, 0.97), cue: "Build every 2.5 km.")]
        case .sprintTri:
            legs = [Leg(sport: .swim, label: "Swim 750 m", minutes: 15, target: "Hard but controlled", cue: swimCue),
                    Leg(sport: .bike, label: "Bike 20 km", minutes: 40, target: watts(0.90, 0.95), cue: "Race it."),
                    Leg(sport: .run, label: "Run 5 km", minutes: 25, target: bpm(0.95, 1.00), cue: "Hold on, then empty it.")]
        case .marathon:
            legs = [Leg(sport: .run, label: "Marathon", minutes: 255, target: bpm(0.85, 0.90),
                        cue: "Even pace to 30 km. The race starts at 32.")]
        case .halfMarathon:
            legs = [Leg(sport: .run, label: "Half marathon", minutes: 120, target: bpm(0.90, 0.95), cue: "Even effort; build the last 5 km.")]
        case .tenK:
            legs = [Leg(sport: .run, label: "10 km", minutes: 55, target: bpm(0.95, 1.00), cue: "Controlled first half, strong second.")]
        case .ultra:
            legs = [Leg(sport: .run, label: "Ultra", minutes: 360, target: bpm(0.75, 0.83), cue: "Walk the climbs from the start. Eat before you're hungry.")]
        case .granFondo, .century:
            legs = [Leg(sport: .bike, label: event == .century ? "Century (160 km)" : "Gran fondo", minutes: event == .century ? 360 : 300,
                        target: watts(0.65, 0.75), cue: "Ride your watts, not the group's.")]
        case .general:
            return nil
        }

        let rate = raceCarbsPerHour
        var fuel: [FuelStep] = [
            FuelStep(at: -180, leg: "Before", text: "Breakfast you've practised: 100–150 g carbs, low fibre, plus 500 ml fluid."),
        ]
        let total = legs.reduce(0) { $0 + $1.minutes }
        if total >= 75 {
            fuel.append(FuelStep(at: -15, leg: "Before", text: "One gel (~25 g) with a few sips of water."))
        }
        var clock = 0
        for leg in legs {
            switch leg.sport {
            case .bike where leg.minutes >= 60:
                // Every 20 minutes from 20 in, and a savory bite each hour — what the build rehearsed.
                for m in stride(from: 20, to: leg.minutes - 10, by: 20) {
                    let hourMark = m % 60 == 0
                    fuel.append(FuelStep(at: clock + m, leg: leg.label,
                                         text: "~\(rate / 3) g carbs" + (hourMark ? " + one savory bite; 500–800 mg sodium this hour" : "")))
                }
            case .run where leg.minutes >= 60:
                for m in stride(from: 20, to: leg.minutes - 5, by: 20) {
                    fuel.append(FuelStep(at: clock + m, leg: leg.label, text: "~20 g carbs at the aid station (gel or cola), water on top"))
                }
            case .run, .bike:
                if leg.minutes >= 40 { fuel.append(FuelStep(at: clock + leg.minutes / 2, leg: leg.label, text: "Water; a gel if it's hot")) }
            default:
                break
            }
            clock += leg.minutes
        }

        var notes = ["Nothing new on race day — only foods and drinks you've trained with."]
        if legs.contains(where: { $0.sport == .bike && $0.minutes >= 120 }) {
            notes.append("Fluid 500–750 ml per hour on the bike, more in heat; add ~250 ml per hour above ~90°F.")
        }
        notes.append("Durations are typical finish times, used to lay out the timeline. Go by the clock on your watch.")
        return RaceDayPlan(raceName: raceName, legs: legs, fuel: fuel.sorted { $0.at < $1.at },
                           carbsPerHour: rate, notes: notes)
    }
}
