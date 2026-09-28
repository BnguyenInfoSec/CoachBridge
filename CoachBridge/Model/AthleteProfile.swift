import Foundation

/// What the athlete is training for. The plan's shape — which sports, how much volume, how long
/// the taper — all hangs off this.
enum EventKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case ironman, half703, olympic, sprintTri
    case marathon, halfMarathon, tenK, ultra
    case granFondo, century
    case general

    var id: String { rawValue }

    var label: String {
        switch self {
        case .ironman: return "Full triathlon (140.6)"
        case .half703: return "Half triathlon (70.3)"
        case .olympic: return "Olympic triathlon"
        case .sprintTri: return "Sprint triathlon"
        case .marathon: return "Marathon"
        case .halfMarathon: return "Half marathon"
        case .tenK: return "5K / 10K"
        case .ultra: return "Ultra"
        case .granFondo: return "Gran fondo"
        case .century: return "Century ride"
        case .general: return "General fitness"
        }
    }

    var symbol: String {
        switch self {
        case .ironman, .half703, .olympic, .sprintTri: return "figure.mixed.cardio"
        case .marathon, .halfMarathon, .tenK, .ultra: return "figure.run"
        case .granFondo, .century: return "figure.outdoor.cycle"
        case .general: return "heart.fill"
        }
    }

    /// Which sports the week is built from.
    var sports: [SessionKind] {
        switch self {
        case .ironman, .half703, .olympic, .sprintTri: return [.swim, .bike, .run]
        case .marathon, .halfMarathon, .tenK, .ultra: return [.run, .bike]
        case .granFondo, .century: return [.bike, .run]
        case .general: return [.run, .bike, .lift]
        }
    }

    /// The sport the longest session of the week belongs to, and what it alternates with.
    var longSessionSports: [SessionKind] {
        switch self {
        case .ironman, .half703, .olympic, .sprintTri: return [.bike, .run]
        case .marathon, .halfMarathon, .tenK, .ultra: return [.run]
        case .granFondo, .century: return [.bike]
        case .general: return [.run, .bike]
        }
    }

    /// Weekly hours at the peak of the build, for someone finishing rather than racing for a slot.
    var peakWeeklyHours: Double {
        switch self {
        case .ironman: return 13
        case .half703: return 9
        case .olympic: return 7
        case .sprintTri: return 5.5
        case .ultra: return 10
        case .marathon: return 7
        case .halfMarathon: return 5.5
        case .tenK: return 4.5
        case .granFondo, .century: return 8
        case .general: return 4.5
        }
    }

    /// How long the longest session runs at peak, in minutes.
    var peakLongMinutes: Int {
        switch self {
        case .ironman: return 360
        case .half703: return 240
        case .olympic: return 150
        case .sprintTri: return 100
        case .ultra: return 300
        case .marathon: return 165
        case .halfMarathon: return 110
        case .tenK: return 80
        case .granFondo, .century: return 300
        case .general: return 90
        }
    }

    var taperWeeks: Int {
        switch self {
        case .ironman, .ultra: return 3
        case .half703, .marathon, .granFondo, .century: return 2
        default: return 1
        }
    }

    /// A sensible plan length when the athlete hasn't said when they're starting.
    var typicalWeeks: Int {
        switch self {
        case .ironman: return 36
        case .half703, .ultra: return 24
        case .marathon, .granFondo, .century: return 18
        case .olympic, .halfMarathon: return 14
        case .sprintTri, .tenK: return 10
        case .general: return 12
        }
    }

    var isTriathlon: Bool { sports.contains(.swim) }
}

/// Something that recurs and blocks training: a class, a shift, a standing commitment.
struct Commitment: Codable, Identifiable, Hashable, Sendable {
    var id: UUID = UUID()
    var title: String
    /// 0 = Sun … 6 = Sat.
    var weekdays: [Int]
    var startHour: Int = 18
    var endHour: Int = 20
    /// Last day it applies, "yyyy-MM-dd". nil = indefinitely.
    var untilISO: String?

    func applies(_ iso: String, jsDay: Int) -> Bool {
        guard weekdays.contains(jsDay) else { return false }
        if let untilISO, iso > untilISO { return false }
        return true
    }

