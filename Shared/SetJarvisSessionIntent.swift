import AppIntents
import Foundation

/// Control Center and Action Button > Controls toggle.
///
/// Compiled into the app and the widget extension (`Shared/` is in both targets).
/// `AudioRecordingIntent` is a `LiveActivityIntent`, so iOS runs `perform()` in the app
/// process and can record in the background while a Live Activity is active.
/// `SetValueIntent` is what `ControlWidgetToggle` requires. `openAppWhenRun` stays false
/// so the press does not bring JARVIS forward.
struct SetJarvisSessionIntent: AudioRecordingIntent, SetValueIntent {
    static var title: LocalizedStringResource { "JARVIS" }
    static var description: IntentDescription {
        IntentDescription("Starts or ends a JARVIS session in the Dynamic Island.")
    }
    static var openAppWhenRun: Bool = false
    static var isDiscoverable: Bool = false

    @Parameter(title: "Session Active")
    var value: Bool

    init() {
        self.value = false
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        #if !WIDGET_EXTENSION
        if value {
            await AssistantEngine.shared.startSession(continuous: true)
        } else {
            await AssistantEngine.shared.endSession()
        }
        #endif
        return .result()
    }
}
