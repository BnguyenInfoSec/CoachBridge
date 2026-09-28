import CoreLocation
import WeatherKit

/// Apple Weather (WeatherKit), the app's only weather source since v2.10. Needs the paid
/// Developer Program: the entitlement (Support/CoachBridge.entitlements) plus WeatherKit enabled
/// for the App ID under both Capabilities and App Services. Without those every call fails with
/// a permission error, which the app reports as a setup problem.
enum AppleWeather {
    struct Attribution: Sendable, Equatable {
        let markLight: URL
        let markDark: URL
        let legal: URL
    }

    static func forecast(latitude: Double, longitude: Double, now: Date = .now) async throws -> CoachBridge.Forecast {
        let location = CLLocation(latitude: WeatherPrivacy.rounded(latitude), longitude: WeatherPrivacy.rounded(longitude))
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

    /// WeatherKit refuses a build that isn't entitled or whose App ID lacks the service. Worth
    /// telling apart from "no network", because only one of them is fixed in the developer portal.
    static func isSetupProblem(_ error: Error) -> Bool {
        if let e = error as? WeatherError, case .permissionDenied = e { return true }
        return String(describing: error).contains("WDSJWTAuthenticator")      // auth-token failure
    }

    /// Apple requires showing the Apple Weather mark and a link to its legal/data-sources page.
    static func attribution() async throws -> Attribution {
        let a = try await WeatherService.shared.attribution
        return Attribution(markLight: a.combinedMarkLightURL, markDark: a.combinedMarkDarkURL, legal: a.legalPageURL)
    }
}
