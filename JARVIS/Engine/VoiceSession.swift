import Foundation
import Observation

/// Voice-mode states. `AssistantEngine.voiceState` is the live value.
enum VoiceState: Equatable {
    case off
    case connecting
    case listening
    case userSpeaking
    case thinking
    case aiSpeaking
    case muted
    case error
    case ended
}

/// UI state for in-chat and full-screen voice. The engine publishes `VoiceState`;
/// this object keeps the chrome (chat presented, captions, transcript) across the exit animation.
@MainActor
@Observable
final class VoiceSession {
    static let shared = VoiceSession()

    var chatPresented = false
    var captionsOn: Bool
    var showTranscript = false
    var exiting = false

    private init() {
        captionsOn = AppSettings.shared.captionsDefault
    }
}
