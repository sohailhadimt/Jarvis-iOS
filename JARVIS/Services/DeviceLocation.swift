import CoreLocation
import Foundation

/// When-in-use location for weather and nearby questions. The system sheet uses the Info.plist string.
@MainActor
final class DeviceLocation: NSObject, CLLocationManagerDelegate {
    static let shared = DeviceLocation()

    private let manager = CLLocationManager()
    private var latitude: Double?
    private var longitude: Double?
    private var fixedAt: Date?
    private var waiter: CheckedContinuation<(lat: Double, lon: Double)?, Never>?

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
    }

    /// Shows the system prompt once, or refreshes a fix when access is already allowed.
    func prepare() {
        switch manager.authorizationStatus {
        case .notDetermined:
            manager.requestWhenInUseAuthorization()
        case .authorizedWhenInUse, .authorizedAlways:
            manager.requestLocation()
        default:
            break
        }
    }

    func cached() -> (lat: Double, lon: Double)? {
        guard let latitude, let longitude, let fixedAt else { return nil }
        guard Date().timeIntervalSince(fixedAt) < 600 else { return nil }
        return (latitude, longitude)
    }

    /// Waits for the prompt if needed, then for one fix. A recent fix returns immediately.
    func fix() async -> (lat: Double, lon: Double)? {
        if let cached = cached() { return cached }
        let status = manager.authorizationStatus
        if status == .denied || status == .restricted { return nil }
        return await withCheckedContinuation { continuation in
            waiter?.resume(returning: cached())
            waiter = continuation
            if status == .notDetermined {
                manager.requestWhenInUseAuthorization()
            } else {
                manager.requestLocation()
            }
            let wait: Double = status == .notDetermined ? 25 : 6
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(wait))
                self.finish(self.cached())
            }
        }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor in
            if status == .authorizedWhenInUse || status == .authorizedAlways {
                self.manager.requestLocation()
            } else if status == .denied || status == .restricted {
                self.finish(nil)
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { return }
        let lat = location.coordinate.latitude
        let lon = location.coordinate.longitude
        Task { @MainActor in
            self.store(lat: lat, lon: lon)
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError _: Error) {
        Task { @MainActor in
            self.finish(self.cached())
        }
    }

    private func store(lat: Double, lon: Double) {
        latitude = lat
        longitude = lon
        fixedAt = Date()
        finish((lat, lon))
    }

    private func finish(_ value: (lat: Double, lon: Double)?) {
        let waiting = waiter
        waiter = nil
        waiting?.resume(returning: value)
    }

    /// Open-Meteo, no key. Nil when the request fails.
    static func weatherLine(latitude: Double, longitude: Double) async -> String? {
        var parts = URLComponents(string: "https://api.open-meteo.com/v1/forecast")
        parts?.queryItems = [
            URLQueryItem(name: "latitude", value: String(latitude)),
            URLQueryItem(name: "longitude", value: String(longitude)),
            URLQueryItem(name: "current", value: "temperature_2m,weather_code"),
            URLQueryItem(name: "daily", value: "temperature_2m_max,temperature_2m_min"),
            URLQueryItem(name: "forecast_days", value: "1"),
            URLQueryItem(name: "timezone", value: "auto"),
        ]
        guard let url = parts?.url else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 6
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let current = json["current"] as? [String: Any],
              let temp = Self.number(current["temperature_2m"]) else { return nil }
        let code = Int(Self.number(current["weather_code"]) ?? 0)
        var high: Int?
        var low: Int?
        if let daily = json["daily"] as? [String: Any] {
            high = Self.number((daily["temperature_2m_max"] as? [Any])?.first).map { Int($0.rounded()) }
            low = Self.number((daily["temperature_2m_min"] as? [Any])?.first).map { Int($0.rounded()) }
        }
        let rounded = Int(temp.rounded())
        var line = "\(rounded) degrees and \(Self.word(for: code))"
        if let high, let low { line += ", high \(high), low \(low)" }
        return line
    }

    private static func number(_ value: Any?) -> Double? {
        if let number = value as? Double { return number }
        if let number = value as? Int { return Double(number) }
        if let number = value as? NSNumber { return number.doubleValue }
        return nil
    }

    private static func word(for code: Int) -> String {
        switch code {
        case 0: "clear"
        case 1, 2: "fair"
        case 3: "cloudy"
        case 45, 48: "foggy"
        case 51, 53, 55, 56, 57: "drizzle"
        case 61, 63, 65, 80, 81, 82: "rain"
        case 71, 73, 75, 77, 85, 86: "snow"
        case 95, 96, 99: "storms"
        default: "unsettled"
        }
    }
}