    var summary: String {
        let names = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
        let days = weekdays.sorted().map { names[$0] }.joined(separator: "/")
        return "\(title) · \(days) \(startHour):00–\(endHour):00"
    }
}

/// A stretch away from normal training: a holiday, a work trip, a snowboard weekend.
struct Blackout: Codable, Identifiable, Hashable, Sendable {
    enum Mode: String, Codable, CaseIterable, Sendable {
        /// Nothing planned at all.
        case off
        /// Keep it light and flexible — travel, but trainers and hotel gyms exist.
        case easy
        /// Doing a different sport all week (a ski trip is still load).
        case crossTraining

        var label: String {
            switch self {
            case .off: return "Complete rest"
            case .easy: return "Keep it light"
            case .crossTraining: return "Other sport"
            }
        }
    }

    var id: UUID = UUID()
    var title: String
    var startISO: String
    var endISO: String
    var mode: Mode = .easy

    func covers(_ iso: String) -> Bool { iso >= startISO && iso <= endISO }

    var summary: String { "\(title) · \(startISO) → \(endISO) (\(mode.label.lowercased()))" }
}

/// What the athlete actually owns or has access to. Drives what the plan can program: no pool
/// and no open water means no swimming; a trainer means a ride can go indoors.
enum Equipment: String, Codable, CaseIterable, Identifiable, Sendable {
    case roadBike, triBike, gravelBike, mountainBike
    case trainer, powerMeter, cadenceSensor
    case pool, openWater, wetsuit
    case treadmill, gpsWatch, hrStrap
    case gym, homeWeights

    var id: String { rawValue }

    var label: String {
        switch self {
        case .roadBike: return "Road bike"
        case .triBike: return "Tri / TT bike"
        case .gravelBike: return "Gravel bike"
        case .mountainBike: return "Mountain bike"
        case .trainer: return "Indoor trainer"
        case .powerMeter: return "Power meter"
        case .cadenceSensor: return "Cadence sensor"
        case .pool: return "Pool access"
        case .openWater: return "Open water"
        case .wetsuit: return "Wetsuit"
        case .treadmill: return "Treadmill"
        case .gpsWatch: return "GPS watch"
        case .hrStrap: return "Heart-rate strap"
        case .gym: return "Gym"
        case .homeWeights: return "Weights at home"
        }
    }

    var group: String {
        switch self {
        case .roadBike, .triBike, .gravelBike, .mountainBike, .trainer, .powerMeter, .cadenceSensor:
            return "Bike"
        case .pool, .openWater, .wetsuit: return "Swim"
        case .treadmill, .gpsWatch, .hrStrap: return "Run and tracking"
        case .gym, .homeWeights: return "Strength"
        }
    }

    static var groups: [String] { ["Bike", "Swim", "Run and tracking", "Strength"] }

    static func inGroup(_ g: String) -> [Equipment] { allCases.filter { $0.group == g } }

    var isBike: Bool { [.roadBike, .triBike, .gravelBike, .mountainBike].contains(self) }
}

/// A race or event on the athlete's calendar — a tune-up race, a fun run, the goal event itself.
struct AthleteEvent: Codable, Identifiable, Hashable, Sendable {
    var id: UUID = UUID()
    var dateISO: String
    var title: String
    var detail: String = ""
    /// A real race they're targeting, vs. something they're just turning up to.
    var isRace = true
    /// The distance, so the dashboard can project a finish time. Optional: events saved before
    /// v2.10 have none (and the profile must still decode).
    var kind: EventKind? = nil
}

/// Working or school hours, which decide where sessions can be placed.
struct WorkSchedule: Codable, Hashable, Sendable {
    /// 0 = Sun … 6 = Sat.
    var weekdays: [Int] = [1, 2, 3, 4, 5]
    var startHour: Int = 9
    var endHour: Int = 17

    func isWorking(_ jsDay: Int) -> Bool { weekdays.contains(jsDay) }

    var summary: String {
        let names = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
        guard !weekdays.isEmpty else { return "No fixed hours" }
        return "\(weekdays.sorted().map { names[$0] }.joined(separator: "/")) \(startHour):00–\(endHour):00"
    }
}

