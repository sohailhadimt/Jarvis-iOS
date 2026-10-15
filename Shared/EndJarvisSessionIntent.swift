import AppIntents
import Foundation

/// Used by the Live Activity / Dynamic Island "end" button.
/// It is compiled into BOTH targets; as a LiveActivityIntent the system runs `perform()` in the app process.
struct EndJarvisSessionIntent: LiveActivityIntent {
    static var title: LocalizedStringResource { "End JARVIS Session" }
    static var description: IntentDescription { IntentDescription("Stops listening and ends the JARVIS Live Activity.") }

    init() {}

    @MainActor
    func perform() async throws -> some IntentResult {
        #if !WIDGET_EXTENSION
        await AssistantEngine.shared.endSession()
        #endif
        return .result()
    }
}
