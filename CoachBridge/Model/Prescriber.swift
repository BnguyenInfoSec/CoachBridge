import Foundation

/// Turns a plan session into concrete targets and fueling using the coach page's rules:
/// progressions ("40 → 60 min") are interpolated across the phase, zones come from FTP / LTHR
/// when set, and fueling follows the page's gut-training table.
struct Prescriber: Sendable {
    let engine: PlanEngine

    enum Sport: Equatable { case swim, bike, run, lift, other }
    enum Effort: Equatable { case recovery, easy, steady, sweetSpot, imPace, strength, none }

    /// Easy run pace (min/mi) used only to estimate duration from miles; ~12:00 at the 70.3.
    static let easyRunPace = 11.5
    /// Easy swim pace (min per 100 yd), used to estimate duration from yards.
    static let easySwimPer100 = 2.2

    func prescribe(_ s: PlanSession, on day: Date) -> PlanSession {
        var out = s
        if out.rx == nil { out.rx = prescription(for: s, on: day) }
        return out
    }

    func prescription(for s: PlanSession, on day: Date) -> Prescription? {
        // Snowboarding: bursts on the way down, rest on the lift. Zones don't describe it.
        if s.kind == .snow {
            return Prescription(intensity: "Mixed: short hard efforts on the descents, easy on the lift. Counts as leg strength, not endurance",
                                fuelDuring: "Eat before you're cold: a proper lunch, a snack mid-afternoon, water at every stop (altitude dries you out)",
                                notes: "Quads take the load. Keep the next day's run or bike easy unless the legs feel fresh.")
        }
        // Heart-rate zones and ride fuelling mean nothing on a golf course; say what does.
        if s.kind == .golf {
            return Prescription(intensity: "Easy: walking 18 holes is a few hours of low aerobic work; riding a cart isn't training",
                                fuelDuring: "Water every few holes and a snack at the turn, more in the heat",
                                notes: "Counts toward the week's time on your feet. Keep the next morning's session as planned unless the round ran long in the heat.")
        }
        let sport = Self.sport(of: s)
        let effort = Self.effort(of: s, sport: sport)
        if s.kind == .rest || s.kind == .fun && sport == .other {
            return s.kind == .rest
                ? Prescription(intensity: "Rest", fuelDuring: nil, fuelAfter: "Normal meals; hit 125–155 g protein today.")
                : nil
        }
        let q = Self.parseVolume(s.detail, fraction: phaseFraction(day), sport: sport)
        let indoor = s.indoor == true
        var rx = Prescription()
        rx.durationMin = q.minutes
        rx.distance = indoor ? nil : q.distance
        rx.intensity = indoor
            ? intensityText(effort, sport: sport, kind: s.kind) + " · on the trainer (ERG holds the watts; steady cadence 85–95)"
            : intensityText(effort, sport: sport, kind: s.kind)
        rx.heartRate = heartRate(effort, sport: sport)
        rx.power = sport == .bike ? power(effort) : nil
        if sport == .run { rx.pace = paceText(effort) }
        let fuel = fueling(minutes: q.minutes, effort: effort, sport: sport, kind: s.kind, day: day)
        rx.fuelBefore = fuel.before
        rx.fuelDuring = fuel.during
        rx.fuelAfter = fuel.after
        if s.kind == .flex { rx.notes = "Bonus session. Skip it without guilt if life or legs say no." }
        if indoor {
            rx.notes = [rx.notes, "Indoor: fan on, towel, and about 25% more fluid than the same ride outside — you sweat more with no wind."]
                .compactMap { $0 }.joined(separator: " ")
            if engine.settings.ftpWatts == nil {
                rx.notes = (rx.notes ?? "") + " Add FTP in Plan settings so the trainer targets are real watts."
            }
        }
        return rx
    }

    // MARK: Classification

    static func sport(of s: PlanSession) -> Sport {
        switch s.kind {
        case .swim: return .swim
        case .bike: return .bike
        case .run: return .run
        case .lift: return .lift
        // Explicit, not guessed from the title: "Golf, riding the cart" would otherwise read as a
        // bike, and "Snowboard — a few runs" as a run.
        case .golf, .snow: return .other
        default:
            let t = s.title.lowercased()
            if t.contains("swim") { return .swim }
            if t.contains("spin") || t.contains("ride") || t.contains("bike") { return .bike }
            if t.contains("run") { return .run }
            return .other
        }
    }