/// Everything about the athlete that shapes their plan. Replaces what used to be hardcoded to
/// one person's race, schedule and city.
struct AthleteProfile: Codable, Equatable, Sendable {
    // Who
    var name: String = ""

    // What they're training for
    var eventKind: EventKind = .general
    var eventName: String = ""
    /// "yyyy-MM-dd". Empty = no date set; the plan runs `eventKind.typicalWeeks` from the start.
    var eventDateISO: String = ""
    /// What success looks like, in their words: "finish", "sub-13", "get my bike strong enough
    /// that the run isn't a survival march". Goes to the coach with every message.
    var goal: String = ""
    /// When the plan begins. Empty = today.
    var startDateISO: String = ""

    // Capacity
    /// Hours a week they're training now — the plan ramps from here, not from zero.
    var currentWeeklyHours: Double = 4
    /// Hours a week they can realistically give at the peak. nil = use the event's default.
    var maxWeeklyHours: Double?
    /// 0 = Sun … 6 = Sat. Days they can train at all.
    var availableDays: [Int] = [0, 1, 2, 3, 4, 5, 6]
    /// The day the long session goes on.
    var longDay: Int = 6

    // Life
    var work = WorkSchedule()
    /// Weeks per training block, keyed by block id. Anything missing uses the suggested length,
    /// and the total is fitted to the runway. nil = let the app decide all of them.
    var blockWeeks: [String: Int]? = nil

    var commitments: [Commitment] = []
    var blackouts: [Blackout] = []
    /// Races and events along the way. The goal event is `eventDateISO`, not one of these.
    var events: [AthleteEvent] = []

    // Preferences
    var preferredSports: [SessionKind] = []
    var avoidedSports: [SessionKind] = []
    var liftsPerWeek: Int = 2

    /// Kit and access. Replaces the three separate booleans this used to carry.
    var equipment: [String] = []
    /// The specific bike, tires and shoes, for the coach. Optional: the profile decodes all or
    /// nothing, and a load that fails falls back to an empty profile — so a new non-optional
    /// field would silently wipe everyone's setup. Keep new fields optional.
    var gear: Gear? = nil
    /// What the athlete eats and drinks, by sport. Optional for the same reason as `gear`.
    var fuel: FuelPreferences? = nil

    func has(_ e: Equipment) -> Bool { equipment.contains(e.rawValue) }

    mutating func set(_ e: Equipment, _ on: Bool) {
        if on {
            if !has(e) { equipment.append(e.rawValue) }
        } else {
            equipment.removeAll { $0 == e.rawValue }
        }
    }

    var hasPool: Bool { has(.pool) }
    var openWaterAccess: Bool { has(.openWater) }
    var hasTrainer: Bool { has(.trainer) }
    var hasBike: Bool { Equipment.allCases.contains { $0.isBike && has($0) } }

    var equipmentList: [Equipment] { equipment.compactMap(Equipment.init(rawValue:)) }

    /// Free text: everything the coach should know that no field covers. Starts empty — this is
    /// the athlete's canvas, not a form.
    var notes: String = ""

    // MARK: Derived

    /// Falls back to today only for a profile that isn't set up (and demo mode, whose sample plan
    /// is meant to start today). A real profile has its start pinned by `pinningStart` — without
    /// that, the plan restarted every day: today was always week 0, the volume ramp never rose and
    /// recovery weeks slid forward forever.
    var startDate: String {
        startDateISO.isEmpty ? Self.iso(Date()) : startDateISO
    }

    /// The profile with its plan start fixed to `todayISO` if it's complete and has none yet.
    func pinningStart(todayISO: String) -> AthleteProfile {
        guard isComplete, startDateISO.isEmpty else { return self }
        var p = self
        p.startDateISO = todayISO
        return p
    }

    /// The race date, or a sensible horizon when there isn't one.
    func endDate(calendar: Calendar = .current) -> String {
        if !eventDateISO.isEmpty { return eventDateISO }
        let start = Self.date(startDate, calendar: calendar)
        let end = calendar.date(byAdding: .day, value: eventKind.typicalWeeks * 7, to: start) ?? start
        return Self.iso(end, calendar: calendar)
    }

