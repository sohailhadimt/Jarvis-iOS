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
        center.setNotificationCategories([category])
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
        [.banner, .sound]
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let action: String
        switch response.actionIdentifier {
        case "connect": action = "connect"
        case "handle": action = "handle"
        case "message": action = "message"
        case "decline": action = "decline"
        default: return
        }
        let info = response.notification.request.content.userInfo
        guard let id = info["call_id"] as? String else { return }
        guard let client = try? await MainActor.run(body: { try JarvisCloudAPI.client() }) else { return }
        _ = await client.screenCall(id: id, action: action)
    }
}
