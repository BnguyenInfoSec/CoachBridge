import CoreLocation

/// One-shot, approximate (~1 km) location for the weather forecast. Nothing is stored except
/// the rounded coordinates and place name you see in Plan settings.
@MainActor
final class LocationProvider: NSObject, CLLocationManagerDelegate {
    enum LocationError: LocalizedError {
        case denied
        var errorDescription: String? {
            "Location is off for Coach Bridge. Turn it on in Settings → Privacy & Security → Location Services, or enter coordinates."
        }
    }

    private let manager = CLLocationManager()
    private var continuation: CheckedContinuation<CLLocation, Error>?

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyKilometer
    }

    func current() async throws -> CLLocation {
        try await withCheckedThrowingContinuation { c in
            continuation = c
            switch manager.authorizationStatus {
            case .notDetermined: manager.requestWhenInUseAuthorization()   // continues in the auth callback
            case .authorizedWhenInUse, .authorizedAlways: manager.requestLocation()
            default: finish(.failure(LocationError.denied))
            }
        }
    }

    /// "Chula Vista", "Carlsbad", …
    static func placeName(for location: CLLocation) async -> String? {
        let marks = try? await CLGeocoder().reverseGeocodeLocation(location)
        return marks?.first?.locality ?? marks?.first?.name
    }

    private func finish(_ result: Result<CLLocation, Error>) {
        continuation?.resume(with: result)
        continuation = nil
    }

    nonisolated func locationManagerDidChangeAuthorization(_ m: CLLocationManager) {
        let status = m.authorizationStatus
        Task { @MainActor in
            guard self.continuation != nil else { return }
            switch status {
            case .authorizedWhenInUse, .authorizedAlways: self.manager.requestLocation()
            case .notDetermined: break
            default: self.finish(.failure(LocationError.denied))
            }
        }
    }

    nonisolated func locationManager(_ m: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let loc = locations.last else { return }
        Task { @MainActor in self.finish(.success(loc)) }
    }

    nonisolated func locationManager(_ m: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in self.finish(.failure(error)) }
    }
}
