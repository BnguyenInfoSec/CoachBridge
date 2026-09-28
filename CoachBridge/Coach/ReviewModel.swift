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

    /// The note was written before the athlete said how the session felt (or before they changed
    /// their answer), so it's reacting to numbers alone. Kept rather than deleted — it was paid
    /// for — and offered for an update.
    func isStale(_ id: UUID) -> Bool {
        guard let note = note(for: id), let feel = feel(for: id) else { return false }
        return note.createdAt < feel.answeredAt
    }

    /// The plan's session a recorded workout answers to: the same sport, on the same day.
    static func plannedMatch(for w: WorkoutSummary, in sessions: [PlanSession]) -> PlanSession? {
        sessions.first { s in
            switch (s.kind, w.sport) {
            case (.swim, .swim), (.bike, .bike), (.run, .run): return true
            case (.lift, .other): return true
            default: return false
            }
        }
    }

    /// Saves how a session felt and asks the coach to write — or rewrite — the note with it.
    /// One request per answer, started by the athlete's own tap. Used by the sheet that opens
    /// with the app, by a tapped notification and by the workout screen.
    func answer(_ feel: WorkoutFeel, for workout: WorkoutSummary, detail: WorkoutDetail? = nil) async {
        let s = AppServices.shared
        let engine = s.plan.engine
        let iso = engine.iso(workout.start)
        save(feel: feel, for: workout, dateISO: iso)
        s.prompter.answered(workout.id)
        s.watchLink.push()                       // it's no longer waiting on the watch

        var detail = detail
        if detail == nil {
            detail = try? await s.source.workoutDetail(workout, lthr: s.plan.settings.lthrBpm)
        }
        let planned = Self.plannedMatch(for: workout, in: s.plan.day(workout.start).sessions)
        let compare = SessionCompare.make(
            planned: planned, actualSeconds: workout.duration,
            avgHR: workout.avgHR ?? detail.flatMap { Stats.mean($0.heartRate.map(\.value)) },
            avgPower: detail?.avgPower)
        await review(workout: workout, detail: detail, planned: planned, compare: compare, engine: engine,
                     recovery: s.dashboard.data?.recovery,
                     recentSameSport: (s.dashboard.data?.recent ?? []).filter { $0.sport == workout.sport && $0.id != workout.id },
                     dateISO: iso,
                     force: note(for: workout.id) != nil)
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
        guard await ConsentGate.shared.require(.ai) else {
            errorText = Consent.declinedMessage
            return
        }

        let system = WorkoutReviewer.systemPrompt(engine: engine, demo: false)
        let user = WorkoutReviewer.userText(
            workout: workout, detail: detail, compare: compare,
            feel: journal.feel(for: workout.id), planned: planned, engine: engine,
            recovery: recovery, recentSameSport: recentSameSport,
            recentFeel: journal.effortSummary())

        do {
            let data = try await UsageContext.$feature.withValue(.note) {
                try await client.runTool(system: system, user: user, tool: WorkoutReviewer.tool)
            }
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
