import Foundation
import os

/// Forecast for the training location. Apple Weather (WeatherKit) when the app has it, otherwise
/// Open-Meteo. Only the (rounded) coordinates leave the phone. Cached in memory for 30 minutes.
@MainActor
final class WeatherModel: ObservableObject {

    enum Source: String { case apple = "Apple Weather", openMeteo = "Open-Meteo" }

    @Published private(set) var forecast: Forecast?
    @Published private(set) var errorText: String?
    @Published private(set) var source: Source = .openMeteo
    @Published private(set) var attribution: AppleWeather.Attribution?
    /// Set when WeatherKit isn't available to this build (free team / service not enabled yet).
    private var appleUnavailable = false
    @Published var locationName: String { didSet { save() } }
    /// Nothing is fetched until the athlete says where they train. Without this the app used
    /// one person's city for everyone.
    @Published private(set) var isConfigured: Bool
    @Published var latitude: Double { didSet { save(); forecast = nil } }
    @Published var longitude: Double { didSet { save(); forecast = nil } }

    private let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "CoachBridge", category: "weather")
    private var inFlight = false

    init() {
        let d = UserDefaults.standard
        locationName = d.string(forKey: "weather.name") ?? ""
        latitude = d.object(forKey: "weather.lat") as? Double ?? 0
        longitude = d.object(forKey: "weather.lon") as? Double ?? 0
        isConfigured = d.bool(forKey: "weather.configured")
    }

    /// Call after the athlete sets a location by hand.
    func confirmLocation() {
        guard latitude != 0 || longitude != 0 else { return }
        isConfigured = true
        UserDefaults.standard.set(true, forKey: "weather.configured")
        Task { await refresh(force: true) }
    }

    func clearLocation() {
        isConfigured = false
        locationName = ""
        latitude = 0
        longitude = 0
        forecast = nil
        UserDefaults.standard.set(false, forKey: "weather.configured")
    }

    private func save() {
        let d = UserDefaults.standard
        d.set(locationName, forKey: "weather.name")
        d.set(latitude, forKey: "weather.lat")
        d.set(longitude, forKey: "weather.lon")
    }

    func refresh(force: Bool = false) async {
        guard isConfigured else { forecast = nil; return }
        if !force, let f = forecast, Date.now.timeIntervalSince(f.fetchedAt) < 30 * 60 { return }
        guard !inFlight else { return }
        inFlight = true
        defer { inFlight = false }
        if !appleUnavailable {
            do {
                forecast = try await AppleWeather.forecast(latitude: latitude, longitude: longitude)
                source = .apple
                errorText = nil
                if attribution == nil { attribution = try? await AppleWeather.attribution() }
                log.info("Forecast from Apple Weather")
                return
            } catch {
                appleUnavailable = true
                log.info("Apple Weather unavailable, using Open-Meteo: \(error.localizedDescription, privacy: .public)")
            }
        }
        do {
            var req = URLRequest(url: OpenMeteo.url(latitude: latitude, longitude: longitude))
            req.timeoutInterval = 20
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard (resp as? HTTPURLResponse)?.statusCode == 200 else { throw OpenMeteo.ParseError.unreadable }
            forecast = try OpenMeteo.parse(data)
            source = .openMeteo
            errorText = nil
            log.info("Forecast loaded: \(self.forecast?.days.count ?? 0, privacy: .public) days")
        } catch {
            errorText = "Weather unavailable: \(error.localizedDescription)"
            log.error("Forecast failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private let locator = LocationProvider()

    /// Sets the weather location from the phone's approximate position (one-time; not tracked).
    func useCurrentLocation() async {
        do {
            let loc = try await locator.current()
            latitude = (loc.coordinate.latitude * 100).rounded() / 100
            longitude = (loc.coordinate.longitude * 100).rounded() / 100
            locationName = await LocationProvider.placeName(for: loc) ?? "Current location"
            isConfigured = true
            UserDefaults.standard.set(true, forKey: "weather.configured")
            await refresh(force: true)
        } catch {
            errorText = error.localizedDescription
        }
    }

    func day(_ date: Date) -> DayWeather? {
        forecast?.days[DayRecord.dateKey(for: date)]
    }

    func isHot(_ date: Date) -> Bool {
        forecast?.isHotAfternoon(date, calendar: .current) ?? false
    }
}
