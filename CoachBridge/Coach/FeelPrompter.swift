import Foundation
import UserNotifications
import os

/// Asks how a workout felt at the moment it's fresh: a sheet when the app opens, and — if the
/// athlete turned it on — a notification when Health gets a new workout, with one reminder.
///
/// Everything here is local. Notifications are scheduled on the phone and name the sport only,
/// never a number, because they show on a locked screen. Nothing here calls the coach: the note
/// is written when the athlete answers, which is their tap, not a background request.
@MainActor
final class FeelPrompter: ObservableObject {
    static let enabledKey = "notify.feel"

    /// The workout the sheet is open for.
    @Published var pending: WorkoutSummary?
    @Published private(set) var permissionDenied = false

    private let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "CoachBridge", category: "feel-prompt")
    private let offeredKey = "feel.offered"
    private let notifiedKey = "feel.notified"
    /// Enough to cover two days of workouts many times over, so the lists stay tiny.
    private let keep = 60

    var notificationsOn: Bool { UserDefaults.standard.bool(forKey: Self.enabledKey) }

    // MARK: On open

    /// Opens the sheet for the newest recent workout that hasn't been answered or offered yet.
    func offerOnOpen() {
        guard pending == nil else { return }
        let s = AppServices.shared
        let recent = s.dashboard.data?.recent ?? []
        let answered = Set(recent.map(\.id).filter { s.review.feel(for: $0) != nil })
        guard let w = FeelReminder.toPrompt(recent, answered: answered, offered: offered, now: .now) else { return }
        remember(w.id, in: offeredKey)
        pending = w
        log.info("Offered the feel sheet on open")
    }

    /// From a tapped notification. Shows the sheet even if it was offered before: tapping is asking.
    func open(workoutID: UUID) async {
        let s = AppServices.shared
        await s.dashboard.ensureLoaded()
        var known = s.dashboard.data?.recent ?? []
        if !known.contains(where: { $0.id == workoutID }) {
            let e = s.plan.engine
            let today = e.calendar.startOfDay(for: .now)
            await s.plan.loadWorkouts(from: e.add(today, days: -3), to: e.add(today, days: 1))
            known += s.plan.workoutsByDay.values.flatMap { $0 }
        }
        guard let w = known.first(where: { $0.id == workoutID }) else {
            log.info("Tapped reminder for a workout no longer in Health")
            return
        }
        remember(w.id, in: offeredKey)
        pending = w
    }

    // MARK: Notifications

    /// Asks iOS for permission. Returns whether notifications can be shown.
    func requestPermission() async -> Bool {
        let center = UNUserNotificationCenter.current()
        let granted = (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
        permissionDenied = !granted
        log.info("Notification permission: \(granted, privacy: .public)")
        return granted
    }

    func refreshPermissionState() async {
        let status = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
        permissionDenied = status == .denied
    }

    /// Called when Health reports new workouts, including background launches. Reads the last
    /// day and a half; Health can't be read while the phone is locked, so on a locked phone this
    /// finds nothing and the ask comes after the first unlock instead.
    func workoutsChanged(now: Date = .now) async {
        guard notificationsOn, !DemoData.isOn else { return }
        let s = AppServices.shared
        let from = now.addingTimeInterval(-36 * 3600)
        guard let workouts = try? await s.source.workouts(from: from, to: now.addingTimeInterval(60)) else {
            log.info("Workouts unreadable (phone locked?); will ask after unlock")
            return
        }
        let answered = Set(workouts.map(\.id).filter { s.review.feel(for: $0) != nil })
        let due = FeelReminder.toNotify(workouts, answered: answered, notified: notified, now: now)
        for w in due { await schedule(w, now: now) }
        if !due.isEmpty { log.info("Scheduled feel reminders for \(due.count, privacy: .public) workouts") }
    }

    private func schedule(_ w: WorkoutSummary, now: Date) async {
        let center = UNUserNotificationCenter.current()
        guard await center.notificationSettings().authorizationStatus == .authorized else { return }
        let ids = FeelReminder.identifiers(for: w.id)
        let end = FeelReminder.end(of: w)
        let firstAt = max(end.addingTimeInterval(FeelReminder.firstDelay), now.addingTimeInterval(5))
        for (i, reminder) in [false, true].enumerated() {
            let content = UNMutableNotificationContent()
            content.title = FeelReminder.title(for: w, reminder: reminder)
            content.body = FeelReminder.body(reminder: reminder)
            content.sound = reminder ? nil : .default
            content.userInfo = ["workoutID": w.id.uuidString]
            content.threadIdentifier = "feel"
            let at = reminder ? firstAt.addingTimeInterval(FeelReminder.reminderDelay) : firstAt
            let trigger = UNTimeIntervalNotificationTrigger(timeInterval: max(5, at.timeIntervalSince(now)), repeats: false)
            // Same identifier replaces the pending one: a merged workout that grew gets one ask.
            try? await center.add(UNNotificationRequest(identifier: ids[i], content: content, trigger: trigger))
        }
        var map = notified
        map[w.id] = end
        saveNotified(map)
    }

    /// The athlete answered: nothing left to ask about this workout.
    func answered(_ id: UUID) {
        let center = UNUserNotificationCenter.current()
        let ids = FeelReminder.identifiers(for: id)
        center.removePendingNotificationRequests(withIdentifiers: ids)
        center.removeDeliveredNotifications(withIdentifiers: ids)
        if pending?.id == id { pending = nil }
    }

    /// Turning the setting off takes back anything already scheduled.
    func cancelAll() {
        let center = UNUserNotificationCenter.current()
        Task {
            let ids = await center.pendingNotificationRequests().map(\.identifier).filter { $0.hasPrefix("feel.") }
            center.removePendingNotificationRequests(withIdentifiers: ids)
        }
    }

    // MARK: Small persisted lists (ids only — no health data)

    private var offered: Set<UUID> {
        Set((UserDefaults.standard.stringArray(forKey: offeredKey) ?? []).compactMap(UUID.init))
    }

    private func remember(_ id: UUID, in key: String) {
        var list = UserDefaults.standard.stringArray(forKey: key) ?? []
        list.removeAll { $0 == id.uuidString }
        list.append(id.uuidString)
        UserDefaults.standard.set(Array(list.suffix(keep)), forKey: key)
    }

    private var notified: [UUID: Date] {
        let raw = UserDefaults.standard.dictionary(forKey: notifiedKey) as? [String: Double] ?? [:]
        return Dictionary(uniqueKeysWithValues: raw.compactMap { k, v in UUID(uuidString: k).map { ($0, Date(timeIntervalSince1970: v)) } })
    }

    private func saveNotified(_ map: [UUID: Date]) {
        let newest = map.sorted { $0.value > $1.value }.prefix(keep)
        UserDefaults.standard.set(Dictionary(uniqueKeysWithValues: newest.map { ($0.key.uuidString, $0.value.timeIntervalSince1970) }),
                                  forKey: notifiedKey)
    }
}
