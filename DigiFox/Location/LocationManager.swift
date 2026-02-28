import Foundation
import CoreLocation

/// Converts geographic coordinates to Maidenhead grid locator.
/// Supports 4-char (e.g. JO31) and 6-char (e.g. JO31le) precision.
func maidenheadLocator(latitude: Double, longitude: Double, precision: Int = 4) -> String {
    let lon = longitude + 180.0
    let lat = latitude + 90.0

    var locator = ""

    // Field (18x18, 20° lon x 10° lat)
    let fieldLon = Int(lon / 20.0)
    let fieldLat = Int(lat / 10.0)
    locator += String(UnicodeScalar(65 + min(fieldLon, 17))!)
    locator += String(UnicodeScalar(65 + min(fieldLat, 17))!)

    // Square (10x10, 2° lon x 1° lat)
    let sqLon = Int((lon - Double(fieldLon) * 20.0) / 2.0)
    let sqLat = Int(lat - Double(fieldLat) * 10.0)
    locator += "\(min(sqLon, 9))"
    locator += "\(min(sqLat, 9))"

    guard precision >= 6 else { return locator }

    // Subsquare (24x24, 5' lon x 2.5' lat)
    let subLon = (lon - Double(fieldLon) * 20.0 - Double(sqLon) * 2.0) / (2.0 / 24.0)
    let subLat = (lat - Double(fieldLat) * 10.0 - Double(sqLat) * 1.0) / (1.0 / 24.0)
    locator += String(UnicodeScalar(97 + min(Int(subLon), 23))!)
    locator += String(UnicodeScalar(97 + min(Int(subLat), 23))!)

    return locator
}

/// Observable location manager that provides a one-shot GPS fix
/// and converts it to a Maidenhead grid locator.
class LocationManager: NSObject, ObservableObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()

    @Published var grid: String?
    @Published var isLocating = false
    @Published var error: String?

    private var completion: ((String?) -> Void)?

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
    }

    /// Request a single location fix and return the grid locator.
    func requestGrid(completion: @escaping (String?) -> Void) {
        self.completion = completion
        self.error = nil
        self.isLocating = true

        switch manager.authorizationStatus {
        case .notDetermined:
            manager.requestWhenInUseAuthorization()
        case .authorizedWhenInUse, .authorizedAlways:
            manager.requestLocation()
        default:
            self.error = "Location access denied"
            self.isLocating = false
            completion(nil)
        }
    }

    // MARK: - CLLocationManagerDelegate

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        if manager.authorizationStatus == .authorizedWhenInUse ||
           manager.authorizationStatus == .authorizedAlways {
            manager.requestLocation()
        } else if manager.authorizationStatus == .denied || manager.authorizationStatus == .restricted {
            error = "Location access denied"
            isLocating = false
            completion?(nil)
            completion = nil
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let loc = locations.last else { return }
        let g = maidenheadLocator(latitude: loc.coordinate.latitude, longitude: loc.coordinate.longitude, precision: 6)
        grid = g
        isLocating = false
        completion?(g)
        completion = nil
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        self.error = "Location error: \(error.localizedDescription)"
        isLocating = false
        completion?(nil)
        completion = nil
    }
}