    var peakHours: Double {
        max(currentWeeklyHours, maxWeeklyHours ?? eventKind.peakWeeklyHours)
    }

    /// The sports actually used: the event's, minus anything they've asked to avoid, plus
    /// anything they've asked for.
    var sports: [SessionKind] {
        var list = eventKind.sports.filter { !avoidedSports.contains($0) }
        for s in preferredSports where !list.contains(s) { list.append(s) }
        if eventKind.isTriathlon && !hasPool && !openWaterAccess {
            list.removeAll { $0 == .swim }
        }
        return list.isEmpty ? [.run] : list
    }

    var isComplete: Bool { !eventDateISO.isEmpty || eventKind != .general }

    // MARK: Storage

    static let storageKey = "athlete.profile"

    static func load(_ defaults: UserDefaults = .standard) -> AthleteProfile {
        guard let data = defaults.data(forKey: storageKey),
              let p = try? JSONDecoder().decode(AthleteProfile.self, from: data) else {
            return AthleteProfile()
        }
        return p
    }

    func save(_ defaults: UserDefaults = .standard) {
        var clean = self
        clean.gear = gear.map { $0.sanitized() }.flatMap { $0.isEmpty ? nil : $0 }
        clean.fuel = fuel.map { $0.sanitized() }.flatMap { $0.isEmpty ? nil : $0 }
        if let data = try? JSONEncoder().encode(clean) { defaults.set(data, forKey: Self.storageKey) }
    }

    // MARK: Date helpers (no engine needed — the engine is built *from* this)

    static func iso(_ d: Date, calendar: Calendar = .current) -> String {
        DayRecord.dateKey(for: d, calendar: calendar)
    }

    static func date(_ iso: String, calendar: Calendar = .current) -> Date {
        let p = iso.split(separator: "-").compactMap { Int($0) }
        guard p.count == 3, let d = calendar.date(from: DateComponents(year: p[0], month: p[1], day: p[2])) else {
            return calendar.startOfDay(for: .now)
        }
        return d
    }

    /// Loads the saved profile, and on first run of this version carries an existing install
    /// across: whoever was already using the app was on the IRONMAN California plan, with their
    /// class nights and snowboard weekends in `PlanSettings`. A fresh install gets an empty
    /// profile and the setup questions.
    static func migrated(from settings: PlanSettings, defaults: UserDefaults = .standard) -> AthleteProfile {
        if defaults.data(forKey: storageKey) != nil { return load(defaults) }
        // No profile yet. If there's no saved PlanSettings either, this is a new install.
        guard defaults.data(forKey: PlanSettings.storageKey) != nil else { return AthleteProfile() }

        var p = ironmanCalifornia
        if !settings.classDays.isEmpty {
            p.commitments = [Commitment(title: "Class", weekdays: settings.classDays,
                                        startHour: 18, endHour: 20, untilISO: settings.classUntil)]
        }
        p.blackouts = settings.snowSaturdays.sorted().map { sat in
            Blackout(title: "Snowboarding", startISO: sat,
                     endISO: Self.iso(Calendar.current.date(byAdding: .day, value: 1,
                                                            to: Self.date(sat)) ?? Self.date(sat)),
                     mode: .crossTraining)
        }
        if settings.trainer { p.set(.trainer, true) }
        p.save(defaults)
        return p
    }

    /// The profile that reproduces the original hardcoded plan, used to migrate the first user
    /// and as the worked example in the walkthrough.
    static let ironmanCalifornia: AthleteProfile = {
        var p = AthleteProfile()
        p.eventKind = .ironman
        p.eventName = "IRONMAN California"
        p.eventDateISO = "2027-10-17"
        p.startDateISO = "2026-09-13"
        p.currentWeeklyHours = 3
        p.maxWeeklyHours = 13
        p.longDay = 6
        p.work = WorkSchedule(weekdays: [1, 2, 3, 4, 5], startHour: 9, endHour: 16)
        p.commitments = [Commitment(title: "Class", weekdays: [2, 4], startHour: 18, endHour: 20,
                                    untilISO: "2026-12-18")]
        p.liftsPerWeek = 2
        p.equipment = [Equipment.roadBike, .trainer, .powerMeter, .pool, .openWater,
                       .gym, .gpsWatch].map(\.rawValue)
        p.events = [AthleteEvent(dateISO: "2026-10-18", title: "Diplo's Run Club 5K · San Francisco",
                                 detail: "Fun run with friends — not training, not a race.", isRace: false)]
        return p
    }()
}

