import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// A place the athlete actually trains. Venues give the day screen its photo — one of your own
/// shots of the Bayshore Bikeway, Ventura Cove, the pain cave — and give Claude a concrete
/// place name to write sessions around.
struct Venue: Codable, Identifiable, Hashable, Sendable {
    var id: UUID = UUID()
    /// Which kind of session this place is for. See `VenueSlot`.
    var slot: String
    var name: String
    /// Optional one-liner: "3.1 mi loop, flat", "50 m, long course Tue/Thu".
    var note: String = ""
    /// File name inside the Venues folder, when the athlete has added a photo.
    var photoFile: String? = nil
    /// Base name of the illustration that ships with the app, for the seeded places. The real
    /// asset is `"\(art)-\(TimeOfDay)"` — each scene is drawn once and graded into four times
    /// of day. A photo always wins over it.
    var art: String? = nil
    var createdAt: Date = .now

    var hasPhoto: Bool { photoFile != nil }
    /// True when there's something to show other than a plain gradient.
    var hasImage: Bool { photoFile != nil || art != nil }
}

/// Which version of a scene to show. Each illustration ships as four graded variants, so the
/// app looks like the hour it actually is — morning gold, flat daylight, low evening sun,
/// a dark sky with stars.
enum TimeOfDay: String, CaseIterable, Sendable {
    case morning, day, evening, night

    /// Uses the day's real sunrise and sunset when the forecast has them, and falls back to
    /// clock hours when it doesn't.
    static func current(_ date: Date = .now, calendar: Calendar = .current,
                        sunrise: Date? = nil, sunset: Date? = nil) -> TimeOfDay {
        if let sunrise, let sunset, sunset > sunrise {
            let dawn = sunrise.addingTimeInterval(-45 * 60)
            let dusk = sunset.addingTimeInterval(45 * 60)
            if date < dawn || date >= dusk { return .night }
            if date < sunrise.addingTimeInterval(150 * 60) { return .morning }
            if date >= sunset.addingTimeInterval(-90 * 60) { return .evening }
            return .day
        }
        switch calendar.component(.hour, from: date) {
        case 0..<6, 20...: return .night
        case 6..<10: return .morning
        case 10..<17: return .day
        default: return .evening
        }
    }
}

/// The venue "slots" — session kinds that get a photo. Indoor rides get their own slot so the
/// trainer shot shows up instead of the coast.
enum VenueSlot {
    static let run = "run"
    static let bike = "bike"
    static let bikeIndoor = "bike.indoor"
    static let swim = "swim"
    static let lift = "lift"
    static let snow = "snow"
    static let fun = "fun"

    static let all = [run, bike, bikeIndoor, swim, lift, snow, fun]

    /// nil for rest and optional days, which stay plain.
    static func key(for session: PlanSession) -> String? {
        switch session.kind {
        case .run: return run
        case .bike: return (session.indoor ?? false) ? bikeIndoor : bike
        case .swim: return swim
        case .lift: return lift
        case .snow: return snow
        case .fun: return fun
        case .rest, .flex: return nil
        }
    }

    /// The session a day's picture comes from: the longest one that happens somewhere.
    static func hero(of sessions: [PlanSession]) -> PlanSession? {
        sessions.filter { key(for: $0) != nil }
            .max { ($0.rx?.durationMin ?? 0) < ($1.rx?.durationMin ?? 0) }
    }

    static func label(_ slot: String) -> String {
        switch slot {
        case run: return "Run"
        case bike: return "Ride"
        case bikeIndoor: return "Indoor ride"
        case swim: return "Swim"
        case lift: return "Lift"
        case snow: return "Snowboard"
        case fun: return "Events"
        default: return slot.capitalized
        }
    }

    static func symbol(_ slot: String) -> String {
        switch slot {
        case run: return "figure.run"
        case bike: return "figure.outdoor.cycle"
        case bikeIndoor: return "figure.indoor.cycle"
        case swim: return "figure.pool.swim"
        case lift: return "dumbbell.fill"
        case snow: return "figure.snowboarding"
        case fun: return "party.popper.fill"
        default: return "mappin.and.ellipse"
        }
    }

