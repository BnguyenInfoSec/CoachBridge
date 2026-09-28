import ActivityKit
import Foundation

/// A session (or a race) in progress, on the Lock Screen and in the Dynamic Island.
///
/// Everything that doesn't change is in the attributes; the live parts are timers the system
/// draws itself, so the activity stays right without the app running. Fuel is shown as a
/// cadence ("every 20 min") against the elapsed clock rather than a countdown, because a
/// countdown would need the app awake to move on to the next one.
struct SessionActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var startedAt: Date
        /// Set when the athlete ends it from the app, so the final state shows the finish time.
        var endedAt: Date?
    }

    var title: String
    var symbol: String
    var kind: String
    /// One line of targets: "Z2 · 138–151 bpm".
    var target: String
    var plannedMinutes: Int?
    /// Minutes between fuel stops, if the session is long enough to need them.
    var fuelEveryMinutes: Int?
    var fuelText: String?
}
