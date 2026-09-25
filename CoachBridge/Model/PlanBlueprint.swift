import Foundation

/// Turns an `AthleteProfile` into the thing the calendar runs on: phases with real dates, a
/// weekly hour target that ramps, and a week template per phase built around the days that
/// person actually has. Pure — no dates from `.now`, no storage — so it's unit-tested.
struct PlanBlueprint: Sendable, Equatable {
    let startISO: String
    let endISO: String
    let raceISO: String
    let raceName: String
    let phases: [PlanPhase]
    /// Hours a week at the midpoint of each phase, by phase id.
    let hoursByPhase: [String: ClosedRange<Double>]
    let profile: AthleteProfile

    var hasEvent: Bool { !profile.eventDateISO.isEmpty }

    // MARK: Building

    static func make(_ profile: AthleteProfile, calendar: Calendar = .current) -> PlanBlueprint {
        let start = AthleteProfile.date(profile.startDate, calendar: calendar)
        let endISO = profile.endDate(calendar: calendar)
        let end = AthleteProfile.date(endISO, calendar: calendar)
        let totalWeeks = max(4, weeks(from: start, to: end, calendar: calendar))

        let lengths = blockLengths(profile, totalWeeks: totalWeeks)
        let peak = profile.peakHours
        let now = profile.currentWeeklyHours

        var phases: [PlanPhase] = []
        var hours: [String: ClosedRange<Double>] = [:]
        // Lay the blocks backward from the end so the taper finishes on race day. Laid forward from
        // the start, whole weeks rarely divide the runway: the taper ended the day before the race
        // or ran up to six days past it. The first phase absorbs the odd days instead.
        var cursor = calendar.date(byAdding: .day, value: -(totalWeeks * 7 - 1), to: end) ?? start
        for (id, weekCount) in lengths where weekCount > 0 {
            let phaseStart = cursor
            let phaseEnd = calendar.date(byAdding: .day, value: weekCount * 7 - 1, to: phaseStart) ?? phaseStart
            cursor = calendar.date(byAdding: .day, value: weekCount * 7, to: phaseStart) ?? phaseEnd
            // Only a runway under the 4-week minimum can put a whole phase before the start.
            guard phaseEnd >= start else { continue }
            let span = hourRange(id: id, current: now, peak: peak)
            hours[id] = span
            phases.append(PlanPhase(
                id: id,
                name: name(id),
                short: short(id),
                start: AthleteProfile.iso(phases.isEmpty ? start : phaseStart, calendar: calendar),
                end: AthleteProfile.iso(phaseEnd, calendar: calendar),
                hours: hoursLabel(span),
                goal: goal(id, profile),
                focus: focus(id, profile)))
        }

        // The plan ends on race day, or at the end of the last phase when there's no race.
        let lastEnd = phases.last?.end ?? endISO
        return PlanBlueprint(
            startISO: AthleteProfile.iso(start, calendar: calendar),
            endISO: max(lastEnd, endISO),
            raceISO: endISO,
            raceName: profile.eventName.isEmpty ? profile.eventKind.label : profile.eventName,
            phases: phases,
            hoursByPhase: hours,
            profile: profile)
    }

    /// The five training blocks, in order.
    static let blockOrder = ["rec", "b1", "b2", "build", "taper"]

    /// Suggested weeks per block for a given runway, before the athlete's own overrides.
    static func suggestedBlocks(_ p: AthleteProfile, totalWeeks: Int) -> [String: Int] {
        // Taper is fixed by the event; the rest of the runway splits by proportion. A short plan
        // gets no recovery block and a thin base — there simply isn't time for one.
        let taper = min(p.eventKind.taperWeeks, max(1, totalWeeks / 4))
        var remaining = totalWeeks - taper
        let recovery = totalWeeks > 20 ? max(1, Int(Double(remaining) * 0.07)) : 0
        remaining -= recovery
        let build = max(2, Int(Double(remaining) * 0.36))
        let base2 = max(1, Int(Double(remaining) * 0.28))
        let base1 = max(1, remaining - build - base2)
        return ["rec": recovery, "b1": base1, "b2": base2, "build": build, "taper": taper]
    }