    /// The session kind a slot's color comes from.
    static func kind(_ slot: String) -> SessionKind {
        switch slot {
        case run: return .run
        case bike, bikeIndoor: return .bike
        case swim: return .swim
        case lift: return .lift
        case snow: return .snow
        default: return .fun
        }
    }
}

/// Picks which venue a day shows. Pure, so it's unit-tested.
enum VenuePicker {
    /// The pinned venue if there is one, otherwise a stable rotation keyed to the date, so the
    /// same day always shows the same place but the week isn't the same photo seven times.
    static func pick(_ venues: [Venue], slot: String, iso: String, pinnedID: String?, index: Int = 0) -> Venue? {
        let list = venues.filter { $0.slot == slot }.sorted { $0.createdAt < $1.createdAt }
        guard !list.isEmpty else { return nil }
        if let pinnedID, let pinned = list.first(where: { $0.id.uuidString == pinnedID }) { return pinned }
        // Sum of the date's digits: stable across launches (unlike hashValue) and cheap.
        let seed = iso.unicodeScalars.reduce(0) { $0 &+ Int($1.value) } &+ index
        return list[seed % list.count]
    }
}

/// Stores venues and their photos on the phone. Photos are the athlete's own, copied into
/// Application Support with complete file protection; nothing is uploaded anywhere.
@MainActor
final class VenueStore: ObservableObject {
    @Published private(set) var venues: [Venue] = []

