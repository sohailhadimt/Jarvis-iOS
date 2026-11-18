import CoreLocation
import Foundation
import UIKit

/// Sends Sir's position to the worker while a caller's 10-minute live location link is open, then stops by itself.
/// Runs only after he taps Allow (or texts YES). The blue location pill shows while it runs.
@MainActor
final class LocationShare: NSObject, CLLocationManagerDelegate {
    static let shared = LocationShare()

    private let manager = CLLocationManager()
    private var until: Date?
    private var lastSent: Date?
    private var stopTask: Task<Void, Never>?

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
        manager.distanceFilter = 10
        manager.pausesLocationUpdatesAutomatically = false
        manager.activityType = .other
    }

    var isSharing: Bool { (until ?? .distantPast) > Date() }

    nonisolated static func parseDate(_ raw: String?) -> Date? {
        guard let raw, !raw.isEmpty else { return nil }
        let full = ISO8601DateFormatter()
        full.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = full.date(from: raw) { return date }
        return ISO8601DateFormatter().date(from: raw)
    }

    /// Starts (or extends) sharing until the worker's hard expiry.
    func start(until end: Date) {
        guard end > Date() else { return }
        until = max(end, until ?? .distantPast)
        lastSent = nil
        switch manager.authorizationStatus {
        case .notDetermined:
            manager.requestWhenInUseAuthorization()
        case .denied, .restricted:
            return
        default:
            break
        }
        if Bundle.main.backgroundModes.contains("location") {
            manager.allowsBackgroundLocationUpdates = true
            manager.showsBackgroundLocationIndicator = true
        }
        manager.startUpdatingLocation()
        stopTask?.cancel()
        let wait = max(1, end.timeIntervalSinceNow)
        stopTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.stop()
        }
    }

    func stop() {
        until = nil
        stopTask?.cancel()
        stopTask = nil
        manager.stopUpdatingLocation()
        if Bundle.main.backgroundModes.contains("location") {
            manager.allowsBackgroundLocationUpdates = false
        }
    }

    /// On launch or return to the app: pick up a share that was allowed by text while JARVIS was closed.
    func resumeIfOpen() async {
        guard let client = try? JarvisCloudAPI.client() else { return }
        if let end = await client.activeLocationShare() {
            start(until: end)
        } else if isSharing {
            stop()
        }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in
            guard self.isSharing else { return }
            let status = self.manager.authorizationStatus
            if status == .authorizedWhenInUse || status == .authorizedAlways {
                self.manager.startUpdatingLocation()
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { return }
        let lat = location.coordinate.latitude
        let lng = location.coordinate.longitude
        let accuracy = max(0, location.horizontalAccuracy)
        Task { @MainActor in self.send(lat: lat, lng: lng, accuracy: accuracy) }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError _: Error) {}

    private func send(lat: Double, lng: Double, accuracy: Double) {
        guard isSharing else {
            stop()
            return
        }
        if let lastSent, Date().timeIntervalSince(lastSent) < 6 { return }
        lastSent = Date()
        guard let client = try? JarvisCloudAPI.client() else { return }
        var background = UIBackgroundTaskIdentifier.invalid
        background = UIApplication.shared.beginBackgroundTask(withName: "location-share") {
            UIApplication.shared.endBackgroundTask(background)
        }
        Task { @MainActor in
            let open = await client.sendLocation(lat: lat, lng: lng, accuracy: accuracy)
            if !open { self.stop() }
            UIApplication.shared.endBackgroundTask(background)
        }
    }
}

private extension Bundle {
    var backgroundModes: [String] { object(forInfoDictionaryKey: "UIBackgroundModes") as? [String] ?? [] }
}
