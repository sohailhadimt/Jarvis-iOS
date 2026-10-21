import Foundation
import os

struct LatencySnapshot: Sendable {
    var voiceProcessing: Bool
    var lastFirstAudioMs: Int?
    var falseTriggers: Int
    var fillers: Int
}

/// Milliseconds from the end of the user's speech to the first streamed audio.
enum LatencyLog {
    private static let log = Logger(subsystem: "com.sohail.jarvis", category: "latency")
    private static let lock = NSLock()
    private static var turnStart: Date?
    private static var voiceProcessing = false
    private static var falseTriggers = 0
    private static var lastFirstAudioMs: Int?
    private static var replyHeard = false
    private static var fillerCount = 0

    static func beginTurn(_ name: String) {
        lock.lock()
        turnStart = Date()
        lock.unlock()
        log.info("\(name, privacy: .public)")
    }

    /// Last moment the user was still speaking. Later events are measured from here.
    static func noteSpeechEnd() {
        lock.lock()
        turnStart = Date()
        replyHeard = false
        lock.unlock()
    }

    static var replyAudioHeard: Bool {
        lock.lock()
        defer { lock.unlock() }
        return replyHeard
    }

    static func noteSpeechEndIfNeeded() {
        lock.lock()
        if turnStart == nil {
            turnStart = Date()
            replyHeard = false
        }
        lock.unlock()
    }

    static func clear() {
        lock.lock()
        turnStart = nil
        lock.unlock()
    }

    /// Hardware voice processing on the capture engine. The simulator often refuses this.
    static func noteVoiceProcessing(_ enabled: Bool) {
        lock.lock()
        voiceProcessing = enabled
        lock.unlock()
        log.info("voice processing \(enabled ? "on" : "off", privacy: .public)")
    }

    /// A click, cough, or empty recognition that did not become a reply.
    static func noteFalseTrigger() {
        lock.lock()
        falseTriggers += 1
        lock.unlock()
    }

    static func noteFiller() {
        lock.lock()
        fillerCount += 1
        lock.unlock()
    }

    static func snapshot() -> LatencySnapshot {
        lock.lock()
        defer { lock.unlock() }
        return LatencySnapshot(
            voiceProcessing: voiceProcessing,
            lastFirstAudioMs: lastFirstAudioMs,
            falseTriggers: falseTriggers,
            fillers: fillerCount
        )
    }

    static func event(_ name: String) {
        lock.lock()
        let start = turnStart
        lock.unlock()
        guard let start else {
            log.info("\(name, privacy: .public)")
            return
        }
        let elapsed: Double = Date().timeIntervalSince(start) * 1000.0
        let rounded: Int = Int(elapsed.rounded())
        if name == "tts-first-audio" {
            lock.lock()
            lastFirstAudioMs = rounded
            replyHeard = true
            lock.unlock()
        }
        log.info("\(name, privacy: .public) +\(rounded)ms")
    }
}