    /// Suggestions with the athlete's overrides applied, then fitted to the runway. Spare weeks
    /// go into Base 1. A shortfall is cut in the order a coach would cut it: the easy weeks up
    /// front, then general base, then Base 2, and only then Build — the race-specific block is
    /// worth more than the weeks that feed it. The taper is cut only if nothing else is left.
    static let cutOrder = ["rec", "b1", "b2", "build", "taper"]

    static func blockLengths(_ p: AthleteProfile, totalWeeks: Int) -> [(String, Int)] {
        var out = suggestedBlocks(p, totalWeeks: totalWeeks)
        if let overrides = p.blockWeeks {
            for (k, v) in overrides where out[k] != nil {
                out[k] = max(0, min(v, totalWeeks))
            }
        }
        var diff = totalWeeks - out.values.reduce(0, +)
        if diff > 0 {
            out["b1"]! += diff
        } else {
            // Two passes: the first leaves a week in every block that has one, so a heavy
            // over-ask thins the plan rather than deleting blocks. The second only runs when
            // the runway is shorter than one week per block, and takes blocks down to nothing.
            for floorPass in [1, 0] {
                for key in cutOrder where diff < 0 {
                    let floor = key == "rec" ? 0 : floorPass
                    let take = min(-diff, max(0, out[key]! - floor))
                    out[key]! -= take
                    diff += take
                }
            }
        }
        return blockOrder.map { ($0, out[$0] ?? 0) }
    }

    static func blockName(_ id: String) -> String { name(id) }

    /// Weeks between the plan's start and the event — the runway every block has to fit into.
    static func totalWeeks(_ p: AthleteProfile, calendar: Calendar = .current) -> Int {
        let start = AthleteProfile.date(p.startDate, calendar: calendar)
        let end = AthleteProfile.date(p.endDate(calendar: calendar), calendar: calendar)
        return max(4, weeks(from: start, to: end, calendar: calendar))
    }

    /// One line on what a block is for, shown next to its stepper.
    static func blockBlurb(_ id: String) -> String {
        switch id {
        case "rec": return "Easy weeks up front — come in fresh rather than already tired."
        case "b1": return "Aerobic base. Long and steady, technique work, no hard efforts."
        case "b2": return "More of the same with tempo added, and the volume climbing."
        case "build": return "Race-specific intensity at peak hours. The hardest block."
        default: return "Volume drops, sharpness stays. Ends on race day."
        }
    }

    private static func weeks(from a: Date, to b: Date, calendar: Calendar) -> Int {
        let days = calendar.dateComponents([.day], from: a, to: b).day ?? 0
        return max(1, Int((Double(days) / 7).rounded(.up)))
    }

    /// Volume by phase: recovery sits well under current load, base builds toward it, the build
    /// block reaches the peak, taper comes back down.
    private static func hourRange(id: String, current: Double, peak: Double) -> ClosedRange<Double> {
        let lo: Double
        let hi: Double
        switch id {
        case "rec":
            lo = 0
            hi = max(1, current * 0.6)
        case "b1":
            lo = max(1, current * 0.85)
            hi = max(2, (current + peak) / 2 * 0.8)
        case "b2":
            lo = max(2, (current + peak) / 2 * 0.8)
            hi = max(3, peak * 0.75)
        case "build":
            lo = max(3, peak * 0.75)
            hi = peak
        default:
            lo = max(2, peak * 0.45)
            hi = max(3, peak * 0.75)
        }
        // The bounds are derived, so they can cross when the peak is close to (or below) what
        // the athlete already does — current 4 h, peak 4.5 h gives 3.4…3.375 for Base 2, and
        // a ClosedRange with lowerBound > upperBound traps at runtime. Order them instead.
        return min(lo, hi)...max(lo, hi)
    }

    private static func hoursLabel(_ r: ClosedRange<Double>) -> String {
        func f(_ v: Double) -> String {
            v == v.rounded() ? String(Int(v)) : String(format: "%.1f", v)
        }
        return r.lowerBound == r.upperBound ? "\(f(r.lowerBound)) h" : "\(f(r.lowerBound)) → \(f(r.upperBound)) h"
    }

