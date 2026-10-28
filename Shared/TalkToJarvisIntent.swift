import AppIntents
import Foundation

/// Opens JARVIS straight into a listening session.
/// Siri ("Hey Siri, JARVIS" / "Talk to JARVIS"), the Action Button control, and
/// Control Center all use this intent. `openAppWhenRun` brings the app forward.
struct TalkToJarvisIntent: AppIntent {
    static var title: LocalizedStringResource { "Talk to JARVIS" }
    static var description: IntentDescription {
        IntentDescription("Opens JARVIS and starts listening.")
    }
    static var openAppWhenRun: Bool = true

    init() {}

    @MainActor
    func perform() async throws -> some IntentResult {
        #if !WIDGET_EXTENSION
        JarvisStartListening.request()
        #endif
        return .result()
    }
}
