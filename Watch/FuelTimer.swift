import Foundation
import UserNotifications

/// "Eat now" taps on the wrist. Started at the gun (or the start of a long session), it
/// schedules a local notification for each fuelling moment; they arrive as a haptic even while
/// the Workout app is recording. Nothing leaves the watch.
@MainActor
final class FuelTimer: ObservableObject {
    static let shared = FuelTimer()

    @Published private(set) var title: String?
    @Published private(set) var startedAt: Date?
    @Published private(set) var cues: [FuelCue] = []
    @Published var errorText: String?

    private let idPrefix = "fuel-"

    var isRunning: Bool { startedAt != nil && (nextCue.map { _ in true } ?? false) }

    var nextCue: (date: Date, cue: FuelCue)? {
        guard let startedAt else { return nil }
        return cues.lazy.map { (startedAt.addingTimeInterval(TimeInterval($0.at * 60)), $0) }
            .first { $0.0 > .now }
    }

    func start(_ title: String, cues: [FuelCue]) async {
        let center = UNUserNotificationCenter.current()
        do {
            guard try await center.requestAuthorization(options: [.alert, .sound]) else {
                errorText = "Allow notifications for Coach Bridge in the Watch app on your iPhone to get fuel reminders."
                return
            }
        } catch {
            errorText = error.localizedDescription
            return
        }
        stop()
        let upcoming = cues.filter { $0.at > 0 }
        for (i, cue) in upcoming.enumerated() {
            let content = UNMutableNotificationContent()
            content.title = "Fuel"
            content.body = cue.text
            content.sound = .default
            let trigger = UNTimeIntervalNotificationTrigger(timeInterval: TimeInterval(cue.at * 60), repeats: false)
            try? await center.add(UNNotificationRequest(identifier: "\(idPrefix)\(i)", content: content, trigger: trigger))
        }
        self.title = title
        self.cues = upcoming
        startedAt = .now
        errorText = nil
    }

    func stop() {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: (0..<200).map { "\(idPrefix)\($0)" })
        title = nil
        startedAt = nil
        cues = []
    }
}
