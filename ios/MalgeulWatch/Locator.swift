import Foundation
import CoreLocation

/// 녹음 시작 위치를 한 번 잡아 장소 이름(동네·도로명)으로 바꿈
final class Locator: NSObject, CLLocationManagerDelegate {
    struct Fix {
        var latitude: Double
        var longitude: Double
        var place: String
    }

    private let manager = CLLocationManager()
    private let geocoder = CLGeocoder()
    private var onFix: ((Fix) -> Void)?
    private(set) var isBusy = false

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
    }

    func start(_ onFix: @escaping (Fix) -> Void) {
        self.onFix = onFix
        isBusy = true
        switch manager.authorizationStatus {
        case .notDetermined: manager.requestWhenInUseAuthorization()
        case .denied, .restricted: isBusy = false
        default: manager.requestLocation()
        }
    }

    func cancel() {
        isBusy = false
        onFix = nil
        manager.stopUpdatingLocation()
        geocoder.cancelGeocode()
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        guard isBusy else { return }
        switch manager.authorizationStatus {
        case .authorizedWhenInUse, .authorizedAlways: manager.requestLocation()
        case .denied, .restricted: isBusy = false
        default: break
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard isBusy, let loc = locations.last else { return }
        let la = loc.coordinate.latitude, lo = loc.coordinate.longitude
        let fallback = String(format: "%.5f, %.5f", la, lo)
        geocoder.reverseGeocodeLocation(loc, preferredLocale: Locale(identifier: "ko_KR")) { [weak self] marks, _ in
            guard let self, self.isBusy else { return }
            var parts: [String] = []
            if let p = marks?.first {
                for s in [p.locality ?? p.administrativeArea, p.subLocality, p.thoroughfare, p.subThoroughfare] {
                    if let s, !s.isEmpty, !parts.contains(s) { parts.append(s) }
                }
                if let n = p.name, !n.isEmpty, !parts.contains(where: { n.contains($0) }) { parts.append(n) }
            }
            let place = parts.isEmpty ? fallback : parts.joined(separator: " ")
            self.onFix?(Fix(latitude: la, longitude: lo, place: place))   // 메인 스레드에서 바로 반영한 뒤 끝 표시
            self.isBusy = false
        }
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        isBusy = false
    }
}
