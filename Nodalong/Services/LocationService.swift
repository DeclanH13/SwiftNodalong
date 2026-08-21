import CoreLocation
import NodalongKit

/// CoreLocation wrapper that publishes the user's current 9-character geohash.
///
/// Requests one-shot location updates (not continuous tracking) — saves
/// battery, and Nodalong only needs an occasional fix to update
/// `users/{uid}.geohash`. The published geohash powers the Near Me tab; other
/// clients fetch neighbours via 5-character prefix matching against that
/// field.
@MainActor
final class LocationService: NSObject, ObservableObject {
    @Published private(set) var geohash: String? = nil
    @Published private(set) var authorizationStatus: CLAuthorizationStatus = .notDetermined

    private let manager = CLLocationManager()

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
        authorizationStatus = manager.authorizationStatus
        if authorizationStatus == .authorizedWhenInUse || authorizationStatus == .authorizedAlways {
            manager.requestLocation()
        }
    }

    func requestLocation() {
        switch manager.authorizationStatus {
        case .notDetermined:
            manager.requestWhenInUseAuthorization()
        case .authorizedWhenInUse, .authorizedAlways:
            manager.requestLocation()
        default:
            break
        }
    }
}

extension LocationService: CLLocationManagerDelegate {
    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let loc = locations.first else { return }
        let hash = encodeGeohash(
            lat: loc.coordinate.latitude,
            lng: loc.coordinate.longitude,
            precision: geohashPrecision
        )
        Task { @MainActor in self.geohash = hash }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {}

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor in
            self.authorizationStatus = status
            if status == .authorizedWhenInUse || status == .authorizedAlways {
                manager.requestLocation()
            }
        }
    }
}
