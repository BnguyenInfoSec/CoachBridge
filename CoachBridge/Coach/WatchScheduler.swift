import CryptoKit
import HealthKit
import WorkoutKit
import os

/// Puts the coming week's sessions into the Workout app on Apple Watch (WorkoutKit), with
/// time goals, intervals, and heart-rate / power alerts from each session's targets.
@MainActor
final class WatchScheduler: ObservableObject {
    @Published var enabled: Bool { didSet { UserDefaults.standard.set(enabled, forKey: "watch.enabled") } }
    @Published private(set) var authorization: WorkoutScheduler.AuthorizationState = .notDetermined
    @Published private(set) var lastSummary: String?
    @Published var errorText: String?

    private let scheduler = WorkoutScheduler.shared
    private let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "CoachBridge", category: "watch")
    /// Days ahead to put on the Watch (Apple caps the number of scheduled workouts per app).
    static let horizonDays = 7

    init() {
        enabled = UserDefaults.standard.object(forKey: "watch.enabled") as? Bool ?? true
    }

    var isSupported: Bool { WorkoutScheduler.isSupported }

    func refreshAuthorization() async {
        authorization = await scheduler.authorizationState
    }

    func requestAccess() async {
        authorization = await scheduler.requestAuthorization()
    }

    // MARK: Sync

    func sync(plan: PlanModel, calendar: CalendarSync) async {
        errorText = nil
        guard enabled, isSupported else { return }
        await refreshAuthorization()
        if authorization == .notDetermined { await requestAccess() }
        guard authorization == .authorized else {
            lastSummary = "Allow Coach Bridge to schedule workouts to use the Watch."
            return
        }

        let e = plan.engine
        let cal = e.calendar
        let now = Date.now
        let today = cal.startOfDay(for: now)
        let rx = plan.prescriber

        // What should be on the Watch: timed swim/bike/run/lift sessions that haven't started yet.
        var desired: [(plan: WorkoutPlan, at: DateComponents)] = []
        for i in 0..<Self.horizonDays {
            let d = e.add(today, days: i)
            let day = plan.day(d)
            for (idx, s) in day.sessions.enumerated() {
                guard let slot = calendar.slot(for: day, index: idx), slot.start > now,
                      let workout = Self.workout(for: s, fraction: rx.phaseFraction(d)) else { continue }
                let id = Self.uuid(WorkoutShaper.identity(key: "\(day.iso)#\(idx)", session: s, start: slot.start))
                let comps = cal.dateComponents([.year, .month, .day, .hour, .minute], from: slot.start)
                desired.append((WorkoutPlan(workout, id: id), comps))
            }
        }
        desired = Array(desired.prefix(WorkoutScheduler.maxAllowedScheduledWorkoutCount))

        // IDs hash the session content and start time, so comparing IDs is enough.
        let existing = await scheduler.scheduledWorkouts
        let wanted = Set(desired.map { $0.plan.id })
        var removed = 0, added = 0
        for s in existing where !wanted.contains(s.plan.id) {
            await scheduler.remove(s.plan, at: s.date)
            removed += 1
        }
        let have = Set(existing.map { $0.plan.id })
        for d in desired where !have.contains(d.plan.id) {
            await scheduler.schedule(d.plan, at: d.at)
            added += 1
        }
        lastSummary = "\(desired.count) sessions on your Watch" + (added + removed > 0 ? " (\(added) added, \(removed) removed)" : "")
        log.info("Watch sync: \(desired.count, privacy: .public) scheduled, \(added, privacy: .public) added, \(removed, privacy: .public) removed")
    }

    func removeAll() async {
        await scheduler.removeAllWorkouts()
        lastSummary = "Removed all scheduled workouts from the Watch"
    }

    /// A one-off plan for the system workout preview sheet (iOS shows it with a "send to Watch" option).
    /// `openInWorkoutApp()` is watchOS-only, so the phone uses SwiftUI's `.workoutPreview` instead.
    func previewPlan(_ s: PlanSession, on day: Date, plan: PlanModel) -> WorkoutPlan? {
        Self.workout(for: s, fraction: plan.prescriber.phaseFraction(day)).map { WorkoutPlan($0) }
    }

    // MARK: Building workouts

    static func mapping(for s: PlanSession) -> (HKWorkoutActivityType, HKWorkoutSessionLocationType)? {
        switch s.kind {
        case .run: return (.running, .outdoor)
        case .bike: return (.cycling, s.indoor == true ? .indoor : .outdoor)
        case .swim: return (.swimming, .indoor)
        case .lift: return (.traditionalStrengthTraining, .indoor)
        case .flex:
            let t = s.title.lowercased()
            if t.contains("swim") { return (.swimming, .indoor) }
            if t.contains("run") { return (.running, .outdoor) }
            if t.contains("spin") || t.contains("ride") { return (.cycling, .outdoor) }
            return nil
        case .rest, .snow, .fun:
            return nil
        }
    }

    static func workout(for s: PlanSession, fraction: Double) -> WorkoutPlan.Workout? {
        guard let mapped = mapping(for: s) else { return nil }
        let (activity, location) = mapped
        let minutes = Double(max(15, s.rx?.durationMin ?? 45))

        // Swims and lifts: a simple time goal.
        if activity == .swimming || activity == .traditionalStrengthTraining || !CustomWorkout.supportsActivity(activity) {
            let goal = WorkoutGoal.time(minutes, .minutes)
            guard SingleGoalWorkout.supportsGoal(goal, activity: activity, location: location) else { return nil }
            return .goal(SingleGoalWorkout(activity: activity, location: location,
                                           swimmingLocation: activity == .swimming ? .pool : .unknown, goal: goal))
        }

        let shape = WorkoutShaper.shape(for: s, fraction: fraction)
        func step(_ st: WorkoutShape.Step) -> WorkoutStep {
            WorkoutStep(goal: .time(st.minutes, .minutes), alert: alert(st.target, activity: activity, location: location))
        }
        func interval(_ purpose: IntervalStep.Purpose, _ st: WorkoutShape.Step) -> IntervalStep {
            IntervalStep(purpose, goal: .time(st.minutes, .minutes), alert: alert(st.target, activity: activity, location: location))
        }
        let blocks = shape.blocks.map { b in
            IntervalBlock(steps: [interval(.work, b.work)] + (b.recovery.map { [interval(.recovery, $0)] } ?? []),
                          iterations: b.iterations)
        }
        let name = s.kind == .flex ? "\(s.title) (optional)" : s.title
        return .custom(CustomWorkout(activity: activity, location: location, displayName: name,
                                     warmup: shape.warmup.map(step), blocks: blocks, cooldown: shape.cooldown.map(step)))
    }

    private static func alert(_ t: WorkoutShape.Target?, activity: HKWorkoutActivityType,
                              location: HKWorkoutSessionLocationType) -> (any WorkoutAlert)? {
        guard let t else { return nil }
        let a: any WorkoutAlert
        switch t.metric {
        case .heartRate: a = HeartRateRangeAlert.heartRate(t.range)
        case .power: a = PowerRangeAlert.power(t.range, unit: .watts)
        }
        return CustomWorkout.supportsAlert(a, activity: activity, location: location) ? a : nil
    }

    /// Deterministic UUID from a string (SHA-256, first 16 bytes).
    static func uuid(_ s: String) -> UUID {
        let d = Array(SHA256.hash(data: Data(s.utf8)))
        return UUID(uuid: (d[0], d[1], d[2], d[3], d[4], d[5], d[6], d[7],
                           d[8], d[9], d[10], d[11], d[12], d[13], d[14], d[15]))
    }
}