/// What the athlete rides and runs in, so the coach can talk about it: which shoes suit which
/// session, what pressure to run, whether the tires are up to a wet descent.
struct Gear: Codable, Equatable, Sendable {
    enum TireSetup: String, Codable, CaseIterable, Identifiable, Sendable {
        case clincher, tubeless, tubular
        var id: String { rawValue }
        var label: String { rawValue.capitalized }
    }

    enum ShoeCategory: String, Codable, CaseIterable, Identifiable, Sendable {
        case superTrainer, maxCushion, dailyTrainer, carbonRacer, stability, trail

        var id: String { rawValue }
        var label: String {
            switch self {
            case .superTrainer: return "Super trainer"
            case .maxCushion: return "Max cushion"
            case .dailyTrainer: return "Daily trainer"
            case .carbonRacer: return "Carbon racer"
            case .stability: return "Stability"
            case .trail: return "Trail"
            }
        }
        /// An example, so the categories mean something to someone who doesn't follow shoe news.
        var example: String {
            switch self {
            case .superTrainer: return "e.g. Adidas Evo SL, ASICS Superblast"
            case .maxCushion: return "e.g. Hoka Bondi, ASICS Nimbus"
            case .dailyTrainer: return "e.g. Nike Pegasus, Brooks Ghost"
            case .carbonRacer: return "e.g. Nike Alphafly, Adidas Adios Pro"
            case .stability: return "e.g. Brooks Adrenaline, ASICS Kayano"
            case .trail: return "e.g. Hoka Speedgoat, Salomon Speedcross"
            }
        }
    }

    struct Shoe: Codable, Equatable, Identifiable, Sendable {
        var id = UUID()
        var category: ShoeCategory
        var model: String = ""
    }

    /// A set of wheels. Most triathletes own two, training and race, and which one goes on the
    /// bike depends on the course and the wind.
    struct Wheelset: Codable, Equatable, Identifiable, Sendable {
        enum Use: String, Codable, CaseIterable, Identifiable, Sendable {
            case training, race, climbing, gravel, trainer
            var id: String { rawValue }
            var label: String {
                switch self {
                case .training: return "Training"
                case .race: return "Race"
                case .climbing: return "Climbing"
                case .gravel: return "Gravel"
                case .trainer: return "Indoor trainer"
                }
            }
        }

        var id = UUID()
        var name: String = ""
        var use: Use = .training
        /// Rim depth. Deep wheels are faster and catch crosswinds.
        var depthMM: Int? = nil
        var internalWidthMM: Int? = nil
        var rim: TirePressure.Rim? = nil

        init(name: String = "", use: Use = .training, depthMM: Int? = nil, internalWidthMM: Int? = nil,
             rim: TirePressure.Rim? = nil) {
            self.name = name
            self.use = use
            self.depthMM = depthMM
            self.internalWidthMM = internalWidthMM
            self.rim = rim
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = (try? c.decodeIfPresent(UUID.self, forKey: .id)) ?? UUID()
            name = (try? c.decodeIfPresent(String.self, forKey: .name)) ?? ""
            use = (try? c.decodeIfPresent(Use.self, forKey: .use)) ?? .training
            depthMM = try? c.decodeIfPresent(Int.self, forKey: .depthMM)
            internalWidthMM = try? c.decodeIfPresent(Int.self, forKey: .internalWidthMM)
            rim = try? c.decodeIfPresent(TirePressure.Rim.self, forKey: .rim)
        }

        /// A disc is stored as the deepest possible rim, so it counts as the most wind-sensitive.
        static let disc = 120

        /// Deep enough that a strong crosswind moves the bike around.
        var isDeep: Bool { (depthMM ?? 0) >= 60 }

