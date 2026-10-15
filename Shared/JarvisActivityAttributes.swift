import ActivityKit
import Foundation

enum JarvisPhase: String, Codable, Hashable, Sendable {
    case idle, listening, thinking, speaking

    var label: String {
        switch self {
        case .idle: "Standing by"
        case .listening: "Listening"
        case .thinking: "Thinking"
        case .speaking: "Speaking"
        }
    }

    var symbol: String {
        switch self {
        case .idle: "circle.dotted"
        case .listening: "waveform"
        case .thinking: "ellipsis"
        case .speaking: "speaker.wave.2.fill"
        }
    }
}

struct JarvisActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable, Sendable {
        var phase: JarvisPhase
        var transcript: String
        var reply: String
    }

    var sessionName: String
}
