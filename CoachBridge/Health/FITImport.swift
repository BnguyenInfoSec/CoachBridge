import CryptoKit
import Foundation
import os

/// One session read from a FIT file. Only the summary is kept — never the route or the
/// per-second records — and the file itself isn't stored.
struct ImportedWorkout: Codable, Hashable, Identifiable, Sendable {
    var id: UUID
    var sport: Sport
    var name: String
    var start: Date
    var duration: TimeInterval
    var distanceMeters: Double?
    var avgHR: Double?
    var avgPower: Int?
    var device: String?
    /// SHA-256 of the file it came from, so importing the same file twice does nothing.
    var fileDigest: String
    var importedAt: Date

    var summary: WorkoutSummary {
        WorkoutSummary(id: id, sport: sport, name: name, start: start, duration: duration,
                       distanceMeters: distanceMeters, avgHR: avgHR,
                       origin: Origin(kind: .fitFile, name: device))
    }

    /// Turns a parsed file into workouts. Ids are derived from the file and session, so the
    /// same file always yields the same ids.
    static func from(_ a: FITParser.Activity, digest: String, now: Date) -> [ImportedWorkout] {
        let device = a.product ?? FITParser.manufacturerName(a.manufacturer)
        return a.sessions.enumerated().map { i, s in
            let (sport, name) = FITParser.describe(s)
            return ImportedWorkout(id: stableID("fit:\(digest):\(i)"), sport: sport, name: name,
                                   start: s.start, duration: s.timer ?? s.elapsed, distanceMeters: s.distanceMeters,
                                   avgHR: s.avgHR.map(Double.init), avgPower: s.avgPower, device: device,
                                   fileDigest: digest, importedAt: now)
        }
    }

    private static func stableID(_ s: String) -> UUID {
        let d = Array(SHA256.hash(data: Data(s.utf8)))
        return UUID(uuid: (d[0], d[1], d[2], d[3], d[4], d[5], d[6], d[7],
                           d[8], d[9], d[10], d[11], d[12], d[13], d[14], d[15]))
    }
}

/// Workouts imported from FIT files, on the phone only (Application Support, complete file
/// protection, never iCloud). Same pattern as the other stores.
@MainActor
final class FITWorkoutStore: ObservableObject {
    enum Outcome: Equatable {
        case added(Int)
        case alreadyImported
    }

    @Published private(set) var workouts: [ImportedWorkout] = []
    private let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "CoachBridge", category: "fit")

    private static var url: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("fit-workouts.json")
    }

    init() { load() }

    /// Parses a file and keeps its sessions. Throws `FITParser.Failure` for anything it can't
    /// read, with a message fit to show.
    @discardableResult
    func importFile(_ data: Data, now: Date = .now) throws -> Outcome {
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard !workouts.contains(where: { $0.fileDigest == digest }) else { return .alreadyImported }
        let parsed = try FITParser.parse(data, now: now)
        let new = ImportedWorkout.from(parsed, digest: digest, now: now)
        workouts.append(contentsOf: new)
        workouts.sort { $0.start > $1.start }
        persist()
        log.info("Imported FIT file: \(new.count, privacy: .public) sessions")
        return .added(new.count)
    }

    func summaries(from start: Date, to end: Date) -> [WorkoutSummary] {
        workouts.filter { $0.start >= start && $0.start < end }.map(\.summary)
    }

    func delete(_ w: ImportedWorkout) {
        workouts.removeAll { $0.id == w.id }
        persist()
    }

    func deleteAll() {
        workouts = []
        try? FileManager.default.removeItem(at: Self.url)
    }

    private func load() {
        guard let data = try? Data(contentsOf: Self.url) else { return }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        workouts = (try? dec.decode([ImportedWorkout].self, from: data)) ?? []
    }

    private func persist() {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        guard let data = try? enc.encode(workouts) else { return }
        try? FileManager.default.createDirectory(at: Self.url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: Self.url, options: [.atomic, .completeFileProtection])
    }
}