        var line: String {
            let what = name.isEmpty ? "\(use.label.lowercased()) wheels" : name
            let facts = [depthMM.map { $0 == Self.disc ? "disc" : "\($0) mm deep" }, internalWidthMM.map { "\($0) mm internal" },
                         rim.map { $0.label.lowercased() }].compactMap { $0 }
            return what + (facts.isEmpty ? "" : " (\(facts.joined(separator: ", ")))") + ", for \(use.label.lowercased())"
        }
    }

    /// Which wheels to fit for an outdoor ride in this wind. Nil when there's no choice to make:
    /// fewer than two outdoor sets, or no forecast.
    func wheelAdvice(gustMph: Double?) -> String? {
        let outdoor = sanitized().wheelsets.filter { $0.use != .trainer }
        guard outdoor.count >= 2, let gust = gustMph else { return nil }
        let shallow = outdoor.filter { !$0.isDeep }.min { ($0.depthMM ?? 0) < ($1.depthMM ?? 0) }
        let deep = outdoor.filter(\.isDeep).max { ($0.depthMM ?? 0) < ($1.depthMM ?? 0) }
        func name(_ w: Wheelset) -> String { w.name.isEmpty ? "your \(w.use.label.lowercased()) wheels" : w.name }
        if gust >= Self.gustyMph, let shallow, let deep {
            return "Gusts to \(Int(gust.rounded())) mph: fit \(name(shallow)) rather than \(name(deep)). Deep rims get pushed around in a crosswind."
        }
        return nil
    }

    /// Where deep rims start to be a handful for most riders.
    static let gustyMph = 20.0

    enum Groupset: String, Codable, CaseIterable, Identifiable, Sendable {
        case duraAceDi2, ultegraDi2, shimano105Di2, shimano105, grxDi2, grx
        case redAXS, forceAXS, forceXPLRAXS, rivalAXS, rivalXPLRAXS, apexAXS, apexXPLRAXS
        case superRecordWireless, chorus
        case other

        var id: String { rawValue }
        var brand: String {
            switch self {
            case .duraAceDi2, .ultegraDi2, .shimano105Di2, .shimano105, .grxDi2, .grx: return "Shimano"
            case .redAXS, .forceAXS, .forceXPLRAXS, .rivalAXS, .rivalXPLRAXS, .apexAXS, .apexXPLRAXS: return "SRAM"
            case .superRecordWireless, .chorus: return "Campagnolo"
            case .other: return "Other"
            }
        }
        var label: String {
            switch self {
            case .duraAceDi2: return "Dura-Ace Di2"
            case .ultegraDi2: return "Ultegra Di2"
            case .shimano105Di2: return "105 Di2"
            case .shimano105: return "105 (mechanical)"
            case .grxDi2: return "GRX Di2"
            case .grx: return "GRX (mechanical)"
            case .redAXS: return "Red AXS"
            case .forceAXS: return "Force AXS"
            case .forceXPLRAXS: return "Force XPLR AXS"
            case .rivalAXS: return "Rival AXS"
            case .rivalXPLRAXS: return "Rival XPLR AXS"
            case .apexAXS: return "Apex AXS"
            case .apexXPLRAXS: return "Apex XPLR AXS"
            case .superRecordWireless: return "Super Record Wireless"
            case .chorus: return "Chorus (mechanical)"
            case .other: return "Something else"
            }
        }
        var isElectronic: Bool { ![.shimano105, .grx, .chorus, .other].contains(self) }
        var batteryNote: String? {
            switch brand {
            case "Shimano" where isElectronic: return "Charge the Di2 battery the day before."
            case "SRAM": return "Charge the AXS derailleur batteries the day before, and pack a spare — they swap between front and rear."
            case "Campagnolo" where isElectronic: return "Charge the groupset the day before."
            default: return nil
            }
        }
        /// XPLR is SRAM's 1× gravel line; the rest are usually run 2×.
        var isOneBy: Bool { self == .forceXPLRAXS || self == .rivalXPLRAXS || self == .apexXPLRAXS }
    }

