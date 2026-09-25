import XCTest
@testable import CoachBridge

/// Builds FIT files byte by byte, so the parser is tested against real structure — including
/// the awkward parts (big-endian, developer fields, compressed timestamps) — without fixtures.
struct FITWriter {
    var body: [UInt8] = []
    var bigEndian = false

    enum Value { case u8(UInt8), u16(UInt16), u32(UInt32), str(String, Int) }

    private func bytes(_ v: Value) -> [UInt8] {
        switch v {
        case .u8(let x): return [x]
        case .u16(let x): return bigEndian ? [UInt8(x >> 8), UInt8(x & 0xFF)] : [UInt8(x & 0xFF), UInt8(x >> 8)]
        case .u32(let x):
            let le = [UInt8(x & 0xFF), UInt8(x >> 8 & 0xFF), UInt8(x >> 16 & 0xFF), UInt8(x >> 24)]
            return bigEndian ? le.reversed() : le
        case .str(let s, let n): return Array((Array(s.utf8) + [UInt8](repeating: 0, count: n)).prefix(n))
        }
    }

    private func baseType(_ v: Value) -> UInt8 {
        switch v { case .u8: return 0x02; case .u16: return 0x84; case .u32: return 0x86; case .str: return 0x07 }
    }

    /// A definition then one data message for it. `dev` adds developer fields of those sizes.
    mutating func message(local: UInt8, global: UInt16, _ fields: [(UInt8, Value)], dev: [Int] = [],
                          compressed: Bool = false) {
        body.append(0x40 | local | (dev.isEmpty ? 0 : 0x20))
        body += [0, bigEndian ? 1 : 0]
        body += bigEndian ? [UInt8(global >> 8), UInt8(global & 0xFF)] : [UInt8(global & 0xFF), UInt8(global >> 8)]
        body.append(UInt8(fields.count))
        for (num, v) in fields { body += [num, UInt8(bytes(v).count), baseType(v)] }
        if !dev.isEmpty {
            body.append(UInt8(dev.count))
            for (i, size) in dev.enumerated() { body += [UInt8(i), UInt8(size), 0] }
        }
        body.append(compressed ? 0x80 | (local << 5) | 0x05 : local)
        for (_, v) in fields { body += bytes(v) }
        for size in dev { body += [UInt8](repeating: 0xAB, count: size) }
    }

    func file(headerSize: Int = 14) -> Data {
        let size = UInt32(body.count)
        var h: [UInt8] = [UInt8(headerSize), 0x20, 0x08, 0x08,
                          UInt8(size & 0xFF), UInt8(size >> 8 & 0xFF), UInt8(size >> 16 & 0xFF), UInt8(size >> 24),
                          0x2E, 0x46, 0x49, 0x54]
        if headerSize == 14 {
            let c = FITParser.crc(h, 0..<12)
            h += [UInt8(c & 0xFF), UInt8(c >> 8)]
        }
        let all = h + body
        let c = FITParser.crc(all, 0..<all.count)
        return Data(all + [UInt8(c & 0xFF), UInt8(c >> 8)])
    }
}

