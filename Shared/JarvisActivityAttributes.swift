import ActivityKit
import Foundation

enum JarvisPhase: String, Codable, Hashable, Sendable {
    case idle, listening, thinking, speaking

    var label: String {
        switch self {
        case .idle: "Standing by"
        case .listening: "Listening"
        case .thinking: "Thinking"
        case .speaking: "Responding"
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
        /// Set while a screened or outbound call is still open. Empty when there is no call.
        var callStatus: String

        init(phase: JarvisPhase, transcript: String, reply: String, callStatus: String = "") {
            self.phase = phase
            self.transcript = transcript
            self.reply = reply
            self.callStatus = callStatus
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            phase = try container.decode(JarvisPhase.self, forKey: .phase)
            transcript = try container.decode(String.self, forKey: .transcript)
            reply = try container.decode(String.self, forKey: .reply)
            callStatus = try container.decodeIfPresent(String.self, forKey: .callStatus) ?? ""
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(phase, forKey: .phase)
            try container.encode(transcript, forKey: .transcript)
            try container.encode(reply, forKey: .reply)
            try container.encode(callStatus, forKey: .callStatus)
        }

        private enum CodingKeys: String, CodingKey {
            case phase, transcript, reply, callStatus
        }

        var headline: String {
            if phase == .idle, !callStatus.isEmpty { return callStatus }
            return phase.label
        }

        var headlineSymbol: String {
            if phase == .idle, !callStatus.isEmpty { return "phone.fill" }
            return phase.symbol
        }
    }

    var sessionName: String
}
