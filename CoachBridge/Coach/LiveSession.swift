import ActivityKit
import Foundation
import os

/// Starts and ends the Live Activity for a session or a race. One at a time: starting a new one
/// ends the old. Nothing here reads Health; the activity shows the plan and a clock.
@MainActor
final class LiveSession: ObservableObject {
    static let shared = LiveSession()

    @Published private(set) var current: Activity<SessionActivityAttributes>?
    @Published var errorText: String?
    private let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "CoachBridge", category: "live")

    init() {
        current = Activity<SessionActivityAttributes>.activities.first { $0.activityState == .active }
    }

    var isAvailable: Bool { ActivityAuthorizationInfo().areActivitiesEnabled }

    func isRunning(title: String) -> Bool { current?.attributes.title == title && current?.activityState == .active }

    /// Sessions of 75 minutes or more get fuel stops every 20, like the Watch's fuel timer.
    static func attributes(for s: PlanSession) -> SessionActivityAttributes {
        let minutes = s.rx?.durationMin
        let target = [s.rx?.heartRate, s.rx?.power, s.rx?.pace, s.rx?.intensity].compactMap { $0 }.first ?? s.kind.label
        return SessionActivityAttributes(
            title: s.title, symbol: s.kind.symbol, kind: s.kind.rawValue,
            target: String(target.prefix(90)), plannedMinutes: minutes,
            fuelEveryMinutes: (minutes ?? 0) >= 75 ? 20 : nil,
            fuelText: (minutes ?? 0) >= 75
                ? s.rx?.fuelDuring.map { String(($0.split(separator: "—").first ?? Substring($0)).prefix(60)).trimmingCharacters(in: .whitespaces) }
                : nil)
    }

    static func attributes(for race: RaceDayPlan) -> SessionActivityAttributes {
        SessionActivityAttributes(
            title: race.raceName, symbol: "flag.checkered", kind: "race",
            target: race.legs.map { "\($0.label): \($0.target)" }.first ?? "Race day",
            plannedMinutes: race.totalMinutes, fuelEveryMinutes: 20,
            fuelText: "~\(race.carbsPerHour / 3) g carbs on the bike")
    }

    func start(_ attributes: SessionActivityAttributes) async {
        guard isAvailable else {
            errorText = "Live Activities are off for Coach Bridge. Turn them on in Settings → Coach Bridge."
            return
        }
        await end()
        do {
            current = try Activity.request(attributes: attributes,
                                           content: .init(state: .init(startedAt: .now, endedAt: nil),
                                                          staleDate: Date.now.addingTimeInterval(12 * 3600)))
            errorText = nil
            log.info("Live Activity started")
        } catch {
            errorText = error.localizedDescription
            log.error("Live Activity failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Ends it showing the final time for a few minutes, then it leaves the Lock Screen.
    func end() async {
        guard let a = current else { return }
        let final = SessionActivityAttributes.ContentState(startedAt: a.content.state.startedAt, endedAt: .now)
        await a.end(.init(state: final, staleDate: nil), dismissalPolicy: .after(.now.addingTimeInterval(5 * 60)))
        current = nil
    }

    /// For "Delete my data": nothing of the athlete's stays on the Lock Screen.
    func endAllNow() async {
        for a in Activity<SessionActivityAttributes>.activities { await a.end(nil, dismissalPolicy: .immediate) }
        current = nil
    }
}
