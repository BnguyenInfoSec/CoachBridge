import Foundation

/// The time windows the contract uses for check-in day D. DST-safe (calendar math only).
struct DayWindows: Sendable, Equatable {
    /// D 00:00 → D+1 00:00
    let day: DateInterval
    /// D-1 00:00 → D 00:00 ("previous calendar day")
    let previousDay: DateInterval
    /// D-1 18:00 → D 12:00 (sleep, HRV, resp, SpO₂, wrist temp)
    let sleep: DateInterval
    /// 7 days ending at D+1 00:00 ("latest in the last 7 days")
    let last7Days: DateInterval
    /// D-1 00:00 → D+1 00:00 ("most recent run, if within the last 2 days")
    let lastTwoDays: DateInterval

    init(for date: Date, calendar: Calendar = .current) {
        let dayStart = calendar.startOfDay(for: date)
        let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart)!
        let prevStart = calendar.date(byAdding: .day, value: -1, to: dayStart)!
        let sleepStart = calendar.date(bySettingHour: 18, minute: 0, second: 0, of: prevStart)!
        let sleepEnd = calendar.date(bySettingHour: 12, minute: 0, second: 0, of: dayStart)!
        let weekStart = calendar.date(byAdding: .day, value: -7, to: dayEnd)!

        day = DateInterval(start: dayStart, end: dayEnd)
        previousDay = DateInterval(start: prevStart, end: dayStart)
        sleep = DateInterval(start: sleepStart, end: sleepEnd)
        last7Days = DateInterval(start: weekStart, end: dayEnd)
        lastTwoDays = DateInterval(start: prevStart, end: dayEnd)
    }
}
