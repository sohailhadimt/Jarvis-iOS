import Foundation
import UserNotifications

extension Notification.Name {
    static let jarvisDeliverBriefing = Notification.Name("jarvisDeliverBriefing")
}

/// Local reminder for the morning briefing. The worker routine stays in Agents and starts off.
enum BriefingClock {
    static let requestID = "jarvis.daily.briefing"
    private static let deliveredKey = "jarvis.briefing.delivered"

    static func schedule() {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [requestID])
        guard AppSettings.shared.briefingEnabled else { return }
        var parts = DateComponents()
        parts.hour = AppSettings.shared.briefingHour
        parts.minute = AppSettings.shared.briefingMinute
        parts.timeZone = TimeZone(identifier: "Europe/London")
        let content = UNMutableNotificationContent()
        content.title = "JARVIS"
        content.body = "Your briefing is ready, sir."
        content.sound = .default
        content.userInfo = ["kind": "briefing"]
        let trigger = UNCalendarNotificationTrigger(dateMatching: parts, repeats: true)
        center.add(UNNotificationRequest(identifier: requestID, content: content, trigger: trigger))
    }

    static func due(now: Date = Date()) -> Bool {
        guard AppSettings.shared.briefingEnabled else { return false }
        guard UserDefaults.standard.string(forKey: deliveredKey) != dayKey(now) else { return false }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/London") ?? .current
        let parts = calendar.dateComponents([.hour, .minute], from: now)
        let minutes = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
        let target = AppSettings.shared.briefingHour * 60 + AppSettings.shared.briefingMinute
        return minutes >= target
    }

    static func markDelivered(now: Date = Date()) {
        UserDefaults.standard.set(dayKey(now), forKey: deliveredKey)
    }

    private static func dayKey(_ date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/London") ?? .current
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }
}
