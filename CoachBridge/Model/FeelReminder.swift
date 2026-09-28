import Foundation

/// When to ask how a workout felt, and what the notification says. Pure, so the rules — and the
/// rule that a notification never carries a number — are tested rather than eyeballed.
enum FeelReminder {
    /// The first notification waits this long after the workout ends. Run/walk pieces arrive one
    /// at a time and keep the first piece's id when merged, so re-scheduling under that id each
    /// time a piece lands leaves one notification, ten minutes after the last one.
    static let firstDelay: TimeInterval = WorkoutSegments.maxGap
    /// One reminder if it's still unanswered. Strava nudges once; more than that is nagging.
    static let reminderDelay: TimeInterval = 3 * 3600
    /// Only workouts that ended this recently notify. An old workout surfacing late in Health (a
    /// device sync, a FIT import) shouldn't buzz the phone about last Tuesday.
    static let freshness: TimeInterval = 12 * 3600

    static func end(of w: WorkoutSummary) -> Date { w.start.addingTimeInterval(w.duration) }

    /// What the athlete did, as a word: "How did your run feel?"
    static func noun(for w: WorkoutSummary) -> String {
        switch w.icon {
        case "figure.walk": return "walk"
        case "figure.hiking": return "hike"
        case "figure.golf": return "round"
        case "figure.snowboarding", "figure.skiing.downhill": return "day on the mountain"
        case "figure.yoga", "figure.pilates": return "session"
        default: break
        }
        switch w.sport {
        case .run: return "run"
        case .bike: return "ride"
        case .swim: return "swim"
        case .other: return "workout"
        }
    }

    /// Lock-screen safe: the sport only. No duration, distance, pace or heart rate, because a
    /// notification shows on a locked phone, like the widget and the Live Activity.
    static func title(for w: WorkoutSummary, reminder: Bool) -> String {
        reminder ? "Still time to log your \(noun(for: w))" : "How did your \(noun(for: w)) feel?"
    }

    static func body(reminder: Bool) -> String {
        reminder
            ? "Two taps, and the coach's note is about how it went for you, not just the numbers."
            : "Tell the coach and they'll write back."
    }

    /// Notification identifiers for one workout: the first ask and the reminder.
    static func identifiers(for id: UUID) -> [String] {
        ["feel.\(id.uuidString)", "feel.remind.\(id.uuidString)"]
    }

    /// Recorded, finished, recent enough to still be worth asking about, and unanswered.
    static func isAskable(_ w: WorkoutSummary, answered: Set<UUID>, now: Date) -> Bool {
        let end = end(of: w)
        return !answered.contains(w.id) && end <= now && now.timeIntervalSince(w.start) < WorkoutFeel.askWindow
    }

    /// The workout to ask about when the app opens: the newest askable one not already offered.
    /// Offered once — skipping it means skipping it; the card on the workout still asks.
    static func toPrompt(_ workouts: [WorkoutSummary], answered: Set<UUID>, offered: Set<UUID>,
                         now: Date) -> WorkoutSummary? {
        workouts
            .filter { isAskable($0, answered: answered, now: now) && !offered.contains($0.id) }
            .max { $0.start < $1.start }
    }

    /// Workouts a notification should be scheduled for. `notified` holds the ones already
    /// scheduled, but a merged workout that grew since is scheduled again, so the ask waits for
    /// the last piece.
    static func toNotify(_ workouts: [WorkoutSummary], answered: Set<UUID>,
                         notified: [UUID: Date], now: Date) -> [WorkoutSummary] {
        workouts.filter { w in
            guard isAskable(w, answered: answered, now: now),
                  now.timeIntervalSince(end(of: w)) < freshness else { return false }
            guard let scheduledFor = notified[w.id] else { return true }
            return end(of: w) > scheduledFor
        }
    }
}
