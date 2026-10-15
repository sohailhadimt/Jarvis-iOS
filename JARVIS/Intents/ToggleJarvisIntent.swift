import AppIntents
import Foundation

/// Assign to the Action Button: Settings > Action Button > Shortcut > JARVIS > Toggle JARVIS.
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

struct JarvisShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: ToggleJarvisIntent(),
                    phrases: ["Toggle \(.applicationName)", "Talk to \(.applicationName)"],
                    shortTitle: "Toggle JARVIS",
                    systemImageName: "waveform.circle.fill")
    }
}
