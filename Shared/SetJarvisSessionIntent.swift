import AppIntents
import Foundation
import os

private let controlLog = Logger(subsystem: "com.sohail.jarvis", category: "control")

/// Control Center and Action Button > Controls toggle.
///
/// Compiled into the app and the widget extension. `AudioRecordingIntent` makes iOS run
/// `perform()` in the app process. The widget copy must not record: an extension is
/// suspended as soon as `perform()` returns, which dismisses the Live Activity.
/// `openAppWhenRun` stays false so the press does not bring JARVIS forward.
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
        #if WIDGET_EXTENSION
        controlLog.error("SetJarvisSessionIntent.perform ran in the widget extension; the app process must record")
        #else
        try await runInApp()
        #endif
        return .result()
    }
}

#if !WIDGET_EXTENSION
/// Unavailable in app extensions. The widget target defines WIDGET_EXTENSION, so only the app conforms.
extension SetJarvisSessionIntent: ForegroundContinuableIntent {}

extension SetJarvisSessionIntent {
    @MainActor
    fileprivate func runInApp() async throws {
        controlLog.info("perform in app, value=\(self.value ? "on" : "off", privacy: .public)")
        if !value {
            await AssistantEngine.shared.endSession(reason: "control-off")
            return
        }
        let outcome = await AssistantEngine.shared.startSession(continuous: true)
        if outcome == .needsForeground {
            controlLog.error("Live Activity or audio session unavailable in background; continuing in foreground")
            _ = try await requestToContinueInForeground(nil) {
                await AssistantEngine.shared.waitUntilForeground()
                _ = await AssistantEngine.shared.startSession(continuous: true)
            }
        }
    }
}
#endif
