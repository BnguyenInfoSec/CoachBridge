import CoreLocation
import WeatherKit

/// Apple Weather (WeatherKit). Needs the paid Developer Program: the WeatherKit capability in
/// Xcode plus the WeatherKit service on the App ID. Until then calls fail and the app uses Open-Meteo.
enum AppleWeather {
    struct Attribution: Sendable, Equatable {
        let markLight: URL
        let markDark: URL
        let legal: URL
    }

    static func forecast(latitude: Double, longitude: Double, now: Date = .now) async throws -> CoachBridge.Forecast {
        let location = CLLocation(latitude: latitude, longitude: longitude)
        let cal = Calendar.current
        let end = now.addingTimeInterval(8 * 86_400)
        let (hourly, daily) = try await WeatherService.shared.weather(
            for: location,
            including: .hourly(startDate: now.addingTimeInterval(-3_600), endDate: end),
                       .daily(startDate: cal.startOfDay(for: now), endDate: end))

        let hours = hourly.forecast.map { h in
            CoachBridge.HourWeather(
                time: h.date,
                tempF: h.temperature.converted(to: .fahrenheit).value,
                feelsF: h.apparentTemperature.converted(to: .fahrenheit).value,
                precipProb: h.precipitationChance * 100,
                windMph: h.wind.speed.converted(to: .milesPerHour).value,
                gustMph: h.wind.gust?.converted(to: .milesPerHour).value ?? 0,
                uv: Double(h.uvIndex.value))
        }
        var days: [String: CoachBridge.DayWeather] = [:]
        for d in daily.forecast {
            let iso = DayRecord.dateKey(for: d.date, calendar: cal)
            days[iso] = CoachBridge.DayWeather(
                iso: iso,
                highF: d.highTemperature.converted(to: .fahrenheit).value,
                lowF: d.lowTemperature.converted(to: .fahrenheit).value,
                precipProbMax: d.precipitationChance * 100,
                sunrise: d.sun.sunrise,
                sunset: d.sun.sunset)
        }
        return CoachBridge.Forecast(fetchedAt: now, timeZone: cal.timeZone, days: days, hours: hours)
    }

    /// Apple requires showing the Apple Weather mark and a link to its legal/data-sources page.
    static func attribution() async throws -> Attribution {
        let a = try await WeatherService.shared.attribution
        return Attribution(markLight: a.combinedMarkLightURL, markDark: a.combinedMarkDarkURL, legal: a.legalPageURL)
    }
}
