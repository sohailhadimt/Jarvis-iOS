import EventKit
import Foundation
import Observation

/// Weather and the next calendar event for the line under the greeting. Cached, and never on the ring's frame.
@MainActor
@Observable
final class DayGlance {
    static let shared = DayGlance()

    private(set) var line = ""
    private var refreshing = false
    private let cacheKey = "jarvis.glance.cache"
    private let cacheAtKey = "jarvis.glance.cacheAt"

    private init() {
        if let text = UserDefaults.standard.string(forKey: cacheKey),
           Date().timeIntervalSince1970 - UserDefaults.standard.double(forKey: cacheAtKey) < 1800 {
            line = text
        }
    }

    func refresh() async {
        guard AppSettings.shared.glanceEnabled, !refreshing else { return }
        refreshing = true
        defer { refreshing = false }
        async let weather = Self.weather()
        let agenda = Self.agenda()
        var parts: [String] = []
        if let weather = await weather { parts.append(weather) }
        if let agenda { parts.append(agenda) }
        let next = parts.joined(separator: "  ·  ")
        guard !next.isEmpty else { return }
        line = next
        UserDefaults.standard.set(next, forKey: cacheKey)
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: cacheAtKey)
    }

    /// A recent fix when location is allowed. Otherwise Maidstone, Kent. No key.
    private static func weather() async -> String? {
        let spot = DeviceLocation.shared.cached()
        let latitude = spot?.lat ?? 51.27
        let longitude = spot?.lon ?? 0.52
        let place = spot == nil ? "in Kent" : "here"
        guard let line = await DeviceLocation.weatherLine(latitude: latitude, longitude: longitude) else { return nil }
        return "\(line) \(place)"
    }

    private static func agenda() -> String? {
        let store = EKEventStore()
        guard EKEventStore.authorizationStatus(for: .event) == .fullAccess else { return nil }
        let start = Date()
        let end = Calendar.current.date(byAdding: .hour, value: 18, to: start) ?? start
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: nil)
        guard let next = store.events(matching: predicate).sorted(by: { $0.startDate < $1.startDate }).first else { return nil }
        let title = (next.title ?? "something").trimmingCharacters(in: .whitespacesAndNewlines)
        let time = next.startDate.formatted(date: .omitted, time: .shortened)
        return "Next, \(time) \(title)"
    }
}