    static func effort(of s: PlanSession, sport: Sport) -> Effort {
        let text = (s.title + " " + s.detail).lowercased()
        if sport == .lift { return .strength }
        if s.kind == .rest { return .none }
        if text.contains("sweet spot") { return .sweetSpot }
        if text.contains("im-pace") || text.contains("im pace") || text.contains("im effort") || text.contains("race pace") { return .imPace }
        if text.contains("steady") && s.title.lowercased().contains("key") { return .steady }
        if text.contains("walk break") || text.contains("mobility") || text.contains("coffee") || text.contains("float") { return .recovery }
        return .easy
    }

    func phaseFraction(_ day: Date) -> Double {
        let ph = engine.phase(for: day)
        let start = engine.date(ph.start), end = engine.date(ph.end)
        let total = max(1, engine.calendar.dateComponents([.day], from: start, to: end).day ?? 1)
        let done = engine.calendar.dateComponents([.day], from: start, to: day).day ?? 0
        return min(1, max(0, Double(done) / Double(total)))
    }

    // MARK: Volume parsing

    struct Volume: Equatable { var minutes: Int?; var distance: String? }

    /// Reads the leading volume from a session detail: "40 → 60 min", "2:00 → 3:00 + 10-min run off",
    /// "9 → 12 mi, easy", "1,500–2,000 yd", "75 min → 2:45". "→" is a progression across the phase
    /// (interpolated by `fraction`), "–" is a range (midpoint).
    static func parseVolume(_ detail: String, fraction: Double, sport: Sport) -> Volume {
        // Only the leading clause: stop at "+", "(", ", " or ": ".
        var head = detail
        for stop in [" + ", "(", ", ", ": "] {
            if let r = head.range(of: stop) { head = String(head[..<r.lowerBound]) }
        }
        let pattern = #"(\d{1,2}):(\d{2})|(\d{1,3}(?:,\d{3})*(?:\.\d+)?)\s*(min|mi|yd|h)?"#
        guard let re = try? NSRegularExpression(pattern: pattern) else { return Volume() }
        let ns = head as NSString
        var values: [(v: Double, unit: String?)] = []
        for m in re.matches(in: head, range: NSRange(location: 0, length: ns.length)) {
            if m.range(at: 1).location != NSNotFound {
                let h = Double(ns.substring(with: m.range(at: 1))) ?? 0
                let mm = Double(ns.substring(with: m.range(at: 2))) ?? 0
                values.append((h * 60 + mm, "min"))
            } else {
                let raw = ns.substring(with: m.range(at: 3)).replacingOccurrences(of: ",", with: "")
                let unit = m.range(at: 4).location != NSNotFound ? ns.substring(with: m.range(at: 4)) : nil
                values.append((Double(raw) ?? 0, unit))
            }
        }
        guard !values.isEmpty else { return Volume() }
        // Unitless numbers take the next unit that appears ("40 → 60 min").
        var unit: String? = nil
        for i in values.indices.reversed() {
            if let u = values[i].unit { unit = u } else { values[i].unit = unit }
        }
        let first = values[0]
        var amount = first.v
        if values.count >= 2, values[1].unit == first.unit {
            let second = values[1].v
            amount = head.contains("→") ? first.v + (second - first.v) * fraction : (first.v + second) / 2
        }
        switch first.unit {
        case "min": return Volume(minutes: Int(amount.rounded()), distance: nil)
        case "h": return Volume(minutes: Int((amount * 60).rounded()), distance: nil)
        case "mi":
            let mi = (amount * 2).rounded() / 2
            return Volume(minutes: Int((mi * easyRunPace).rounded()), distance: String(format: "%.1f mi", mi))
        case "yd":
            let yd = (amount / 100).rounded() * 100
            return Volume(minutes: Int((yd / 100 * easySwimPer100).rounded()),
                          distance: "\(Int(yd).formatted()) yd")
        default: return Volume()
        }
    }

    // MARK: Targets

    private func intensityText(_ e: Effort, sport: Sport, kind: SessionKind) -> String {
        if kind == .snow { return "Snowboarding — counts as this weekend's long session" }
        if kind == .fun { return "For fun — no pace targets, nothing to make up" }
        switch e {
        case .recovery: return "Very easy — recovery, walk breaks fine"
        case .easy: return sport == .swim ? "Easy aerobic, relaxed form" : "Zone 2 — conversational, could talk in full sentences"
        case .steady: return "Easy, with the last 15–20 min steady (Zone 3)"
        case .sweetSpot: return "Sweet spot intervals at 88–93% FTP, easy spin between"
        case .imPace: return "Mostly Zone 2 with IRONMAN-effort blocks (Zone 2–3)"
        case .strength: return "Strength — leave 1–3 reps in reserve; run first on combined days"
        case .none: return "Rest"
        }
    }

