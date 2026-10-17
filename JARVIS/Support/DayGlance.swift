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

    /// Maidstone, Kent. No key. A failure leaves the greeting alone.
    private static func weather() async -> String? {
        var parts = URLComponents(string: "https://api.open-meteo.com/v1/forecast")
        parts?.queryItems = [
            URLQueryItem(name: "latitude", value: "51.27"),
            URLQueryItem(name: "longitude", value: "0.52"),
            URLQueryItem(name: "current", value: "temperature_2m,weather_code"),
            URLQueryItem(name: "timezone", value: "Europe/London"),
        ]
        guard let url = parts?.url else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 6
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let current = json["current"] as? [String: Any],
              let temp = current["temperature_2m"] as? Double else { return nil }
        let code = current["weather_code"] as? Int ?? 0
        let rounded = Int(temp.rounded())
        return "\(rounded)° and \(word(for: code)) in Kent"
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
