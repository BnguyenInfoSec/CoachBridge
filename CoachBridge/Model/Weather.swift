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

/// Open-Meteo (open-meteo.com): free for non-commercial use, no API key. Attribution: CC BY 4.0.
enum OpenMeteo {
    static func url(latitude: Double, longitude: Double, days: Int = 8) -> URL {
        var c = URLComponents(string: "https://api.open-meteo.com/v1/forecast")!
        c.queryItems = [
            URLQueryItem(name: "latitude", value: String(format: "%.2f", latitude)),
            URLQueryItem(name: "longitude", value: String(format: "%.2f", longitude)),
            URLQueryItem(name: "hourly", value: "temperature_2m,apparent_temperature,precipitation_probability,wind_speed_10m,wind_gusts_10m,uv_index"),
            URLQueryItem(name: "daily", value: "temperature_2m_max,temperature_2m_min,precipitation_probability_max,sunrise,sunset"),
            URLQueryItem(name: "temperature_unit", value: "fahrenheit"),
            URLQueryItem(name: "wind_speed_unit", value: "mph"),
            URLQueryItem(name: "timezone", value: "auto"),
            URLQueryItem(name: "forecast_days", value: String(days)),
        ]
        return c.url!
    }

    private struct Response: Decodable {
        struct Hourly: Decodable {
            let time: [String]
            let temperature_2m: [Double?]
            let apparent_temperature: [Double?]
            let precipitation_probability: [Double?]
            let wind_speed_10m: [Double?]
            let wind_gusts_10m: [Double?]
            let uv_index: [Double?]
        }
        struct Daily: Decodable {
            let time: [String]
            let temperature_2m_max: [Double?]
            let temperature_2m_min: [Double?]
            let precipitation_probability_max: [Double?]
            let sunrise: [String]
            let sunset: [String]
        }
        let timezone: String?
        let hourly: Hourly
        let daily: Daily
    }

    enum ParseError: LocalizedError {
        case unreadable
        var errorDescription: String? { "Couldn't read the weather forecast." }
    }

    static func parse(_ data: Data, now: Date = .now) throws -> Forecast {
        guard let r = try? JSONDecoder().decode(Response.self, from: data) else { throw ParseError.unreadable }
        let tz = r.timezone.flatMap(TimeZone.init(identifier:)) ?? .current
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = tz
        f.dateFormat = "yyyy-MM-dd'T'HH:mm"

        let h = r.hourly
        var hours: [HourWeather] = []
        for i in h.time.indices {
            guard let t = f.date(from: h.time[i]),
                  let temp = h.temperature_2m[safe: i] ?? nil else { continue }
            hours.append(HourWeather(time: t, tempF: temp,
                                     feelsF: (h.apparent_temperature[safe: i] ?? nil) ?? temp,
                                     precipProb: (h.precipitation_probability[safe: i] ?? nil) ?? 0,
                                     windMph: (h.wind_speed_10m[safe: i] ?? nil) ?? 0,
                                     gustMph: (h.wind_gusts_10m[safe: i] ?? nil) ?? 0,
                                     uv: (h.uv_index[safe: i] ?? nil) ?? 0))
        }
        let d = r.daily
        var days: [String: DayWeather] = [:]
        for i in d.time.indices {
            guard let hi = d.temperature_2m_max[safe: i] ?? nil, let lo = d.temperature_2m_min[safe: i] ?? nil else { continue }
            days[d.time[i]] = DayWeather(iso: d.time[i], highF: hi, lowF: lo,
                                         precipProbMax: (d.precipitation_probability_max[safe: i] ?? nil) ?? 0,
                                         sunrise: d.sunrise[safe: i].flatMap { f.date(from: $0) },
                                         sunset: d.sunset[safe: i].flatMap { f.date(from: $0) })
        }
        return Forecast(fetchedAt: now, timeZone: tz, days: days, hours: hours)
    }
}

extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}
