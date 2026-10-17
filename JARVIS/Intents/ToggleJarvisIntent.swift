import AppIntents
import Foundation

/// Shortcut list entry for "Toggle JARVIS".
/// The Action Button control "Talk to JARVIS" uses TalkToJarvisIntent instead.
/// AudioRecordingIntent (iOS 18+) lets the app start recording from the background,
/// provided a Live Activity is started while the intent runs, which startSession() does.
struct ToggleJarvisIntent: AudioRecordingIntent {
    static var title: LocalizedStringResource { "Toggle JARVIS" }
    static var description: IntentDescription {
        IntentDescription("Starts a hands-free JARVIS session, or ends it if one is running.")
    }

    init() {}

    @MainActor
    func perform() async throws -> some IntentResult {
        await AssistantEngine.shared.toggleSession()
        return .result()
    }
}

/// Phrases must include the app name, and each phrase can belong to only one shortcut.
/// A duplicate phrase makes iOS drop the whole provider, so the app never appears in Choose a Shortcut.
struct JarvisShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: TalkToJarvisIntent(),
                    phrases: [
                        "\(.applicationName)",
                        "Talk to \(.applicationName)",
                        "Ask \(.applicationName)",
                        "Listen with \(.applicationName)",
                    ],
                    shortTitle: "Talk to JARVIS",
                    systemImageName: "mic.fill")
        AppShortcut(intent: ToggleJarvisIntent(),
                    phrases: [
                        "Toggle \(.applicationName)",
                    ],
                    shortTitle: "Toggle JARVIS",
                    systemImageName: "waveform.circle.fill")
    }
}

/// The intent runs as the app is opening, sometimes before any view exists.
/// The flag survives that gap; the notification covers an app that is already on screen.
enum JarvisStartListening {
    static let notification = Notification.Name("JARVISStartListening")
    private static let pendingKey = "jarvis.pendingStartListening"

    @MainActor
    static func request() {
        UserDefaults.standard.set(true, forKey: pendingKey)
        NotificationCenter.default.post(name: notification, object: nil)
    }

    @MainActor
    static var isPending: Bool {
        UserDefaults.standard.bool(forKey: pendingKey)
    }

    @MainActor
    static func consume() -> Bool {
        guard UserDefaults.standard.bool(forKey: pendingKey) else { return false }
        UserDefaults.standard.set(false, forKey: pendingKey)
        return true
    }
}
