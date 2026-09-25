import Foundation

/// Decides which check-in days an automatic run should export.
enum ExportPlan {
    /// Today and yesterday are always (re-)exported, because their values keep changing
    /// (resting HR settles later in the day, late workouts land). Older days in the lookback
    /// window are exported only if their file is missing from Drive, newest first,
    /// at most `backfillLimit` per run.
    static func days(today: Date,
                     existingFileNames: Set<String>,
                     lookbackDays: Int = 60,
                     backfillLimit: Int,
                     calendar: Calendar = .current) -> [Date] {
        let start = calendar.startOfDay(for: today)
        var result: [Date] = []
        var backfilled = 0
        for offset in 0..<lookbackDays {
            guard let day = calendar.date(byAdding: .day, value: -offset, to: start) else { continue }
            if offset <= 1 {
                result.append(day)
                continue
            }
            guard backfilled < backfillLimit else { break }
            let name = DayRecord.dateKey(for: day, calendar: calendar) + ".json"
            if !existingFileNames.contains(name) {
                result.append(day)
                backfilled += 1
            }
        }
        return result
    }

    /// Next 6:30 AM strictly after `now` — the earliest a daily refresh should be attempted.
    static func nextMorning(after now: Date, calendar: Calendar = .current) -> Date {
        let today = calendar.date(bySettingHour: 6, minute: 30, second: 0, of: now)!
        return today > now ? today : calendar.date(byAdding: .day, value: 1, to: today)!
    }
}
