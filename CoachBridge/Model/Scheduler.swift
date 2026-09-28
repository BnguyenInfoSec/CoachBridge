import Foundation

/// A block of time the athlete's own calendar says is taken.
struct BusyBlock: Sendable, Equatable {
    let start: Date
    let end: Date
    let title: String?
    let allDay: Bool
}

/// Places a day's sessions into free time. Pure, so it's unit-tested.
enum Scheduler {
    /// Minutes after midnight.
    struct Window: Equatable, Sendable { let start: Int; let end: Int }

    /// Fallbacks when there's no work schedule to derive from: evening then early morning on a
    /// weekday, morning then afternoon at the weekend.
    static let weekdayWindows = [Window(start: 16 * 60 + 30, end: 20 * 60 + 30), Window(start: 5 * 60 + 30, end: 8 * 60 + 45)]
    static let weekendWindows = [Window(start: 7 * 60, end: 13 * 60), Window(start: 15 * 60, end: 19 * 60)]

    /// Training windows built from the athlete's own hours: after they finish, then before they
    /// start. A day they don't work gets the whole usable day.
    static func windows(work: WorkSchedule, jsDay: Int) -> [Window] {
        guard work.isWorking(jsDay) else { return weekendWindows }
        let after = Window(start: min(22 * 60, work.endHour * 60 + 30), end: 21 * 60)
        let before = Window(start: 5 * 60 + 30, end: max(6 * 60, work.startHour * 60 - 15))
        return [after, before].filter { $0.end - $0.start >= 30 }
    }
    /// Gap kept before and after other events (changing, driving).
    static let buffer: TimeInterval = 15 * 60
    /// Gap between back-to-back sessions (run then lift, ride then brick).
    static let transition = 10

    /// On a hot afternoon (the plan's ~90°F rule) mornings go first.
    static func windows(for day: Date, calendar: Calendar, hot: Bool = false,
                        work: WorkSchedule? = nil) -> [Window] {
        let js = calendar.component(.weekday, from: day) - 1
        let w: [Window]
        if let work {
            w = windows(work: work, jsDay: js)
        } else {
            w = calendar.isDateInWeekend(day) ? weekendWindows : weekdayWindows
        }
        return hot ? w.sorted { $0.start < $1.start } : w
    }

    /// Start times for each duration, in order, or nil where nothing fits.
    /// Tries the whole day as one back-to-back block first (keeps "run first, then lift" together),
    /// then each session on its own. A preferred start (e.g. from Claude) is used if that slot is free.
    static func place(durations: [Int], preferredStart: Date? = nil, day: Date,
                      busy: [BusyBlock], calendar: Calendar, hot: Bool = false,
                      work: WorkSchedule? = nil) -> [DateInterval?] {
        guard !durations.isEmpty else { return [] }
        let dayStart = calendar.startOfDay(for: day)
        let blocked = busy.filter { !$0.allDay }.map {
            DateInterval(start: $0.start.addingTimeInterval(-buffer), end: max($0.end, $0.start).addingTimeInterval(buffer))
        }
        let total = durations.reduce(0, +) + transition * (durations.count - 1)

        func sequence(from start: Date) -> [DateInterval?] {
            var t = start
            return durations.map { d in
                let slot = DateInterval(start: t, duration: TimeInterval(d * 60))
                t = slot.end.addingTimeInterval(TimeInterval(transition * 60))
                return slot
            }
        }

        if let p = preferredStart, isFree(DateInterval(start: p, duration: TimeInterval(total * 60)), blocked) {
            return sequence(from: p)
        }
        for w in windows(for: day, calendar: calendar, hot: hot, work: work) {
            if let s = firstFree(minutes: total, window: w, dayStart: dayStart, blocked: blocked) {
                return sequence(from: s)
            }
        }
        // No room for the block: place sessions one at a time.
        var taken = blocked
        return durations.map { d in
            for w in windows(for: day, calendar: calendar, hot: hot, work: work) {
                if let s = firstFree(minutes: d, window: w, dayStart: dayStart, blocked: taken) {
                    let slot = DateInterval(start: s, duration: TimeInterval(d * 60))
                    taken.append(slot)
                    return slot
                }
            }
            return nil
        }
    }

    static func isFree(_ slot: DateInterval, _ blocked: [DateInterval]) -> Bool {
        !blocked.contains { $0.start < slot.end && $0.end > slot.start }
    }

    /// Earliest start inside the window, on a 5-minute grid, that fits `minutes` without overlapping.
    static func firstFree(minutes: Int, window: Window, dayStart: Date, blocked: [DateInterval]) -> Date? {
        let wStart = dayStart.addingTimeInterval(TimeInterval(window.start * 60))
        let wEnd = dayStart.addingTimeInterval(TimeInterval(window.end * 60))
        let length = TimeInterval(minutes * 60)
        var t = wStart
        let sorted = blocked.sorted { $0.start < $1.start }
        while t.addingTimeInterval(length) <= wEnd {
            let slot = DateInterval(start: t, duration: length)
            guard let clash = sorted.first(where: { $0.start < slot.end && $0.end > slot.start }) else { return t }
            t = roundUp(clash.end, to: 5)
        }
        return nil
    }

    static func roundUp(_ d: Date, to minutes: Int) -> Date {
        let step = TimeInterval(minutes * 60)
        return Date(timeIntervalSinceReferenceDate: (d.timeIntervalSinceReferenceDate / step).rounded(.up) * step)
    }

    /// "HH:mm" on the given day.
    static func time(_ hhmm: String?, on day: Date, calendar: Calendar) -> Date? {
        guard let hhmm, let colon = hhmm.firstIndex(of: ":"),
              let h = Int(hhmm[..<colon]), let m = Int(hhmm[hhmm.index(after: colon)...]),
              (0..<24).contains(h), (0..<60).contains(m) else { return nil }
        return calendar.date(bySettingHour: h, minute: m, second: 0, of: day)
    }

    /// The calendar as Claude sees it: one line per day with times and titles.
    static func describe(_ busy: [BusyBlock], days: [Date], calendar: Calendar) -> String {
        let tf = DateFormatter()
        tf.calendar = calendar
        tf.timeZone = calendar.timeZone
        tf.locale = Locale(identifier: "en_US_POSIX")
        tf.dateFormat = "HH:mm"
        let df = DateFormatter()
        df.calendar = calendar
        df.timeZone = calendar.timeZone
        df.locale = Locale(identifier: "en_US_POSIX")
        df.dateFormat = "EEE yyyy-MM-dd"

        return days.map { day in
            let start = calendar.startOfDay(for: day)
            let end = calendar.date(byAdding: .day, value: 1, to: start)!
            let items = busy
                .filter { $0.start < end && $0.end > start }
                .sorted { ($0.allDay ? 0 : 1, $0.start) < ($1.allDay ? 0 : 1, $1.start) }
                .map { b -> String in
                    // Anyone who sends an invite writes this title: one clean line, no tags.
                    let title = b.title.map { " " + PromptSafety.inline($0, max: 60) } ?? ""
                    return b.allDay ? "all day:\(title)" : "\(tf.string(from: b.start))–\(tf.string(from: b.end))\(title)"
                }
            return "\(df.string(from: day)): " + (items.isEmpty ? "free" : items.joined(separator: "; "))
        }.joined(separator: "\n")
    }
}