    private static func name(_ id: String) -> String {
        switch id {
        case "rec": return "Recovery"
        case "b1": return "Base 1"
        case "b2": return "Base 2"
        case "build": return "Build"
        default: return "Taper"
        }
    }

    private static func short(_ id: String) -> String {
        switch id {
        case "rec": return "Rec"
        case "b1": return "Base 1"
        case "b2": return "Base 2"
        case "build": return "Build"
        default: return "Taper"
        }
    }

    private static func goal(_ id: String, _ p: AthleteProfile) -> String {
        switch id {
        case "rec": return "Arrive at the start of the plan rested. Nothing structured, nothing hard."
        case "b1": return "Build the habit and the base. Measure where the engine is now."
        case "b2": return "Raise the ceiling: more volume, and one honest quality session a week."
        case "build": return "The volume block — this is where \(p.eventKind.label.lowercased()) fitness is made."
        default: return "Arrive fresh, not fit-and-flat."
        }
    }

    private static func focus(_ id: String, _ p: AthleteProfile) -> String {
        let longSport = p.eventKind.longSessionSports.first ?? .run
        switch id {
        case "rec":
            return "Move because you want to. Walks count. Lifting comes back light — two sets, nothing near failure."
        case "b1":
            return p.hasTrainer || p.sports.contains(.bike)
                ? "FTP test in week one, so every bike target after it is real watts. Long \(longSport.label.lowercased()) grows gradually."
                : "Set a baseline in week one. Long \(longSport.label.lowercased()) grows gradually; everything else stays easy."
        case "b2":
            return "One quality session a week alongside the long day. Keep the rest genuinely easy — that's what makes the hard part work."
        case "build":
            return "Every weekend is a long weekend, with a recovery week every fourth. Practise race-day fuelling on every long session."
        default:
            return "Volume drops to roughly 75%, then 55%, then race week. Keep a little intensity so you don't go flat."
        }
    }

    // MARK: Lookups

    func phase(for iso: String) -> PlanPhase {
        if let p = phases.first(where: { iso >= $0.start && iso <= $0.end }) { return p }
        return iso < startISO ? (phases.first ?? Self.fallbackPhase) : (phases.last ?? Self.fallbackPhase)
    }

    static let fallbackPhase = PlanPhase(id: "b1", name: "Base 1", short: "Base 1",
                                         start: "1970-01-01", end: "2099-12-31", hours: "—",
                                         goal: "Build the habit.", focus: "Keep it easy and regular.")

    /// Milestones generated from the plan's own shape, rather than written out by hand.
    var milestones: [Milestone] {
        var out: [Milestone] = []
        if let first = phases.first(where: { $0.id == "b1" }) {
            out.append(Milestone(date: first.start, when: "Week one",
                                 title: profile.sports.contains(.bike) ? "FTP test" : "Set your baseline",
                                 detail: profile.sports.contains(.bike)
                                    ? "20-minute test. Every bike target for the next months hangs off this number — put it in Plan settings."
                                    : "A steady effort you can repeat later to see whether the plan is working.",
                                 kind: .test))
        }
        for p in phases where p.id != "rec" {
            out.append(Milestone(date: p.start, when: p.name, title: "\(p.name) starts",
                                 detail: p.goal, kind: .check))
        }
        if hasEvent {
            // The athlete's own words for what a good day looks like, shown on race day itself.
            let want = profile.goal.trimmingCharacters(in: .whitespacesAndNewlines)
            out.append(Milestone(date: raceISO, when: "Race day", title: raceName,
                                 detail: want.isEmpty ? "Everything in the plan points here." : want,
                                 kind: .race))
        }
        return out.sorted { $0.date < $1.date }
    }
}

// MARK: - Week generation

