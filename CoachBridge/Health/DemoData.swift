import Foundation

/// A believable fortnight of training, for showing the app to someone who has no Apple Watch —
/// or no data yet. Deterministic from the date, so the dashboard looks the same all day and the
/// charts don't reshuffle on every refresh.
///
/// Nothing here ever reaches Drive or the coach as if it were real: the dashboard labels it, the
/// export refuses to run, and the coach prompt says the numbers are a demo.
enum DemoData {
    static let key = "demo.enabled"

    static var isOn: Bool {
        get { UserDefaults.standard.bool(forKey: key) }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }

    /// Stable pseudo-random in 0..<1 from two integers — no state, same answer every time.
    private static func noise(_ a: Int, _ b: Int) -> Double {
        let x = Double((a &* 73_856_093) ^ (b &* 19_349_663) & 0x7FFF_FFFF)
        return x.truncatingRemainder(dividingBy: 1000) / 1000
    }

    static func dashboard(now: Date = .now, calendar: Calendar = .current) -> DashboardData {
        let today = calendar.startOfDay(for: now)
        let dayNumber = calendar.ordinality(of: .day, in: .era, for: today) ?? 0

        // 28 days of resting HR and HRV with a gentle weekly rhythm plus noise.
        var rhr: [DailyPoint] = []
        var hrv: [DailyPoint] = []
        for i in stride(from: 27, through: 0, by: -1) {
            let day = calendar.date(byAdding: .day, value: -i, to: today)!
            let wave = sin(Double(dayNumber - i) / 3.1)
            rhr.append(DailyPoint(day: day, value: (50 + wave * 2.2 + noise(dayNumber - i, 1) * 3).rounded()))
            hrv.append(DailyPoint(day: day, value: (78 - wave * 8 + noise(dayNumber - i, 2) * 22).rounded()))
        }
        let hrvRolling = Stats.rollingAverage(hrv, days: 7, calendar: calendar)

        // Eight weeks of training, ramping, with a lighter fourth week.
        var weekly: [WeeklyLoad] = []
        for w in stride(from: 7, through: 0, by: -1) {
            let weekStart = calendar.dateInterval(of: .weekOfYear,
                                                  for: calendar.date(byAdding: .weekOfYear, value: -w, to: today)!)!.start
            let ramp = 1 + Double(7 - w) * 0.08
            let easy = (7 - w) % 4 == 3 ? 0.62 : 1.0
            let base: [(Sport, Double)] = [(.swim, 1.1), (.bike, 3.4), (.run, 2.6), (.other, 1.0)]
            for (sport, hours) in base {
                let h = hours * ramp * easy * (0.85 + noise(w, sport.rawValue.count) * 0.3)
                weekly.append(WeeklyLoad(weekStart: weekStart, sport: sport, hours: (h * 10).rounded() / 10))
            }
        }

        let recent = recentWorkouts(from: today, calendar: calendar)

        var metrics: [MetricKey: Double] = [
            .rhr: rhr.last?.value ?? 51,
            .hrv: hrv.last?.value ?? 74,
            .vo2: 51.2,
            .steps: 9_400,
            .exerciseMin: 68,
            .activeCal: 812,
            .weight: 168.4,
        ]
        // Someone who doesn't sleep in their watch still sees a full-looking day.
        if noise(dayNumber, 9) > 0.5 { metrics[.sleep] = 7.1 }

        let recovery = RecoverySignal.evaluate(
            rhrToday: metrics[.rhr],
            rhrBaseline: rhr.dropLast().map(\.value),
            hrvRecent: hrv.suffix(7).map(\.value),
            hrvBaseline: hrv.map(\.value))

        return DashboardData(
            today: DayRecord(date: DayRecord.dateKey(for: today, calendar: calendar),
                             exportedAt: now, metrics: metrics),
            rhr: rhr, hrv: hrv, hrvRolling: hrvRolling,
            weekly: weekly, recent: recent, recovery: recovery,
            ignoredLongSessions: 0, generatedAt: now)
    }

    static func recentWorkouts(from today: Date, calendar: Calendar = .current) -> [WorkoutSummary] {
        let plan: [(Int, Sport, String, Double, Double?, Double?)] = [
            (0, .run, "Run", 52 * 60, 11_800, 148),
            (1, .bike, "Ride", 96 * 60, 44_500, 132),
            (2, .swim, "Swim", 41 * 60, 2_100, 127),
            (4, .bike, "Ride", 185 * 60, 82_000, 138),
            (5, .run, "Run", 78 * 60, 17_400, 151),
        ]
        return plan.map { offset, sport, name, duration, distance, hr in
            let start = calendar.date(byAdding: .hour, value: -(offset * 24 + 14),
                                      to: calendar.startOfDay(for: today))!
            return WorkoutSummary(id: UUID(uuidString: String(format: "DEC0DE00-0000-4000-8000-%012d", offset))
                                    ?? UUID(),
                                  sport: sport, name: name, start: start,
                                  duration: duration, distanceMeters: distance, avgHR: hr, origin: .demo)
        }
    }

