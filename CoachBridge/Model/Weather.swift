import Foundation

struct HourWeather: Sendable, Equatable {
    let time: Date
    let tempF: Double
    let feelsF: Double
    let precipProb: Double
    let windMph: Double
    let gustMph: Double
    let uv: Double
}

struct DayWeather: Sendable, Equatable {
    let iso: String
    let highF: Double
    let lowF: Double
    let precipProbMax: Double
    let sunrise: Date?
    let sunset: Date?
}

struct Forecast: Sendable {
    let fetchedAt: Date
    let timeZone: TimeZone
    let days: [String: DayWeather]
    let hours: [HourWeather]

    /// Heat rule from the plan: above ~90°F, move sessions to first light.
    static let heatThresholdF = 90.0

    /// Today's entry, for sunrise and sunset.
    func day(_ date: Date, calendar: Calendar = .current) -> DayWeather? {
        days[DayRecord.dateKey(for: date, calendar: calendar)]
    }

    var today: DayWeather? { day(.now) }

    /// The forecast hour containing `date`.
    func at(_ date: Date) -> HourWeather? {
        hours.last { $0.time <= date && date.timeIntervalSince($0.time) < 3600 }
    }

    /// Hottest "feels like" between two local hours on a day.
    func maxFeels(on day: Date, fromHour a: Int, toHour b: Int, calendar: Calendar) -> Double? {
        let start = calendar.date(bySettingHour: a, minute: 0, second: 0, of: day)!
        let end = calendar.date(bySettingHour: b, minute: 0, second: 0, of: day)!
        return hours.filter { $0.time >= start && $0.time < end }.map(\.feelsF).max()
    }

    /// True when the after-work / afternoon window is forecast at or above the heat threshold.
    func isHotAfternoon(_ day: Date, calendar: Calendar) -> Bool {
        (maxFeels(on: day, fromHour: 13, toHour: 20, calendar: calendar) ?? 0) >= Self.heatThresholdF
    }

    /// One line per day for Claude.
    func describe(days list: [Date], calendar: Calendar) -> String {
        let df = DateFormatter()
        df.calendar = calendar
        df.timeZone = calendar.timeZone
        df.locale = Locale(identifier: "en_US_POSIX")
        df.dateFormat = "EEE yyyy-MM-dd"
        return list.compactMap { d -> String? in
            let iso = DayRecord.dateKey(for: d, calendar: calendar)
            guard let w = days[iso] else { return nil }
            var s = "\(df.string(from: d)): \(Int(w.lowF.rounded()))–\(Int(w.highF.rounded()))°F, rain \(Int(w.precipProbMax.rounded()))%"
            let parts = [(6, "6am"), (12, "noon"), (17, "5pm")].compactMap { (h, label) -> String? in
                guard let t = calendar.date(bySettingHour: h, minute: 0, second: 0, of: d), let hw = at(t) else { return nil }
                return "\(label) \(Int(hw.tempF.rounded()))°F feels \(Int(hw.feelsF.rounded())), wind \(Int(hw.windMph.rounded())) mph"
            }
            if !parts.isEmpty { s += "; " + parts.joined(separator: "; ") }
            if isHotAfternoon(d, calendar: calendar) { s += " — HOT afternoon" }
            return s
        }.joined(separator: "\n")
    }
}

/// The only location a weather request carries: the training spot rounded to two decimals
/// (about 1 km), whether it came from the phone's position or was typed in by hand.
enum WeatherPrivacy {
    static func rounded(_ degrees: Double) -> Double { (degrees * 100).rounded() / 100 }
}

extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}
