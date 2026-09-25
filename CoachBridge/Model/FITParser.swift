import Foundation

/// Reads the session summaries from a FIT activity file — what Garmin, Wahoo, Hammerhead and
/// most bike computers record — and nothing else.
///
/// Written for this app rather than pulled in as a dependency, and written defensively: the
/// file comes from outside (the share sheet, Files) and must not be able to crash or hang the
/// app. Every length is checked against what's actually there, the CRC must match, the file
/// and message counts are capped, and values outside what a body or a bike can do are dropped.
///
/// It keeps session totals only. GPS tracks, per-second records and developer fields are
/// skipped, not stored: a route is where you live, and the app doesn't need it.
enum FITParser {
    static let maxFileBytes = 30 * 1024 * 1024
    static let maxMessages = 3_000_000
    /// FIT timestamps count seconds from 1989-12-31 00:00 UTC.
    static let epoch: TimeInterval = 631_065_600

    enum Failure: Error, Equatable, LocalizedError {
        case tooLarge, notFIT, truncated, badChecksum, notAnActivity, noSessions, malformed(String)

        var errorDescription: String? {
            switch self {
            case .tooLarge: return "The file is too large to be an activity (over 30 MB)."
            case .notFIT: return "This isn't a FIT file."
            case .truncated: return "The file is incomplete — it may not have finished copying."
            case .badChecksum: return "The file is damaged (its checksum doesn't match)."
            case .notAnActivity: return "This FIT file is a course or workout, not a recorded activity."
            case .noSessions: return "No recorded session was found in the file."
            case .malformed(let why): return "The file couldn't be read (\(why))."
            }
        }
    }

    struct Session: Equatable, Sendable {
        var sport: UInt8
        var subSport: UInt8?
        var start: Date
        var elapsed: TimeInterval
        var timer: TimeInterval?
        var distanceMeters: Double?
        var avgHR: Int?
        var maxHR: Int?
        var avgPower: Int?
    }

    struct Activity: Equatable, Sendable {
        var sessions: [Session]
        var manufacturer: UInt16?
        var product: String?
    }