    private static var dir: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Venues", isDirectory: true)
    }
    private static var indexURL: URL { dir.appendingPathComponent("venues.json") }

    init(seedIfEmpty: Bool = true) {
        load()
        if venues.isEmpty && seedIfEmpty {
            venues = Self.seed
            persist()
        }
    }

    func venues(for slot: String) -> [Venue] {
        venues.filter { $0.slot == slot }.sorted { $0.createdAt < $1.createdAt }
    }

    func venue(id: UUID) -> Venue? { venues.first { $0.id == id } }

    func save(_ v: Venue) {
        if let i = venues.firstIndex(where: { $0.id == v.id }) { venues[i] = v } else { venues.append(v) }
        persist()
    }

    func delete(_ v: Venue) {
        if let file = v.photoFile {
            try? FileManager.default.removeItem(at: Self.dir.appendingPathComponent(file))
        }
        venues.removeAll { $0.id == v.id }
        persist()
    }

    /// Copies a picked photo in and points the venue at it. Returns the updated venue.
    @discardableResult
    func setPhoto(_ data: Data, for venue: Venue) -> Venue {
        var v = venue
        let name = "\(venue.id.uuidString).jpg"
        let url = Self.dir.appendingPathComponent(name)
        try? FileManager.default.createDirectory(at: Self.dir, withIntermediateDirectories: true)
        try? data.write(to: url, options: [.atomic, .completeFileProtection])
        v.photoFile = name
        save(v)
        return v
    }

    func removePhoto(_ venue: Venue) {
        guard let file = venue.photoFile else { return }
        try? FileManager.default.removeItem(at: Self.dir.appendingPathComponent(file))
        var v = venue
        v.photoFile = nil
        save(v)
    }

    func photoURL(_ venue: Venue) -> URL? {
        venue.photoFile.map { Self.dir.appendingPathComponent($0) }
    }

    #if canImport(UIKit)
    /// Small in-memory cache so scrolling the week doesn't hit the disk every row.
    private var images: [UUID: UIImage] = [:]

    func image(for venue: Venue) -> UIImage? {
        if let cached = images[venue.id] { return cached }
        guard let url = photoURL(venue), let data = try? Data(contentsOf: url),
              let img = UIImage(data: data) else { return nil }
        images[venue.id] = img
        return img
    }

    func forgetImage(_ venue: Venue) { images[venue.id] = nil }
    #endif

    // MARK: Persistence

    private func load() {
        guard let data = try? Data(contentsOf: Self.indexURL) else { return }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        venues = (try? dec.decode([Venue].self, from: data)) ?? []
        adoptArtwork()
    }

    /// A library saved before the artwork shipped has no `art`; match the seeded places by
    /// name and slot so they pick it up instead of staying gradients.
    private func adoptArtwork() {
        var changed = false
        for (i, v) in venues.enumerated() where v.art == nil {
            guard let seeded = Self.seed.first(where: { $0.slot == v.slot && $0.name == v.name }) else { continue }
            venues[i].art = seeded.art
            changed = true
        }
        if changed { persist() }
    }

    private func persist() {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        guard let data = try? enc.encode(venues) else { return }
        try? FileManager.default.createDirectory(at: Self.dir, withIntermediateDirectories: true)
        try? data.write(to: Self.indexURL, options: [.atomic, .completeFileProtection])
    }

    /// Places near home and work, each with an illustration that ships in the asset catalog,
    /// so every day has a picture before a single photo is added.
    nonisolated static let seed: [Venue] = {
        let base = Date(timeIntervalSince1970: 0)
        func v(_ slot: String, _ name: String, _ note: String, _ art: String, _ i: Int) -> Venue {
            Venue(slot: slot, name: name, note: note, art: art,
                  createdAt: base.addingTimeInterval(Double(i)))
        }
        return [
            v(VenueSlot.run, "Bayshore Bikeway", "Flat, wind off the bay, no lights", "venue-bayshore-run", 0),
            v(VenueSlot.run, "Imperial Beach oceanfront", "Packed sand at low tide", "venue-imperial-beach", 1),
            v(VenueSlot.run, "Coronado / Silver Strand", "Long, flat, exposed", "venue-silver-strand", 2),
            v(VenueSlot.run, "Trail miles", "Dirt, shade, easy on the legs", "venue-trail-run", 13),
            v(VenueSlot.run, "Golden Gate Park", "Cypress, fog, forgiving paths", "venue-golden-gate-park", 14),
            v(VenueSlot.run, "Golden Gate Bridge", "Long run with a view, wind on the span", "venue-golden-gate-bridge", 15),
            v(VenueSlot.bike, "Bayshore Bikeway loop", "Traffic-free, good for steady watts", "venue-bayshore-ride", 3),
            v(VenueSlot.bike, "Silver Strand to Coronado", "Flat and fast, headwind home", "venue-silver-strand", 4),
            v(VenueSlot.bike, "Otay Lakes / Honey Springs", "The climbing day", "venue-otay-lakes", 5),
            v(VenueSlot.bike, "Mountain road", "Switchbacks, steady watts, pack a jacket", "venue-mountain-road", 16),
            v(VenueSlot.bike, "Sierra pass", "High and thin — ride it easier than it looks", "venue-sierra-pass", 17),
            v(VenueSlot.bikeIndoor, "Pain cave", "KICKR CORE 2, fan on, towel down", "venue-pain-cave", 6),
            v(VenueSlot.swim, "SDSU Aztec Aquaplex", "Long course, check lap times", "venue-pool", 7),
            v(VenueSlot.swim, "Ventura Cove, Mission Bay", "Flat open water, easy entry", "venue-ventura-cove", 8),
            v(VenueSlot.swim, "La Jolla Cove", "Open water with swell, buddy up", "venue-la-jolla", 9),
            v(VenueSlot.swim, "Open water", "Sight every six strokes, swim the buoy line", "venue-open-water", 18),
            v(VenueSlot.lift, "Gym", "Squat rack, bands, core mat", "venue-gym", 10),
            v(VenueSlot.snow, "Mountain day", "Snowboard weekend", "venue-mountain", 11),
            v(VenueSlot.snow, "Resort day", "Groomers and chairlift laps", "venue-ski-resort", 19),
            v(VenueSlot.snow, "Alpine lake", "The drive-up view", "venue-alpine-lake", 20),
            v(VenueSlot.fun, "Race day", "", "venue-race-day", 12),
        ]
    }()
}
