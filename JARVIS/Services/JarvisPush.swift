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
        center.setNotificationCategories([category, question, message])
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

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
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
