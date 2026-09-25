import Foundation
import os

/// Owns the workout journal — how each session felt, and the coach's note about it — and runs the
/// one request that writes a note. A note is generated once per workout and then cached, so
/// reopening a session never spends another request.
@MainActor
final class ReviewModel: ObservableObject {
    let journal = WorkoutJournal()

    /// Workouts a request is in flight for, so the UI can show a spinner on the right row.
    @Published private(set) var generating: Set<UUID> = []
    @Published var errorText: String?

    private let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "CoachBridge", category: "review")

    func entry(for id: UUID) -> WorkoutEntry? { journal.entry(for: id) }
    func feel(for id: UUID) -> WorkoutFeel? { journal.feel(for: id) }
    func note(for id: UUID) -> CoachNote? { journal.note(for: id) }
    func isGenerating(_ id: UUID) -> Bool { generating.contains(id) }

    var canGenerate: Bool { DemoData.isOn || LLMFactory.isConfigured }

    /// Saves how a session felt. Returns true when this was the first answer for that workout,
    /// which is what decides whether to go straight on and ask the coach for a note.
    @discardableResult
    func save(feel: WorkoutFeel, for workout: WorkoutSummary, dateISO: String) -> Bool {
        let first = journal.feel(for: workout.id) == nil
        journal.save(feel: feel, for: workout, dateISO: dateISO)
        objectWillChange.send()
        return first
    }

    /// Throws away the note so the next request writes a fresh one — used by "Ask again", and
    /// after the athlete changes how a session felt.
    func clearNote(for id: UUID) {
        journal.clearNote(for: id)
        objectWillChange.send()
    }

    /// Asks the coach to react to one finished session. Does nothing if a note already exists
    /// (pass `force` to replace it) or if a request for this workout is already running.
    func review(workout: WorkoutSummary,
                detail: WorkoutDetail?,
                planned: PlanSession?,
                compare: SessionCompare,
                engine: PlanEngine,
                recovery: RecoverySignal?,
                recentSameSport: [WorkoutSummary],
                dateISO: String,
                force: Bool = false) async {
        guard !generating.contains(workout.id) else { return }
        if journal.note(for: workout.id) != nil && !force { return }

        generating.insert(workout.id)
        defer { generating.remove(workout.id) }
        errorText = nil

        // Demo mode writes its own note: the point is to show someone the app, and it shouldn't
        // need an API key or spend a real request to do it.
        if DemoData.isOn {
            try? await Task.sleep(for: .milliseconds(650))    // so it doesn't appear instantly and look canned
            journal.save(note: DemoData.note(workout: workout, compare: compare,
                                             feel: journal.feel(for: workout.id)),
                         for: workout, dateISO: dateISO)
            objectWillChange.send()
            return
        }

        guard let (client, _, model) = LLMFactory.current(maxTokens: WorkoutReviewer.maxTokens) else {
            errorText = LLMFactory.missingSetupMessage(for: "get a coach's note")
            return
        }

        let system = WorkoutReviewer.systemPrompt(engine: engine, demo: false)
        let user = WorkoutReviewer.userText(
            workout: workout, detail: detail, compare: compare,
            feel: journal.feel(for: workout.id), planned: planned, engine: engine,
            recovery: recovery, recentSameSport: recentSameSport,
            recentFeel: journal.effortSummary())

        do {
            let data = try await client.runTool(system: system, user: user, tool: WorkoutReviewer.tool)
            guard let note = WorkoutReviewer.parse(data, model: model) else {
                errorText = "The coach's reply didn't come back in a form the app could read. Try again."
                return
            }
            journal.save(note: note, for: workout, dateISO: dateISO)
            objectWillChange.send()
            log.info("Wrote a coach note for a \(workout.sport.rawValue, privacy: .public) session")
        } catch {
            errorText = error.localizedDescription
        }
    }
}