    var bike: String = ""
    var tires: String = ""
    var tireSetup: TireSetup? = nil
    var shoes: [Shoe] = []
    var groupset: Groupset? = nil
    /// Free text, e.g. "50/34, 11–34" or "42T, 10–44".
    var gearing: String = ""
    // Tire pressure inputs and the athlete's chosen pressures.
    var pressureBike: TirePressure.Bike? = nil
    var tireWidthMM: Int? = nil
    var rim: TirePressure.Rim? = nil
    var riding: TirePressure.Riding? = nil
    /// Only when typed in; otherwise the latest weight from Apple Health is used. Stays on the
    /// phone — it isn't part of what the coach is sent.
    var riderWeightKg: Double? = nil
    var frontPSI: Double? = nil
    var rearPSI: Double? = nil
    /// True once the athlete edits a pressure by hand; until then pressures follow the
    /// recommendation as the inputs change.
    var pressuresCustom: Bool = false
    var wheelsets: [Wheelset] = []

    init(bike: String = "", tires: String = "", tireSetup: TireSetup? = nil, shoes: [Shoe] = [],
         groupset: Groupset? = nil, gearing: String = "") {
        self.bike = bike
        self.tires = tires
        self.tireSetup = tireSetup
        self.shoes = shoes
        self.groupset = groupset
        self.gearing = gearing
    }

