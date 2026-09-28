import Foundation
import os

/// Forecast for the training location, from Apple Weather (WeatherKit). Only the coordinates,
/// rounded to about 1 km, leave the phone. Cached in memory for 30 minutes.
///
/// Until v2.10 this tried WeatherKit and fell back to Open-Meteo. The entitlement was never
/// added, so every forecast came from Open-Meteo, and one failure switched Apple Weather off for
/// the rest of the session. Now there's one source, and a setup problem is shown as one.
@MainActor
final class WeatherModel: ObservableObject {

    @Published private(set) var forecast: Forecast?
    @Published private(set) var errorText: String?
    @Published private(set) var attribution: AppleWeather.Attribution?
    /// Whether WeatherKit answers for this build, from the last forecast or check. Shown in
    /// Settings because a missing portal switch looked exactly like "no forecast yet".
    @Published private(set) var status: ServiceStatus = .unchecked
    @Published private(set) var statusCheckedAt: Date?
    /// What Apple actually said when the last check failed, for telling a portal switch apart from
    /// a propagation delay or an expired profile. Error type and code only; no location in it.
    @Published private(set) var statusDetail: String?
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
        do {
            forecast = try await AppleWeather.forecast(latitude: latitude, longitude: longitude)
            errorText = nil
            record(.working)
            if attribution == nil { attribution = try? await AppleWeather.attribution() }
            log.info("Forecast loaded: \(self.forecast?.days.count ?? 0, privacy: .public) days")
        } catch {
            errorText = AppleWeather.isSetupProblem(error)
                ? "Apple Weather isn't enabled for this app yet. In the Apple Developer portal, turn on WeatherKit for the App ID under both Capabilities and App Services, then rebuild."
                : "Weather unavailable: \(error.localizedDescription)"
            record(ServiceStatus(error), detail: Self.describe(error))
            log.error("Forecast failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    enum ServiceStatus: Equatable {
        case unchecked, checking, working, notEnabled
        case unavailable(String)

        init(_ error: Error) {
            self = AppleWeather.isSetupProblem(error) ? .notEnabled : .unavailable(error.localizedDescription)
        }
    }

    private func record(_ s: ServiceStatus, detail: String? = nil) {
        status = s
        statusCheckedAt = .now
        statusDetail = detail
    }

    static func describe(_ error: Error) -> String {
        let ns = error as NSError
        return "\(String(describing: type(of: error))) · \(ns.domain) \(ns.code) · \(String(describing: error).prefix(160))"
    }

    /// Asks WeatherKit for one day at a fixed place (Apple Park), so the check works before a
    /// training location is set and never sends the athlete's own position.
    func checkService() async {
        guard status != .checking else { return }
        status = .checking
        do {
            try await AppleWeather.probe()
            record(.working)
        } catch {
            record(ServiceStatus(error), detail: Self.describe(error))
        }
        log.info("WeatherKit check: \(self.status == .working ? "working" : "failed", privacy: .public)")
    }

    private let locator = LocationProvider()

    /// Sets the weather location from the phone's approximate position (one-time; not tracked).
    func useCurrentLocation() async {
        do {
            let loc = try await locator.current()
            latitude = WeatherPrivacy.rounded(loc.coordinate.latitude)
            longitude = WeatherPrivacy.rounded(loc.coordinate.longitude)
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
