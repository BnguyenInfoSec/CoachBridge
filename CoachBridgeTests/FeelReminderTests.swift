import XCTest
@testable import CoachBridge

final class FeelReminderTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_790_000_000)

    private func w(_ sport: Sport, endedMinutesAgo: Double, for minutes: Double = 45,
                   symbol: String? = nil, id: UUID = UUID()) -> WorkoutSummary {
        let end = now.addingTimeInterval(-endedMinutesAgo * 60)
        return WorkoutSummary(id: id, sport: sport, name: sport.rawValue,
                              start: end.addingTimeInterval(-minutes * 60), duration: minutes * 60,
                              distanceMeters: 10_000, avgHR: 151, activitySymbol: symbol)
    }

    func testTheNotificationNamesTheSport() {
        XCTAssertEqual(FeelReminder.title(for: w(.run, endedMinutesAgo: 5), reminder: false), "How did your run feel?")
        XCTAssertEqual(FeelReminder.noun(for: w(.bike, endedMinutesAgo: 5)), "ride")
        XCTAssertEqual(FeelReminder.noun(for: w(.other, endedMinutesAgo: 5, symbol: "figure.walk")), "walk")
        XCTAssertEqual(FeelReminder.noun(for: w(.other, endedMinutesAgo: 5, symbol: "figure.golf")), "round")
        XCTAssertEqual(FeelReminder.noun(for: w(.other, endedMinutesAgo: 5)), "workout")
    }

    /// Notifications show on a locked phone: the same rule as the widget and Live Activity.
    func testNotificationsCarryNoNumbers() {
        let sports: [(Sport, String?)] = [(.run, nil), (.bike, nil), (.swim, nil), (.other, "figure.walk"),
                                          (.other, "figure.golf"), (.other, "figure.snowboarding"), (.other, nil)]
        for (sport, symbol) in sports {
            let workout = w(sport, endedMinutesAgo: 5, symbol: symbol)
            for reminder in [false, true] {
                let text = FeelReminder.title(for: workout, reminder: reminder) + FeelReminder.body(reminder: reminder)
                XCTAssertNil(text.rangeOfCharacter(from: .decimalDigits), "number on the lock screen: \(text)")
            }
        }
    }

    func testTheOpenPromptPicksTheNewestUnansweredUnofferedWorkout() {
        let older = w(.bike, endedMinutesAgo: 300)
        let newer = w(.run, endedMinutesAgo: 30)
        let pick = FeelReminder.toPrompt([older, newer], answered: [], offered: [], now: now)
        XCTAssertEqual(pick?.id, newer.id)
        XCTAssertEqual(FeelReminder.toPrompt([older, newer], answered: [newer.id], offered: [], now: now)?.id, older.id)
        XCTAssertEqual(FeelReminder.toPrompt([older, newer], answered: [], offered: [newer.id], now: now)?.id, older.id,
                       "skipping the sheet once means it isn't thrown at them again")
        XCTAssertNil(FeelReminder.toPrompt([w(.run, endedMinutesAgo: 3 * 24 * 60)], answered: [], offered: [], now: now),
                     "older than the ask window")
        XCTAssertNil(FeelReminder.toPrompt([w(.run, endedMinutesAgo: -10)], answered: [], offered: [], now: now),
                     "still in progress")
    }

    func testNotificationsOnlyForFreshUnansweredWorkouts() {
        let fresh = w(.run, endedMinutesAgo: 20)
        let stale = w(.run, endedMinutesAgo: 13 * 60)
        let done = w(.bike, endedMinutesAgo: 20)
        let due = FeelReminder.toNotify([fresh, stale, done], answered: [done.id], notified: [:], now: now)
        XCTAssertEqual(due.map(\.id), [fresh.id])
    }

    /// Run/walk pieces keep the first piece's id when merged. Each new piece makes the workout
    /// end later, which re-schedules the same notification instead of sending another.
    func testAWorkoutThatGrewIsScheduledAgainUnderTheSameId() {
        let id = UUID()
        let firstPiece = w(.run, endedMinutesAgo: 30, for: 20, id: id)
        let notified = [id: FeelReminder.end(of: firstPiece)]
        XCTAssertTrue(FeelReminder.toNotify([firstPiece], answered: [], notified: notified, now: now).isEmpty)

        let grown = WorkoutSegments.merge([firstPiece, w(.other, endedMinutesAgo: 5, for: 20, symbol: "figure.walk")])
        XCTAssertEqual(grown.id, id)
        XCTAssertEqual(FeelReminder.toNotify([grown], answered: [], notified: notified, now: now).map(\.id), [id])
        XCTAssertEqual(Set(FeelReminder.identifiers(for: id)).count, 2)
    }
}
