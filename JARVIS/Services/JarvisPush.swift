import UIKit
import UserNotifications

/// Registers for alerts and turns a screening notification into a worker decision.
final class JarvisPush: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        let actions = [
            UNNotificationAction(identifier: "connect", title: "Put me through", options: [.foreground]),
            UNNotificationAction(identifier: "handle", title: "Let JARVIS handle it", options: []),
            UNNotificationAction(identifier: "message", title: "Take a message", options: []),
            UNNotificationAction(identifier: "decline", title: "Decline", options: [.destructive]),
        ]
        let category = UNNotificationCategory(identifier: "JARVIS_CALL", actions: actions, intentIdentifiers: [], options: [])
        let reply = UNTextInputNotificationAction(
            identifier: "answer",
            title: "Reply",
            options: [],
            textInputButtonTitle: "Send",
            textInputPlaceholder: "What should I tell them?"
        )
        let question = UNNotificationCategory(identifier: "JARVIS_QUESTION", actions: [reply], intentIdentifiers: [], options: [])
        let message = UNNotificationCategory(identifier: "JARVIS_MESSAGE", actions: [], intentIdentifiers: [], options: [])
        let askActions = [
            UNNotificationAction(identifier: "ask_allow", title: "Allow", options: []),
            UNTextInputNotificationAction(
                identifier: "ask_reply",
                title: "Allow and tell them…",
                options: [],
                textInputButtonTitle: "Send",
                textInputPlaceholder: "What JARVIS may say"
            ),
            UNNotificationAction(identifier: "ask_deny", title: "Say I'm busy", options: [.destructive]),
        ]
        let ask = UNNotificationCategory(identifier: "JARVIS_ASK", actions: askActions, intentIdentifiers: [], options: [])
        // Location: Allow opens JARVIS, because iOS only starts location updates from the foreground.
        let whereActions = [
            UNNotificationAction(identifier: "ask_allow", title: "Allow for 10 minutes", options: [.foreground]),
            UNNotificationAction(identifier: "ask_deny", title: "Say I'm busy", options: [.destructive]),
        ]
        let whereAsk = UNNotificationCategory(identifier: "JARVIS_ASK_LOCATION", actions: whereActions, intentIdentifiers: [], options: [])
        center.setNotificationCategories([category, question, message, ask, whereAsk])
        // Scene-based apps never get applicationDidBecomeActive; pick up a share allowed by text while JARVIS was closed.
        NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
            Task { @MainActor in await LocationShare.shared.resumeIfOpen() }
        }
        center.requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in
            DispatchQueue.main.async {
                application.registerForRemoteNotifications()
            }
        }
        return true
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        let token = deviceToken.map { String(format: "%02x", $0) }.joined()
        Task { @MainActor in
            CallDevice.remember(token)
            await CallDevice.uploadIfNeeded()
        }
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        _ = error
    }

    /// The worker's silent nudge when Sir allowed a location share by text while JARVIS was closed.
    func application(_ application: UIApplication, didReceiveRemoteNotification userInfo: [AnyHashable: Any]) async -> UIBackgroundFetchResult {
        guard userInfo["kind"] as? String == "location_share" else { return .noData }
        await startShare(userInfo)
        return .newData
    }

    private func startShare(_ info: [AnyHashable: Any]) async {
        let end = LocationShare.parseDate(info["expires_at"] as? String)
        await MainActor.run {
            if let end { LocationShare.shared.start(until: end) }
        }
        if end == nil { await LocationShare.shared.resumeIfOpen() }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        if notification.request.content.userInfo["kind"] as? String == "location_share" {
            await startShare(notification.request.content.userInfo)
        }
        if notification.request.content.userInfo["kind"] as? String == "call_message" {
            CallMessageLink.post(notification.request.content.userInfo)
            return [.banner, .sound]
        }
        return [.banner, .sound]
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let info = response.notification.request.content.userInfo
        if info["kind"] as? String == "call_message" {
            CallMessageLink.post(info)
            return
        }
        if info["kind"] as? String == "briefing" {
            await MainActor.run {
                NotificationCenter.default.post(name: .jarvisDeliverBriefing, object: nil)
            }
            return
        }
        guard let client = try? await MainActor.run(body: { try JarvisCloudAPI.client() }) else { return }
        if info["kind"] as? String == "owner_request", let requestId = info["request_id"] as? String {
            let typed = (response as? UNTextInputNotificationResponse)?.userText.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let allow: Bool
            switch response.actionIdentifier {
            case "ask_allow", "ask_reply": allow = true
            case "ask_deny": allow = false
            default: return
            }
            let result = await client.decideOwnerRequest(id: requestId, allow: allow, answer: allow ? typed : "")
            if let end = result.shareExpiresAt {
                await MainActor.run { LocationShare.shared.start(until: end) }
            }
            return
        }
        if info["kind"] as? String == "location_share" {
            await startShare(info)
            return
        }
        if let typed = response as? UNTextInputNotificationResponse,
           let callId = info["call_id"] as? String,
           let questionId = info["question_id"] as? String {
            _ = await client.answerCallQuestion(callId: callId, questionId: questionId, text: typed.userText)
            return
        }
        let action: String
        switch response.actionIdentifier {
        case "connect": action = "connect"
        case "handle": action = "handle"
        case "message": action = "message"
        case "decline": action = "decline"
        default: return
        }
        guard let id = info["call_id"] as? String else { return }
        _ = await client.screenCall(id: id, action: action)
    }
}

/// Holds the message id from a notification tap until the home screen can open that card.
enum CallMessageLink {
    static var pendingID: String?

    static func post(_ info: [AnyHashable: Any]) {
        let raw = info["message_id"] as? String
        let id = raw?.hasPrefix("cmsg_") == true ? raw : nil
        pendingID = id
        var userInfo: [String: String] = [:]
        if let id { userInfo["message_id"] = id }
        NotificationCenter.default.post(name: .jarvisCallMessage, object: nil, userInfo: userInfo)
    }
}
