import Foundation
import os

/// Milliseconds from the end of the user's speech to the first streamed audio.
enum LatencyLog {
    private static let log = Logger(subsystem: "com.sohail.jarvis", category: "latency")
    private static var turnStart: Date?

    static func beginTurn(_ name: String) {
        turnStart = Date()
        log.info("\(name, privacy: .public)")
    }

    /// Last moment the user was still speaking. Later events are measured from here.
    static func noteSpeechEnd() {
        turnStart = Date()
    }

    static func noteSpeechEndIfNeeded() {
        if turnStart == nil {
            turnStart = Date()
        }
    }

    static func clear() {
        turnStart = nil
    }

    static func event(_ name: String) {
        guard let turnStart else {
            log.info("\(name, privacy: .public)")
            return
        }
        let elapsed: Double = Date().timeIntervalSince(turnStart) * 1000.0
        let rounded: Int = Int(elapsed.rounded())
        log.info("\(name, privacy: .public) +\(rounded)ms")
    }
}