    static func parse(_ data: Data, now: Date = .now) throws -> Activity {
        guard data.count <= maxFileBytes else { throw Failure.tooLarge }
        let b = [UInt8](data)
        guard b.count >= 14 || (b.count >= 12 && b[0] == 12) else { throw b.count < 12 ? Failure.truncated : Failure.notFIT }

        // Header: size, protocol, profile (2), data size (4), ".FIT", optional header CRC.
        let headerSize = Int(b[0])
        guard headerSize == 12 || headerSize == 14 else { throw Failure.notFIT }
        guard b.count >= headerSize, b[8] == 0x2E, b[9] == 0x46, b[10] == 0x49, b[11] == 0x54 else { throw Failure.notFIT }
        let dataSize = Int(UInt32(b[4]) | UInt32(b[5]) << 8 | UInt32(b[6]) << 16 | UInt32(b[7]) << 24)
        let end = headerSize + dataSize
        guard dataSize >= 0, end + 2 <= b.count else { throw Failure.truncated }
        if headerSize == 14 {
            let stored = UInt16(b[12]) | UInt16(b[13]) << 8
            if stored != 0 && stored != crc(b, 0..<12) { throw Failure.badChecksum }   // 0 means "not set"
        }
        let fileCRC = UInt16(b[end]) | UInt16(b[end + 1]) << 8
        guard fileCRC == crc(b, 0..<end) else { throw Failure.badChecksum }

        struct Field { let num: UInt8; let size: Int; let baseType: UInt8 }
        struct Definition { let global: UInt16; let bigEndian: Bool; let fields: [Field]; let devBytes: Int
            var length: Int { fields.reduce(devBytes) { $0 + $1.size } } }

        var defs = [Definition?](repeating: nil, count: 16)
        var pos = headerSize
        var messages = 0
        var activity = Activity(sessions: [])
        var fileType: UInt8?
        let earliest = Date(timeIntervalSince1970: 946_684_800)          // 2000-01-01
        let latest = now.addingTimeInterval(86_400)

        func need(_ n: Int) throws { guard n >= 0, pos + n <= end else { throw Failure.truncated } }

        while pos < end {
            messages += 1
            guard messages <= maxMessages else { throw Failure.malformed("too many messages") }
            let h = b[pos]
            pos += 1

            if h & 0x80 == 0, h & 0x40 != 0 {
                // Definition message.
                let local = Int(h & 0x0F)
                try need(5)
                let arch = b[pos + 1]
                guard arch <= 1 else { throw Failure.malformed("unknown byte order") }
                let big = arch == 1
                let global = big ? UInt16(b[pos + 2]) << 8 | UInt16(b[pos + 3]) : UInt16(b[pos + 2]) | UInt16(b[pos + 3]) << 8
                let count = Int(b[pos + 4])
                pos += 5
                try need(count * 3)
                var fields: [Field] = []
                fields.reserveCapacity(count)
                for i in 0..<count {
                    let size = Int(b[pos + i * 3 + 1])
                    guard size > 0 else { throw Failure.malformed("empty field") }
                    fields.append(Field(num: b[pos + i * 3], size: size, baseType: b[pos + i * 3 + 2]))
                }
                pos += count * 3
                var devBytes = 0
                if h & 0x20 != 0 {
                    try need(1)
                    let devCount = Int(b[pos])
                    pos += 1
                    try need(devCount * 3)
                    for i in 0..<devCount { devBytes += Int(b[pos + i * 3 + 1]) }
                    pos += devCount * 3
                }
                defs[local] = Definition(global: global, bigEndian: big, fields: fields, devBytes: devBytes)
                continue
            }

            // Data message: normal header, or compressed-timestamp header (local type in bits 5–6).
            let local = h & 0x80 != 0 ? Int((h >> 5) & 0x03) : Int(h & 0x0F)
            guard let def = defs[local] else { throw Failure.malformed("data before its definition") }
            try need(def.length)
            let start = pos
            pos += def.length

            guard def.global == 0 || def.global == 18 || def.global == 23 else { continue }
            var values: [UInt8: UInt64] = [:]
            var strings: [UInt8: String] = [:]
            var off = start
            for f in def.fields {
                if f.baseType & 0x1F == 7 {                                     // string
                    let bytes = b[off..<(off + f.size)].prefix { $0 != 0 }.prefix(64)
                    strings[f.num] = String(decoding: bytes, as: UTF8.self)
                } else if [1, 2, 4].contains(f.size) {
                    var v: UInt64 = 0
                    for i in 0..<f.size {
                        let byte = UInt64(b[off + (def.bigEndian ? i : f.size - 1 - i)])
                        v = v << 8 | byte
                    }
                    let invalid: UInt64 = f.size == 1 ? 0xFF : f.size == 2 ? 0xFFFF : 0xFFFF_FFFF
                    // Signed types use 0x7F… as invalid; both are out of range for every field read here.
                    if v != invalid { values[f.num] = v }
                }
                off += f.size
            }

            switch def.global {
            case 0:                                                           // file_id
                fileType = values[0].map { UInt8(truncatingIfNeeded: $0) }
                if let m = values[1] { activity.manufacturer = UInt16(truncatingIfNeeded: m) }
                if let name = strings[8], !name.isEmpty { activity.product = name }
            case 23:                                                          // device_info
                if activity.product == nil, let name = strings[27], !name.isEmpty { activity.product = name }
            default:                                                          // session
                guard let startRaw = values[2], let elapsedRaw = values[7], let sport = values[5] else { continue }
                let startDate = Date(timeIntervalSince1970: epoch + TimeInterval(startRaw))
                let elapsed = TimeInterval(elapsedRaw) / 1000
                guard startDate >= earliest, startDate <= latest, elapsed > 0, elapsed <= 48 * 3600 else { continue }
                guard sport != 3, sport != 18 else { continue }              // transition, multisport summary
                func inRange(_ v: UInt64?, _ r: ClosedRange<UInt64>) -> Int? { v.flatMap { r.contains($0) ? Int($0) : nil } }
                let distance = values[9].map { Double($0) / 100 }.flatMap { $0 <= 1_000_000 ? $0 : nil }
                activity.sessions.append(Session(
                    sport: UInt8(truncatingIfNeeded: sport),
                    subSport: values[6].map { UInt8(truncatingIfNeeded: $0) },
                    start: startDate, elapsed: elapsed,
                    timer: values[8].map { TimeInterval($0) / 1000 }.flatMap { $0 > 0 && $0 <= elapsed + 1 ? $0 : nil },
                    distanceMeters: distance,
                    avgHR: inRange(values[16], 25...250), maxHR: inRange(values[17], 25...250),
                    avgPower: inRange(values[20], 1...2_500)))
            }
        }

        if let t = fileType, t != 4 { throw Failure.notAnActivity }
        guard !activity.sessions.isEmpty else { throw Failure.noSessions }
        return activity
    }

    // MARK: Mapping to the app's workouts

    /// FIT sport → the app's sport and a name. Unknown sports are kept as "Workout" rather than
    /// dropped: the time still happened.
    static func describe(_ s: Session) -> (sport: Sport, name: String) {
        switch s.sport {
        case 1: return (.run, "Run")
        case 2: return (.bike, s.subSport == 6 ? "Indoor ride" : "Ride")
        case 5: return (.swim, "Swim")
        case 4 where s.subSport == 6: return (.bike, "Indoor ride")       // fitness equipment, indoor cycling
        case 10: return (.other, "Strength")
        case 11: return (.other, "Walk")
        case 17: return (.other, "Hike")
        case 25: return (.other, "Golf")
        default: return (.other, "Workout")
        }
    }

    static func manufacturerName(_ m: UInt16?) -> String? {
        switch m {
        case 1: return "Garmin"
        case 32: return "Wahoo"
        default: return nil
        }
    }

    // MARK: CRC (the FIT SDK's CRC-16)

    private static let crcTable: [UInt16] = [0x0000, 0xCC01, 0xD801, 0x1400, 0xF001, 0x3C00, 0x2800, 0xE401,
                                            0xA001, 0x6C00, 0x7800, 0xB401, 0x5000, 0x9C01, 0x8801, 0x4400]

    static func crc(_ bytes: [UInt8], _ range: Range<Int>) -> UInt16 {
        var crc: UInt16 = 0
        for i in range {
            let byte = bytes[i]
            var tmp = crcTable[Int(crc & 0xF)]
            crc = (crc >> 4) & 0x0FFF
            crc = crc ^ tmp ^ crcTable[Int(byte & 0xF)]
            tmp = crcTable[Int(crc & 0xF)]
            crc = (crc >> 4) & 0x0FFF
            crc = crc ^ tmp ^ crcTable[Int((byte >> 4) & 0xF)]
        }
        return crc
    }
}
