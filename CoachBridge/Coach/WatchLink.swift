import Foundation
import os
import WatchConnectivity
import WorkoutKit

/// The phone's side of the Watch app: sends a snapshot of what's coming up and takes back how
/// workouts felt. The phone stays the source of truth; the watch only displays and answers.
///
/// Nothing here calls Claude. A feel answered on the watch is saved like one answered on the
/// phone, but the coach's note waits until you ask for it: a background launch spending money
/// you didn't see is exactly the kind of cost the app is built to avoid.
@MainActor
final class WatchLink: NSObject, ObservableObject {
    @Published private(set) var isPaired = false
    @Published private(set) var isAppInstalled = false
    @Published private(set) var lastPush: Date?

    private let session: WCSession? = WCSession.isSupported() ? .default : nil
    private let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "CoachBridge", category: "watchlink")

    func activate() {
        guard let session, session.activationState != .activated else { return }
        session.delegate = self
        session.activate()
    }

    /// Sends the latest snapshot. Cheap and idempotent: WatchConnectivity keeps only the newest
    /// application context and delivers it when the watch next wakes.
    func push() {
        // The iPhone widget changes on exactly the same events, so it rides along here.
        PhoneGlancePublisher.publish()
        guard let session, session.activationState == .activated, session.isPaired, session.isWatchAppInstalled else {
            log.info("Watch push skipped: activated \(self.session?.activationState == .activated, privacy: .public), paired \(self.session?.isPaired ?? false, privacy: .public), installed \(self.session?.isWatchAppInstalled ?? false, privacy: .public)")
            return
        }
        let s = AppServices.shared
        let snapshot = Self.snapshot(plan: s.plan, calendar: s.calendar, dashboard: s.dashboard.data,
                                     answered: { s.review.feel(for: $0) != nil }, isDemo: DemoData.isOn, now: .now)
        do {
            try session.updateApplicationContext([WatchLinkKey.snapshot: try snapshot.fitting().encoded()])
            lastPush = .now
            log.info("Pushed watch snapshot: \(snapshot.sessions.count, privacy: .public) sessions, \(snapshot.awaitingFeel.count, privacy: .public) awaiting feel")
        } catch {
            log.error("Watch push failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// After "Delete my data": the watch removes its cached snapshot and complication data.
    func wipeWatch() {
        guard let session, session.activationState == .activated, session.isPaired, session.isWatchAppInstalled else { return }
        try? session.updateApplicationContext([WatchLinkKey.wipe: true])
    }

    // MARK: Building the snapshot

    /// Days of sessions sent to the watch, starting today.
    static let horizonDays = 4

    static func snapshot(plan: PlanModel, calendar: CalendarSync, dashboard: DashboardData?,
                         answered: (UUID) -> Bool, isDemo: Bool, now: Date) -> WatchSnapshot {
        let e = plan.engine
        let today = e.calendar.startOfDay(for: now)
        let days = (0..<horizonDays).map { plan.day(e.add(today, days: $0)) }

        var sessions: [WatchSnapshot.Session] = []
        for day in days {
            for (i, s) in day.sessions.enumerated() where s.kind != .rest {
                let slot = calendar.slot(for: day, index: i)
                let start = slot?.start ?? Scheduler.time(s.startTime, on: day.date, calendar: e.calendar)
                let plan = WatchScheduler.workout(for: s, fraction: plan.prescriber.phaseFraction(day.date))
                    .flatMap { try? WorkoutPlan($0).dataRepresentation }     // no Start button if it won't encode
                sessions.append(WatchSnapshot.Session(
                    id: "\(day.iso)#\(i)", dateISO: day.iso, start: start, kind: s.kind.rawValue,
                    symbol: s.kind.symbol, title: s.title, minutes: s.rx?.durationMin,
                    intensity: s.rx?.intensity, heartRate: s.rx?.heartRate, power: s.rx?.power,
                    pace: s.rx?.pace, fuelDuring: s.rx?.fuelDuring, isYours: s.addedByAthlete,
                    workoutPlan: plan))
            }
        }

        // Finished recently and not yet answered — the same window the phone uses to ask.
        let recent = (dashboard?.recent ?? []) + days.flatMap(\.done)
        var seen = Set<UUID>()
        let awaiting = recent
            .filter { seen.insert($0.id).inserted }
            .filter { now.timeIntervalSince($0.start) < WorkoutFeel.askWindow && $0.start <= now && !answered($0.id) }
            .sorted { $0.start > $1.start }
            .prefix(3)
            .map { WatchSnapshot.Workout(id: $0.id, name: $0.name, symbol: $0.icon,
                                         start: $0.start, minutes: Int($0.duration / 60)) }

        let pw = e.phaseWeek(today)
        let named = e.blueprint.hasEvent || !e.profile.eventName.isEmpty
        // Race pacing and fuelling, from the day before: the watch has it on race morning even
        // if the phone never wakes.
        let raceDays = e.daysToRace(from: today)
        let race: WatchSnapshot.Race? = (!plan.needsSetup && e.blueprint.hasEvent && raceDays <= 1)
            ? RaceDayPlan.make(event: e.profile.eventKind, raceName: e.raceName,
                               ftp: e.settings.ftpWatts, lthr: e.settings.lthrBpm).map { r in
                WatchSnapshot.Race(name: r.raceName,
                                   legs: r.legs.map { .init(label: $0.label, target: $0.target, cue: $0.cue) },
                                   fuel: r.fuel.map { FuelCue(at: $0.at, text: "\($0.leg): \($0.text)") })
            }
            : nil
        return WatchSnapshot(
            generatedAt: now, isDemo: isDemo,
            raceName: plan.needsSetup ? nil : (named ? e.raceName : nil),
            daysToRace: plan.needsSetup ? nil : e.daysToRace(from: today),
            phase: plan.needsSetup ? nil : pw.map {
                .init(id: $0.phase.id, name: $0.phase.name, week: $0.week, weeks: $0.weeks,
                      isEasier: $0.label.hasSuffix("easier week"), focus: $0.phase.focus)
            },
            recovery: dashboard.map {
                .init(level: String(describing: $0.recovery.level), headline: CoachContext.label($0.recovery.level),
                      reasons: $0.recovery.reasons)
            },
            sessions: plan.needsSetup ? [] : sessions,
            awaitingFeel: Array(awaiting),
            race: race)
    }

    // MARK: Feel answered on the watch

    /// Applies a report only if it names a workout the phone knows and every field is in range.
    /// Returns whether it was saved.
    @discardableResult
    func apply(_ report: WatchFeelReport) async -> Bool {
        let s = AppServices.shared
        // A report can wake the app in the background with nothing loaded yet. Load the days it
        // could be about before deciding it's unknown — it's delivered once, so a false "unknown"
        // would lose the answer.
        let e = s.plan.engine
        let today = e.calendar.startOfDay(for: .now)
        await s.plan.loadWorkouts(from: e.add(today, days: -3), to: e.add(today, days: 1))
        let known = (s.dashboard.data?.recent ?? []) + s.plan.workoutsByDay.values.flatMap { $0 }
        guard report.isValid(knownWorkouts: Set(known.map(\.id))),
              let workout = known.first(where: { $0.id == report.workoutID }),
              let mood = WorkoutFeel.Mood(rawValue: report.mood) else {
            log.info("Ignored a watch feel report that didn't validate")
            return false
        }
        let feel = WorkoutFeel(rpe: report.rpe, mood: mood)
        let first = s.review.save(feel: feel, for: workout, dateISO: s.plan.engine.iso(workout.start))
        // Same rule as the phone: a changed answer invalidates the note written from the old one.
        if !first { s.review.clearNote(for: workout.id) }
        push()
        return true
    }
}

extension WatchLink: WCSessionDelegate {
    nonisolated func session(_ session: WCSession, activationDidCompleteWith state: WCSessionActivationState, error: Error?) {
        let paired = session.isPaired, installed = session.isWatchAppInstalled
        Task { @MainActor in
            self.isPaired = paired
            self.isAppInstalled = installed
            self.push()
        }
    }

    nonisolated func sessionWatchStateDidChange(_ session: WCSession) {
        let paired = session.isPaired, installed = session.isWatchAppInstalled
        Task { @MainActor in
            self.isPaired = paired
            self.isAppInstalled = installed
            self.push()
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
        guard let data = userInfo[WatchLinkKey.feel] as? Data, let report = WatchFeelReport.decode(data) else { return }
        Task { @MainActor in await self.apply(report) }
    }

    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}

    /// Switching to a different watch: activate again so the new one gets a snapshot.
    nonisolated func sessionDidDeactivate(_ session: WCSession) { session.activate() }
}