/// Builds one week of sessions for a profile and phase. Pure and separately testable: given the
/// same inputs it always returns the same week, which is what makes the calendar stable.
enum WeekBuilder {
    /// Monday-first, seven entries.
    static func week(blueprint: PlanBlueprint, phase: PlanPhase, weekIndex: Int,
                     isRecoveryWeek: Bool) -> [[PlanSession]] {
        let p = blueprint.profile
        let span = blueprint.hoursByPhase[phase.id] ?? 3...6
        // Where this week sits inside its phase decides how much of the ramp it gets.
        let hours = span.lowerBound + (span.upperBound - span.lowerBound) * rampFraction(weekIndex)
        let minutes = Int(hours * 60 * (isRecoveryWeek ? 0.65 : 1))

        var days: [[PlanSession]] = Array(repeating: [], count: 7)
        let available = Set(p.availableDays.map(index))
        var free = (0..<7).filter { available.contains($0) }

        // Rest days first, so nothing gets placed on a day that doesn't exist for this athlete.
        for i in 0..<7 where !available.contains(i) {
            days[i] = [PlanSession(kind: .rest, title: "Off", detail: "Not a training day")]
        }
        guard !free.isEmpty else { return days }

        if phase.id == "rec" {
            return recoveryWeek(days: &days, free: free, p: p, minutes: minutes)
        }

        // 1. The long session, on the athlete's long day.
        let longIdx = free.contains(index(p.longDay)) ? index(p.longDay) : free[free.count - 1]
        let longSports = p.eventKind.longSessionSports.filter { p.sports.contains($0) }
        let longSport = longSports.isEmpty ? (p.sports.first ?? .run)
            : longSports[weekIndex % longSports.count]
        let longMin = scaled(p.eventKind.peakLongMinutes, phase: phase.id, ramp: rampFraction(weekIndex),
                             recovery: isRecoveryWeek)
        days[longIdx] = [session(longSport, long: true, minutes: longMin, p: p)]
        free.removeAll { $0 == longIdx }

        // A brick run off a long ride is the point of triathlon; keep it short and in the plan.
        if p.eventKind.isTriathlon, longSport == .bike, p.sports.contains(.run), phase.id != "taper" {
            days[longIdx].append(PlanSession(kind: .run, title: "Brick run",
                                             detail: "\(max(10, longMin / 9)) min off the bike, easy"))
        }

        // 2. Second long session, adjacent to the first where possible.
        var used = longMin
        if p.sports.count > 1, let secondIdx = neighbour(of: longIdx, in: free) {
            let second = p.sports.first { $0 != longSport && $0 != .lift } ?? longSport
            let mins = max(30, Int(Double(longMin) * 0.45))
            days[secondIdx] = [session(second, long: false, minutes: mins, p: p, key: false)]
            free.removeAll { $0 == secondIdx }
            used += mins
        }

        // 3. One quality session midweek, once there's a base to hang it on.
        if phase.id != "b1" || weekIndex > 3, let keyIdx = midweek(free) {
            let keySport = p.sports.first { $0 != .lift } ?? .run
            let mins = max(35, Int(Double(minutes) * 0.16))
            days[keyIdx] = [session(keySport, long: false, minutes: mins, p: p, key: true)]
            free.removeAll { $0 == keyIdx }
            used += mins
        }

        // 4. Everything else: easy sessions round-robin through the remaining sports, then lifts.
        var queue: [SessionKind] = []
        let easySports = p.sports.filter { $0 != .lift }
        if !easySports.isEmpty {
            for i in 0..<max(0, free.count - min(p.liftsPerWeek, free.count)) {
                queue.append(easySports[i % easySports.count])
            }
        }
        queue.append(contentsOf: Array(repeating: SessionKind.lift, count: min(p.liftsPerWeek, free.count)))

        let leftover = max(0, minutes - used)
        let each = queue.isEmpty ? 0 : max(25, leftover / max(1, queue.count))
        for (i, day) in free.sorted().enumerated() {
            guard i < queue.count else {
                days[day] = [PlanSession(kind: .rest, title: "Off", detail: "Recovery is training too")]
                continue
            }
            let kind = queue[i]
            days[day] = [session(kind, long: false, minutes: kind == .lift ? 45 : each, p: p)]
        }

        // 5. Commitments: an evening class makes that day a rest evening, not a squeezed session.
        return days
    }