final class FITParserTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_790_000_000)
    /// 2026-09-20 07:00 UTC as a FIT timestamp.
    private let start = UInt32(1_789_887_600 - 631_065_600)

    private func ride(bigEndian: Bool = false, dev: [Int] = [], compressed: Bool = false, headerSize: Int = 14) -> Data {
        var w = FITWriter(bigEndian: bigEndian)
        w.message(local: 0, global: 0, [(0, .u8(4)), (1, .u16(1)), (8, .str("Edge 540", 16))])
        w.message(local: 1, global: 20, [(253, .u32(start)), (3, .u8(140))], dev: dev, compressed: compressed)  // a record: skipped
        w.message(local: 2, global: 18, [(2, .u32(start)), (7, .u32(7_200_000)), (8, .u32(7_050_000)),
                                          (9, .u32(6_050_000)), (5, .u8(2)), (6, .u8(0)),
                                          (16, .u8(141)), (17, .u8(172)), (20, .u16(205))], dev: dev)
        return w.file(headerSize: headerSize)
    }

    /// The writer above uses the parser's own CRC, so check it independently: FIT's CRC is
    /// CRC-16/ARC, whose published check value for "123456789" is 0xBB3D.
    func testChecksumIsTheStandardCRC16() {
        let v = Array("123456789".utf8)
        XCTAssertEqual(FITParser.crc(v, 0..<v.count), 0xBB3D)
    }

    func testReadsARide() throws {
        let a = try FITParser.parse(ride(), now: now)
        XCTAssertEqual(a.product, "Edge 540")
        XCTAssertEqual(FITParser.manufacturerName(a.manufacturer), "Garmin")
        XCTAssertEqual(a.sessions.count, 1)
        let s = a.sessions[0]
        XCTAssertEqual(s.start, Date(timeIntervalSince1970: 1_789_887_600))
        XCTAssertEqual(s.elapsed, 7_200)
        XCTAssertEqual(s.timer, 7_050)
        XCTAssertEqual(s.distanceMeters, 60_500)
        XCTAssertEqual(s.avgHR, 141)
        XCTAssertEqual(s.maxHR, 172)
        XCTAssertEqual(s.avgPower, 205)
        XCTAssertEqual(FITParser.describe(s).sport, .bike)
    }

    func testBigEndianDeveloperFieldsCompressedTimestampsAndShortHeaders() throws {
        let reference = try FITParser.parse(ride(), now: now)
        for file in [ride(bigEndian: true), ride(dev: [4, 1, 2]), ride(compressed: true), ride(headerSize: 12),
                     ride(bigEndian: true, dev: [3], compressed: true, headerSize: 12)] {
            XCTAssertEqual(try FITParser.parse(file, now: now), reference)
        }
    }

    func testTriathlonKeepsEachLegAndDropsTransitions() throws {
        var w = FITWriter()
        w.message(local: 0, global: 0, [(0, .u8(4))])
        for (i, (sport, secs)) in [(5, 1_900), (3, 180), (2, 9_000), (3, 120), (1, 6_300), (18, 17_500)].enumerated() {
            w.message(local: 1, global: 18, [(2, .u32(start + UInt32(i * 100))), (7, .u32(UInt32(secs * 1000))), (5, .u8(UInt8(sport)))])
        }
        let a = try FITParser.parse(w.file(), now: now)
        XCTAssertEqual(a.sessions.map(\.sport), [5, 2, 1], "swim, bike, run; transitions and the multisport total skipped")
    }

    func testImpossibleValuesAreDropped() throws {
        var w = FITWriter()
        w.message(local: 0, global: 0, [(0, .u8(4))])
        w.message(local: 1, global: 18, [(2, .u32(start)), (7, .u32(3_600_000)), (5, .u8(1)),
                                          (16, .u8(251)), (20, .u16(9_000)), (9, .u32(200_000_000))])
        let s = try FITParser.parse(w.file(), now: now).sessions[0]
        XCTAssertNil(s.avgHR)
        XCTAssertNil(s.avgPower)
        XCTAssertNil(s.distanceMeters, "2,000 km in an hour isn't a run")
    }

    func testSessionsFromTheFutureOrLastingDaysAreRejected() {
        var w = FITWriter()
        w.message(local: 0, global: 0, [(0, .u8(4))])
        w.message(local: 1, global: 18, [(2, .u32(start + 90 * 86_400)), (7, .u32(3_600_000)), (5, .u8(1))])
        w.message(local: 2, global: 18, [(2, .u32(start)), (7, .u32(72 * 3_600_000)), (5, .u8(1))])
        XCTAssertThrowsError(try FITParser.parse(w.file(), now: now)) { XCTAssertEqual($0 as? FITParser.Failure, .noSessions) }
    }

    func testCoursesAreNotActivities() {
        var w = FITWriter()
        w.message(local: 0, global: 0, [(0, .u8(6))])            // 6 = course
        w.message(local: 1, global: 18, [(2, .u32(start)), (7, .u32(3_600_000)), (5, .u8(1))])
        XCTAssertThrowsError(try FITParser.parse(w.file(), now: now)) { XCTAssertEqual($0 as? FITParser.Failure, .notAnActivity) }
    }

    func testRejectsWhatIsntFIT() {
        for bad in [Data(), Data("hello".utf8), Data(repeating: 0, count: 64), Data("not a fit file at all, just text".utf8)] {
            XCTAssertThrowsError(try FITParser.parse(bad, now: now))
        }
        XCTAssertThrowsError(try FITParser.parse(Data(count: FITParser.maxFileBytes + 1), now: now)) {
            XCTAssertEqual($0 as? FITParser.Failure, .tooLarge)
        }
    }

    func testAChangedByteFailsTheChecksum() {
        var bytes = [UInt8](ride())
        bytes[40] ^= 0x01
        XCTAssertThrowsError(try FITParser.parse(Data(bytes), now: now)) { XCTAssertEqual($0 as? FITParser.Failure, .badChecksum) }
    }

    /// Truncated at every possible length: always an error, never a crash.
    func testTruncatedAnywhere() {
        let full = [UInt8](ride(dev: [2]))
        for n in 0..<full.count {
            XCTAssertThrowsError(try FITParser.parse(Data(full.prefix(n)), now: now), "length \(n)")
        }
    }

    /// Random corruption with the checksum re-signed, so the damage reaches the record parser
    /// instead of stopping at the CRC. Thousands of files: it must return or throw, every time.
    func testFuzzedFilesNeverCrash() {
        var rng = SystemRandomNumberGenerator()
        let base = [UInt8](ride(dev: [3], compressed: true))
        let headerAndBody = Array(base.dropLast(2))
        var parsed = 0, rejected = 0
        for _ in 0..<5_000 {
            var b = headerAndBody
            for _ in 0..<Int.random(in: 1...6, using: &rng) {
                let i = Int.random(in: 14..<b.count, using: &rng)     // keep the header, damage the records
                b[i] = UInt8.random(in: 0...255, using: &rng)
            }
            let c = FITParser.crc(b, 0..<b.count)
            b += [UInt8(c & 0xFF), UInt8(c >> 8)]
            if (try? FITParser.parse(Data(b), now: now)) != nil { parsed += 1 } else { rejected += 1 }
        }
        XCTAssertEqual(parsed + rejected, 5_000)
    }

    /// A header claiming a huge data size must fail as truncated, not allocate or read past the end.
    func testLyingDataSizeIsTruncatedNotTrusted() {
        var b = [UInt8](ride())
        b[4] = 0xFF; b[5] = 0xFF; b[6] = 0xFF; b[7] = 0x7F
        let c = FITParser.crc(b, 0..<12)
        b[12] = UInt8(c & 0xFF); b[13] = UInt8(c >> 8)
        XCTAssertThrowsError(try FITParser.parse(Data(b), now: now)) { XCTAssertEqual($0 as? FITParser.Failure, .truncated) }
    }

    func testSportNames() {
        func s(_ sport: UInt8, _ sub: UInt8? = nil) -> FITParser.Session {
            FITParser.Session(sport: sport, subSport: sub, start: now, elapsed: 60)
        }
        XCTAssertEqual(FITParser.describe(s(1)).sport, .run)
        XCTAssertEqual(FITParser.describe(s(2, 6)).name, "Indoor ride")
        XCTAssertEqual(FITParser.describe(s(4, 6)).sport, .bike)
        XCTAssertEqual(FITParser.describe(s(5)).sport, .swim)
        XCTAssertEqual(FITParser.describe(s(25)).name, "Golf")
        XCTAssertEqual(FITParser.describe(s(99)).name, "Workout")
    }
}
