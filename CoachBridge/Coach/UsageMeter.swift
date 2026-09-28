import Foundation
import os

/// Which feature a model call is for. Set by the caller around the call
/// (`UsageContext.$feature.withValue(.note) { … }`) and read by the client when the response
/// reports its tokens, so the clients don't need to know about features.
enum UsageContext {
    @TaskLocal static var feature: UsageFeature = .other
}

/// Every model call's token counts, on the phone. Same pattern as the other stores: JSON in
/// Application Support, complete file protection, pruned. Counts only, never content.
@MainActor
final class UsageMeter: ObservableObject {
    @Published private(set) var records: [UsageRecord] = []
    private let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "CoachBridge", category: "usage")

    private static var url: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ai-usage.json")
    }

    init() { load() }

    /// Called by the clients from wherever the response lands.
    nonisolated static func record(_ usage: TokenUsage, feature: UsageFeature, provider: String, model: String) {
        Task { @MainActor in
            AppServices.shared.usage.add(UsageRecord(date: .now, feature: feature, provider: provider, model: model,
                                                     inputTokens: usage.input, outputTokens: usage.output))
        }
    }

    func add(_ r: UsageRecord) {
        records.append(r)
        persist()
        // Feature only: the counts are in the store, and a message's size can hint at its content.
        log.info("AI call recorded: \(r.feature.rawValue, privacy: .public)")
    }

    func summary(from start: Date, to end: Date = .now.addingTimeInterval(1)) -> UsageSummary {
        UsageSummary.make(records, from: start, to: end)
    }

    /// Keeps about thirteen months, enough to compare a month with the same one last year.
    func prune(before date: Date) {
        let before = records.count
        records.removeAll { $0.date < date }
        if records.count != before { persist() }
    }

    func deleteAll() {
        records = []
        try? FileManager.default.removeItem(at: Self.url)
    }

    private func load() {
        guard let data = try? Data(contentsOf: Self.url) else { return }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        records = (try? dec.decode([UsageRecord].self, from: data)) ?? []
    }

    private func persist() {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        guard let data = try? enc.encode(records) else { return }
        try? FileManager.default.createDirectory(at: Self.url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: Self.url, options: [.atomic, .completeFileProtection])
    }
}