    /// Easier weeks at the start of a phase, fuller ones by the end; every fourth week eases off.
    static func rampFraction(_ weekIndex: Int) -> Double {
        let cycle = weekIndex % 4
        // A recovery week is 70% of the week before it, not of its own spot on the ramp: early in
        // the plan the ramp climbs fast enough that 70% of week 3 (0.175) out-loaded week 2 (0.167).
        guard cycle == 3 else { return min(1, Double(weekIndex) / 12) }
        return min(1, Double(weekIndex - 1) / 12) * 0.7
    }

    static func isRecoveryWeek(_ weekIndex: Int) -> Bool { weekIndex % 4 == 3 }

    private static func scaled(_ peak: Int, phase: String, ramp: Double, recovery: Bool) -> Int {
        let factor: Double
        switch phase {
        case "b1": factor = 0.35 + 0.20 * ramp
        case "b2": factor = 0.55 + 0.20 * ramp
        case "build": factor = 0.75 + 0.25 * ramp
        case "taper": factor = 0.45
        default: factor = 0.3
        }
        return max(30, Int(Double(peak) * factor * (recovery ? 0.7 : 1)))
    }

    private static func recoveryWeek(days: inout [[PlanSession]], free: [Int],
                                     p: AthleteProfile, minutes: Int) -> [[PlanSession]] {
        let sports = p.sports.filter { $0 != .lift }
        for (i, day) in free.sorted().enumerated() {
            if i % 2 == 1 || sports.isEmpty {
                days[day] = [PlanSession(kind: .rest, title: "Off", detail: "Walk, eat, sleep")]
            } else {
                let kind = sports[(i / 2) % sports.count]
                days[day] = [PlanSession(kind: .flex, title: "Optional easy \(kind.label.lowercased())",
                                         detail: "\(max(20, minutes / 6)) min, no numbers")]
            }
        }
        return days
    }

    /// 0 = Sun … 6 = Sat  →  Monday-first index.
    static func index(_ jsDay: Int) -> Int { (jsDay + 6) % 7 }

    private static func neighbour(of i: Int, in free: [Int]) -> Int? {
        for candidate in [i - 1, i + 1] where free.contains(candidate) { return candidate }
        return free.last
    }

    private static func midweek(_ free: [Int]) -> Int? {
        free.first { (1...3).contains($0) } ?? free.first
    }

    /// Titles use the same vocabulary the Prescriber classifies on ("Long", "Key", "Easy",
    /// "Sweet spot"), and details carry the volume in a form it can parse.
    private static func session(_ kind: SessionKind, long: Bool, minutes: Int,
                                p: AthleteProfile, key: Bool = false) -> PlanSession {
        let mins = max(20, minutes)
        let volume = mins >= 120 ? String(format: "%d:%02d", mins / 60, mins % 60) + " h" : "\(mins) min"
        switch kind {
        case .lift:
            return PlanSession(kind: .lift, title: "Lift",
                               detail: "\(mins) min — compound lifts, leave two reps in the tank")
        case .swim:
            let yards = max(800, Int(Double(mins) / 2.2) * 100)
            return PlanSession(kind: .swim, title: long ? "Long swim" : (key ? "Swim set" : "Easy swim"),
                               detail: "\(yards.formatted()) yd" + (key ? " with 8×100 steady" : ", relaxed"))
        case .bike:
            if long { return PlanSession(kind: .bike, title: "Long ride", detail: "\(volume), steady and fuelled") }
            if key {
                return PlanSession(kind: .bike, title: "Sweet spot",
                                   detail: "\(volume): 3×12 → 2×20 at 88–93% FTP",
                                   indoor: p.hasTrainer ? true : nil)
            }
            return PlanSession(kind: .bike, title: "Easy ride", detail: "\(volume), conversational")
        case .run:
            if long { return PlanSession(kind: .run, title: "Long run", detail: "\(volume), easy the whole way") }
            if key { return PlanSession(kind: .run, title: "Key run", detail: "\(volume), last third steady") }
            return PlanSession(kind: .run, title: "Easy run", detail: "\(volume), conversational")
        default:
            return PlanSession(kind: kind, title: kind.label, detail: volume)
        }
    }
}