    /// Workouts for the plan calendar, so recorded sessions line up under planned ones.
    static func workouts(from start: Date, to end: Date, calendar: Calendar = .current) -> [WorkoutSummary] {
        var out: [WorkoutSummary] = []
        var day = calendar.startOfDay(for: start)
        var i = 0
        while day < end {
            let n = calendar.ordinality(of: .day, in: .era, for: day) ?? 0
            // Roughly five sessions a week, skipping two days.
            if noise(n, 3) > 0.28 {
                let sports: [Sport] = [.run, .bike, .swim, .run, .bike, .other]
                let sport = sports[n % sports.count]
                let minutes = Double(35 + Int(noise(n, 4) * 70))
                out.append(WorkoutSummary(
                    id: UUID(uuidString: String(format: "DEC0DE11-0000-4000-8000-%012d", i)) ?? UUID(),
                    sport: sport,
                    name: sport == .other ? "Strength" : sport.rawValue,
                    start: calendar.date(byAdding: .hour, value: 7, to: day)!,
                    duration: minutes * 60,
                    distanceMeters: sport == .swim ? minutes * 45 : (sport == .bike ? minutes * 440 : minutes * 195),
                    avgHR: 120 + noise(n, 5) * 40,
                    origin: .demo))
                i += 1
            }
            day = calendar.date(byAdding: .day, value: 1, to: day)!
        }
        return out
    }

    /// A coach's note written on the phone, so a demo shows the feature without an API key and
    /// without spending a real request. Built from the same comparison the real note gets, so it
    /// says something true about whatever session it's shown under.
    static func note(workout: WorkoutSummary, compare: SessionCompare, feel: WorkoutFeel?) -> CoachNote {
        let mins = Int((workout.duration / 60).rounded())
        let sport = workout.sport.rawValue.lowercased()

        var headline: String
        var body: String
        if !compare.hadPlan {
            headline = "An extra one — no harm done"
            body = "\(mins) minutes of \(sport) that wasn't on the plan. Nothing here you need to pay back, but keep an eye on the week's total so an extra session doesn't quietly turn an easy week into a normal one."
        } else if compare.misses.isEmpty {
            headline = "Straight down the middle"
            body = "\(mins) minutes, every target inside its window. This is what the block is asking for — repeatable, unremarkable, exactly the point."
        } else {
            let miss = compare.misses[0]
            headline = "\(miss.label) came in \(miss.delta)"
            body = "\(mins) minutes of \(sport), with \(miss.label.lowercased()) \(miss.delta) against the plan. One session off target isn't a problem; the same miss three times running is a sign the target is wrong."
        }

        if let feel {
            body += " You logged it at RPE \(feel.rpe) and called it \(feel.mood.label.lowercased()), which "
            body += feel.rpe >= 7 && compare.misses.isEmpty
                ? "is higher than a session like this usually costs — worth watching if it repeats."
                : "lines up with what the numbers show."
        }

        return CoachNote(
            headline: headline,
            body: body + " (Demo note — generated on the phone from sample data.)",
            towardGoal: "Consistency across the block is what gets you to the start line able to race, rather than just able to finish.",
            watchFor: feel.flatMap {
                $0.rpe >= 8 ? "Two sessions this week at RPE 8 or above. Keep the easy days genuinely easy." : nil
            },
            model: "demo",
            createdAt: .now)
    }

    /// A ready-made profile so the Plan tab has something to show in a demo.
    static let profile: AthleteProfile = {
        var p = AthleteProfile()
        p.name = "Demo"
        p.eventKind = .half703
        p.eventName = "Demo 70.3"
        p.currentWeeklyHours = 6
        p.longDay = 6
        p.availableDays = [1, 2, 3, 4, 5, 6]
        p.liftsPerWeek = 2
        p.equipment = [Equipment.roadBike, .trainer, .powerMeter, .pool, .gym].map(\.rawValue)
        p.goal = "Finish inside six hours without blowing up on the run."
        p.notes = "Demo profile — the numbers on screen are generated, not from Health."
        return p
    }()
}