    private func heartRate(_ e: Effort, sport: Sport) -> String? {
        guard sport == .run || sport == .bike else { return nil }
        guard let lthr = engine.settings.lthrBpm else {
            switch e {
            case .recovery, .easy: return "Easy: nose-breathing, full sentences. Add your LTHR in Plan settings for bpm."
            case .steady, .imPace, .sweetSpot: return "Comfortably hard in the work blocks. Add LTHR for bpm."
            default: return nil
            }
        }
        func r(_ lo: Double, _ hi: Double) -> String { "\(Int((Double(lthr) * lo).rounded()))–\(Int((Double(lthr) * hi).rounded())) bpm" }
        switch (e, sport) {
        case (.recovery, _): return "under \(Int((Double(lthr) * (sport == .run ? 0.85 : 0.81)).rounded())) bpm"
        case (.easy, .run): return r(0.85, 0.89) + " (Z2)"
        case (.easy, _): return r(0.81, 0.89) + " (Z2)"
        case (.steady, _), (.imPace, _): return (sport == .run ? r(0.85, 0.89) : r(0.81, 0.89)) + " easy parts · " + r(0.90, 0.94) + " work"
        case (.sweetSpot, _): return r(0.93, 0.97) + " in intervals"
        default: return nil
        }
    }

    private func power(_ e: Effort) -> String? {
        guard let ftp = engine.settings.ftpWatts else {
            return e == .sweetSpot ? "88–93% of FTP. Do the FTP test, then add it in Plan settings." : nil
        }
        func r(_ lo: Double, _ hi: Double) -> String { "\(Int((Double(ftp) * lo).rounded()))–\(Int((Double(ftp) * hi).rounded())) W" }
        switch e {
        case .recovery: return "under \(Int((Double(ftp) * 0.55).rounded())) W"
        case .easy: return r(0.56, 0.75) + " (Z2)"
        case .steady: return r(0.76, 0.87)
        case .imPace: return r(0.56, 0.75) + " · IM blocks " + r(0.68, 0.78)
        case .sweetSpot: return r(0.88, 0.93) + " intervals"
        default: return nil
        }
    }

    private func paceText(_ e: Effort) -> String? {
        switch e {
        case .recovery, .easy: return "Whatever keeps HR easy — likely 11:30–12:30/mi now"
        case .steady: return "Steady finish ~30–45 s/mi faster than easy"
        case .imPace: return "IM segments ~12:00/mi (race-day target)"
        default: return nil
        }
    }

    // MARK: Fueling (from the page's nutrition section)

    private func carbsPerHour(_ day: Date) -> String {
        switch engine.phase(for: day).id {
        case "b2": return "70–80 g"
        case "build": return "80–90 g"
        case "taper": return "60–80 g"
        default: return "60 g"
        }
    }

    private func fueling(minutes: Int?, effort: Effort, sport: Sport, kind: SessionKind, day: Date)
        -> (before: String?, during: String?, after: String?) {
        if sport == .lift {
            return ("Something with carbs 1–2 h before if it's been a while since a meal.",
                    "Water.",
                    "25–40 g protein within an hour. Daily 125–155 g for the growth window.")
        }
        if kind == .snow {
            return ("Big carb breakfast.",
                    "Eat and drink like a long ride: ~60 g carbs/h, salty snacks, fluid every lift.",
                    "Carbs + protein at the end of the day.")
        }
        let m = minutes ?? 45
        let hard = effort == .sweetSpot || effort == .imPace || effort == .steady
        if m >= 90 {
            return ("60–100 g carbs 2–3 h before (oatmeal, bagel, banana) + 500 ml fluid.",
                    "\(carbsPerHour(day)) carbs/h from 20 min in — Bloks + Skratch every 15–20 min, one savory bite each hour (chips, pretzels). 500–800 mg sodium and 500–750 ml fluid per hour.",
                    "Carbs + 25–40 g protein within an hour. Weigh before/after once a month for the sweat test.")
        }
        if m >= 60 || hard {
            return (hard ? "30–60 g carbs 1–2 h before." : "Normal meal 2–3 h before.",
                    sport == .swim ? "Bottle of Skratch on deck." : "Water + electrolytes (Skratch); 20–30 g carbs if it runs long or hard.",
                    hard ? "Carbs + protein within an hour." : "Normal meal.")
        }
        return ("Normal meal 2–3 h before, or nothing if it's early.", "Water.", "Normal meal.")
    }
}