    /// Lenient: any field missing (an older save, a field added later) decodes to its default
    /// instead of failing the whole profile.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        bike = (try? c.decodeIfPresent(String.self, forKey: .bike)) ?? ""
        tires = (try? c.decodeIfPresent(String.self, forKey: .tires)) ?? ""
        tireSetup = try? c.decodeIfPresent(TireSetup.self, forKey: .tireSetup)
        shoes = (try? c.decodeIfPresent([Shoe].self, forKey: .shoes)) ?? []
        groupset = try? c.decodeIfPresent(Groupset.self, forKey: .groupset)
        gearing = (try? c.decodeIfPresent(String.self, forKey: .gearing)) ?? ""
        pressureBike = try? c.decodeIfPresent(TirePressure.Bike.self, forKey: .pressureBike)
        tireWidthMM = try? c.decodeIfPresent(Int.self, forKey: .tireWidthMM)
        rim = try? c.decodeIfPresent(TirePressure.Rim.self, forKey: .rim)
        riding = try? c.decodeIfPresent(TirePressure.Riding.self, forKey: .riding)
        riderWeightKg = try? c.decodeIfPresent(Double.self, forKey: .riderWeightKg)
        frontPSI = try? c.decodeIfPresent(Double.self, forKey: .frontPSI)
        rearPSI = try? c.decodeIfPresent(Double.self, forKey: .rearPSI)
        pressuresCustom = (try? c.decodeIfPresent(Bool.self, forKey: .pressuresCustom)) ?? false
        wheelsets = (try? c.decodeIfPresent([Wheelset].self, forKey: .wheelsets)) ?? []
    }

    /// Pressure for one ride: your saved pressures, or the recommendation, adjusted for rain.
    /// Nil for indoor rides (a direct-drive trainer has no rear tire, and it's never wet) and
    /// when there's nothing to go on. `note` explains any adjustment.
    func pressure(forRide s: PlanSession, wet: Bool, riderKg: Double?) -> (front: Double, rear: Double, note: String?)? {
        guard s.kind == .bike || Prescriber.sport(of: s) == .bike, s.indoor != true else { return nil }
        if pressuresCustom, let f = frontPSI, let r = rearPSI {
            // Your own numbers, eased for rain the same way the recommendation would be.
            return wet ? ((f * 0.93).rounded(), (r * 0.93).rounded(), "Rain forecast: about 7% under your usual for grip.")
                       : (f, r, nil)
        }
        var g = self
        if wet { g.riding = .wet }
        guard let rec = g.recommendedPressure(riderKg: riderKg) else {
            if let f = frontPSI, let r = rearPSI { return (f, r, nil) }
            return nil
        }
        return (rec.frontPSI, rec.rearPSI, wet ? "Rain forecast: set for wet roads." : nil)
    }

    /// The recommendation for the current inputs, given a rider weight.
    func recommendedPressure(riderKg: Double?) -> TirePressure.Result? {
        guard let kg = riderWeightKg ?? riderKg else { return nil }
        let bike = pressureBike ?? .road
        return TirePressure.recommend(riderKg: kg, bike: bike, widthMM: tireWidthMM ?? bike.defaultWidth,
                                      setup: tireSetup, rim: rim, riding: riding ?? (bike == .mountain ? .trail : bike == .gravel ? .gravel : .roadTraining))
    }

    var isEmpty: Bool {
        bike.isEmpty && tires.isEmpty && tireSetup == nil && shoes.isEmpty && groupset == nil && gearing.isEmpty
            && tireWidthMM == nil && rim == nil && frontPSI == nil && rearPSI == nil && riderWeightKg == nil
            && wheelsets.isEmpty
    }

    /// Typed text is capped and cleaned: it goes into the coach's prompt.
    func sanitized() -> Gear {
        var g = self
        g.bike = CustomSession.oneLine(bike, max: 80)
        g.tires = CustomSession.oneLine(tires, max: 80)
        g.gearing = CustomSession.oneLine(gearing, max: 40)
        g.tireWidthMM = tireWidthMM.map { min(max($0, 18), 80) }
        g.riderWeightKg = riderWeightKg.flatMap { (30...200).contains($0) ? $0 : nil }
        g.frontPSI = frontPSI.flatMap { (10...160).contains($0) ? $0 : nil }
        g.rearPSI = rearPSI.flatMap { (10...160).contains($0) ? $0 : nil }
        g.shoes = shoes.prefix(8).map { var s = $0; s.model = CustomSession.oneLine(s.model, max: 60); return s }
        g.wheelsets = wheelsets.prefix(6).map { w in
            var w = w
            w.name = CustomSession.oneLine(w.name, max: 60)
            w.depthMM = w.depthMM.flatMap { (0...120).contains($0) ? $0 : nil }
            w.internalWidthMM = w.internalWidthMM.flatMap { (10...50).contains($0) ? $0 : nil }
            return w
        }
        return g
    }

    /// Lines for the coach, and the guidance that makes them useful.
    var coachLines: [String] {
        let g = sanitized()
        var lines: [String] = []
        if !g.bike.isEmpty { lines.append("Bike: \(g.bike).") }
        if let gs = g.groupset {
            lines.append("Groupset: \(gs.brand == "Other" ? "other" : "\(gs.brand) \(gs.label)") (\(gs.isOneBy ? "1×" : "2×"), \(gs.isElectronic ? "electronic" : "mechanical"))"
                         + (g.gearing.isEmpty ? "." : "; gearing \(g.gearing)."))
        } else if !g.gearing.isEmpty {
            lines.append("Gearing: \(g.gearing).")
        }
        if !g.tires.isEmpty || g.tireSetup != nil || g.tireWidthMM != nil {
            lines.append("Tires: " + [g.tires.isEmpty ? nil : g.tires, g.tireWidthMM.map { "\($0) mm" },
                                      g.tireSetup.map { $0.label.lowercased() }, g.rim.map { "\($0.label.lowercased()) rims" }]
                .compactMap { $0 }.joined(separator: ", ") + ".")
        }
        if let f = g.frontPSI, let r = g.rearPSI {
            lines.append("Runs \(Int(f)) psi front / \(Int(r)) psi rear.")
        }
        if !g.wheelsets.isEmpty {
            lines.append("Wheels: " + g.wheelsets.map(\.line).joined(separator: "; ") + ".")
            if g.wheelsets.contains(where: \.isDeep) && g.wheelsets.count > 1 {
                lines.append("On gusty days (gusts around \(Int(Self.gustyMph)) mph or more), suggest the shallower wheels; deep rims catch crosswinds.")
            }
        }
        if !g.shoes.isEmpty {
            lines.append("Run shoes: " + g.shoes.map { $0.model.isEmpty ? $0.category.label.lowercased() : "\($0.category.label.lowercased()) (\($0.model))" }
                .joined(separator: "; ") + ".")
            lines.append("When it helps, say which of these shoes suits a run: cushioned pairs for easy and recovery miles, super trainers for long runs and tempo, carbon racers kept for race-pace work and race day.")
        }
        return lines
    }
}
