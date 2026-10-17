import Foundation

/// User-facing copy. System and provider errors stay in the log; the screen and the voice get a line JARVIS would say.
enum JarvisLines {
    static let tryAgain = "Something went wrong on my side. I'll try again."
    static let network = "I can't reach the network just now. I'll try again in a moment."
    static let busy = "They're a bit busy. I'll try again shortly."
    static let keyRejected = "That service rejected the key. Check Settings when you have a moment."
    static let voiceUnavailable = "I can't use the microphone just now. Give me a moment and try again."
    static let microphoneDenied = "I can't hear you, sir. Microphone and Speech Recognition are off. Turn them on in iPhone Settings, JARVIS."
    static let microphoneClosed = "I can't hear you, sir. Open JARVIS and allow the microphone."
    static let speechUnavailable = "I can't use speech recognition just now, sir."
    static let listening = "Listening, sir."
    static let missedSpeech = "I missed that. Say it once more."
    static let voiceFailed = "My voice didn't come through. I'll try again."
    static let briefingFailed = "I couldn't read the briefing just now. Ask me again in a moment."

    static func explain(_ error: Error) -> String {
        explain(error.localizedDescription)
    }

    static func explain(_ raw: String) -> String {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { return tryAgain }
        if looksTechnical(text) { return mapped(text.lowercased()) }
        if text.count <= 180, !text.contains("\n") { return text }
        return mapped(text.lowercased())
    }

    private static func looksTechnical(_ text: String) -> Bool {
        let lower = text.lowercased()
        let markers = [
            "error domain", "nsurl", "nscocoa", "nsosstatus", "underlying error",
            "json", "http", "status code", "<html", "traceback", "exception",
            "optional(", "swift.", "errno", "timed out", "timeout", "offline",
            "not connected", "network connection", "internet", "socket", "cloud error"
        ]
        if markers.contains(where: { lower.contains($0) }) { return true }
        return lower.range(of: #"error \d"#, options: .regularExpression) != nil
    }

    private static func mapped(_ lower: String) -> String {
        if lower.contains("network") || lower.contains("internet") || lower.contains("offline")
            || lower.contains("not connected") || lower.contains("timed out") || lower.contains("timeout")
            || lower.contains("socket") {
            return network
        }
        if lower.contains("401") || lower.contains("403") || lower.contains("api key")
            || lower.contains("unauthorized") || lower.contains("invalid key") {
            return keyRejected
        }
        if lower.contains("429") || lower.contains("rate") || lower.contains("quota") || lower.contains("busy") {
            return busy
        }
        if lower.contains("microphone") || lower.contains("audio session") || lower.contains("avaudiosession") {
            return voiceUnavailable
        }
        if lower.contains("speech") || lower.contains("recogni") {
            return missedSpeech
        }
        if lower.contains("elevenlabs") || lower.contains("voice") {
            return voiceFailed
        }
        if lower.contains("briefing") {
            return briefingFailed
        }
        return tryAgain
    }
}
