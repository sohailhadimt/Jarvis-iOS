import Foundation

/// Gemini 3.8 Live. Checked against the Live API guide, September 2026.
/// Native audio models accept AUDIO responses only. TEXT is requested first because the model card
/// also lists text output. A modality rejection reconnects with AUDIO plus output transcription,
/// which keeps server VAD, and that transcript is what George speaks.
enum LiveModel {
    static let current = "gemini-3.8-live"
    static let socketHost =
        "wss://generativelanguage.googleapis.com/ws/google.ai.generativelanguage.v1beta.GenerativeService.BidiGenerateContentConstrained"
}

enum LiveModality: String, Equatable {
    case text
    case audioTranscript
}

enum LiveInbound: Equatable {
    case setupComplete
    case modelText(String)
    case outputTranscript(String)
    case inputTranscript(String)
    case interrupted
    case activityStart
    case activityEnd
    case turnComplete
    case toolCall(id: String, name: String, arguments: String)
    case goAway
    case error(String)
}

enum LiveEffect: Equatable {
    case speak(String)
    case interrupt
    case speechStart
    case speechEnd
    case user(String)
    case userFinal(String)
    case tool(id: String, name: String, arguments: String)
    case failed(String)
    case ready
}

enum LiveWire {
    /// 400 ms of silence ends the turn. The server default is about 800 ms, which spends the 1 second budget before George starts.
    static let silenceDurationMs = 400

    static func setup(instruction: String, declarations: [JSONValue], modality: LiveModality) -> String {
        var setup: [String: Any] = [
            "model": "models/\(LiveModel.current)",
            "responseModalities": [modality == .text ? "TEXT" : "AUDIO"],
            "systemInstruction": ["parts": [["text": String(instruction.prefix(12_000))]]],
            "inputAudioTranscription": [:] as [String: Any],
            "realtimeInputConfig": [
                "activityHandling": "START_OF_ACTIVITY_INTERRUPTS",
                "automaticActivityDetection": [
                    "disabled": false,
                    "silenceDurationMs": silenceDurationMs,
                    "prefixPaddingMs": 200,
                    "endOfSpeechSensitivity": "END_SENSITIVITY_HIGH",
                ],
            ] as [String: Any],
        ]
        if modality == .audioTranscript {
            setup["outputAudioTranscription"] = [:] as [String: Any]
        }
        if !declarations.isEmpty {
            setup["tools"] = [[
                "functionDeclarations": declarations.map { declaration($0) },
            ]]
        }
        return stringify(["setup": setup])
    }

    static func audio(_ pcm: Data) -> String {
        stringify([
            "realtimeInput": [
                "audio": [
                    "mimeType": "audio/pcm;rate=16000",
                    "data": pcm.base64EncodedString(),
                ],
            ],
        ])
    }

    static func toolResult(id: String, name: String, result: String) -> String {
        stringify([
            "toolResponse": [
                "functionResponses": [[
                    "id": id,
                    "name": name,
                    "response": ["result": String(result.prefix(4_000))],
                ]],
            ],
        ])
    }

    static func rejectsText(_ message: String) -> Bool {
        let lower = message.lowercased()
        let mentionsModality = lower.contains("modality") || lower.contains("response_modalit") || lower.contains("responsemodalit")
        let mentionsAudio = lower.contains("audio")
        let mentionsText = lower.contains("text")
        if mentionsModality && (mentionsAudio || mentionsText) { return true }
        if lower.contains("only support") && mentionsAudio { return true }
        return false
    }

    /// OpenAI-style tool definitions become Gemini function declarations. Calls block until the phone returns.
    static func declarations(from tools: [JSONValue]) -> [JSONValue] {
        tools.compactMap { tool in
            guard let function = tool["function"], let name = function["name"]?.string, !name.isEmpty else { return nil }
            var fields: [String: JSONValue] = [
                "name": .string(name),
                "description": function["description"] ?? .string(""),
                "behavior": .string("BLOCKING"),
            ]
            if let parameters = function["parameters"] {
                fields["parameters"] = parameters
            }
            return .object(fields)
        }
    }

    private static func declaration(_ value: JSONValue) -> Any {
        jsonObject(value)
    }

    private static func jsonObject(_ value: JSONValue) -> Any {
        switch value {
        case .string(let text): return text
        case .number(let number): return number
        case .bool(let flag): return flag
        case .object(let fields): return fields.mapValues { jsonObject($0) }
        case .array(let items): return items.map { jsonObject($0) }
        case .null: return NSNull()
        }
    }

    private static func stringify(_ body: [String: Any]) -> String {
        guard JSONSerialization.isValidJSONObject(body),
              let data = try? JSONSerialization.data(withJSONObject: body),
              let text = String(data: data, encoding: .utf8) else { return "{}" }
        return text
    }
}

enum LivePCM {
    /// Raw little-endian 16-bit mono at 16 kHz. No energy gate and no substituted silence.
    static func int16(_ samples: [Float], sourceRate: Double, targetRate: Double = 16_000) -> Data {
        guard sourceRate > 0, targetRate > 0, !samples.isEmpty else { return Data() }
        let step = sourceRate / targetRate
        var data = Data()
        let count = Int((Double(samples.count) / step).rounded(.down))
        data.reserveCapacity(max(count, 1) * 2)
        var cursor = 0.0
        while Int(cursor) < samples.count {
            let sample = samples[Int(cursor)]
            let clamped = min(1, max(-1, sample))
            var value = Int16(clamped * 32_767).littleEndian
            withUnsafeBytes(of: &value) { data.append(contentsOf: $0) }
            cursor += step
        }
        return data
    }
}

/// Speaks the first clause quickly, then the rest sentence by sentence. Model text wins over a duplicate transcript.
struct LiveSpeakBuffer {
    private(set) var pending = ""
    private var committed = ""
    private var sawModelText = false

    mutating func reset() {
        pending = ""
        committed = ""
        sawModelText = false
    }

    mutating func ingest(_ update: String, source: LiveTextSource) -> [String] {
        if source == .outputTranscript, sawModelText { return [] }
        if source == .modelText { sawModelText = true }
        let piece = delta(update)
        guard !piece.isEmpty else { return [] }
        pending += piece
        return pull(flush: false)
    }

    mutating func flush() -> [String] {
        pull(flush: true)
    }

    private mutating func delta(_ update: String) -> String {
        let soFar = committed + pending
        if update.hasPrefix(soFar) { return String(update.dropFirst(soFar.count)) }
        if !pending.isEmpty, update.hasPrefix(pending), committed.isEmpty {
            return String(update.dropFirst(pending.count))
        }
        return update
    }

    private mutating func pull(flush: Bool) -> [String] {
        var spoken: [String] = []
        while true {
            if committed.isEmpty, let early = firstClause(pending) {
                take(early, into: &spoken)
                continue
            }
            if let sentence = completeSentence(pending) {
                take(sentence, into: &spoken)
                continue
            }
            if flush {
                let rest = pending.trimmingCharacters(in: .whitespacesAndNewlines)
                pending = ""
                if rest.count >= 2 { spoken.append(rest); committed += rest }
            }
            break
        }
        return spoken
    }

    private mutating func take(_ raw: String, into spoken: inout [String]) {
        let count = raw.count
        pending = String(pending.dropFirst(min(count, pending.count)))
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.count >= 2 else { return }
        spoken.append(text)
        committed += text
    }

    /// The opening clause. A comma, or about eight words, so ElevenLabs can start before the full sentence.
    private func firstClause(_ text: String) -> String? {
        if let comma = text.firstIndex(where: { $0 == "," || $0 == ";" || $0 == ":" }) {
            let head = text[...comma]
            if head.count >= 12, head.count < text.count { return String(head) }
        }
        var words = 0
        var index = text.startIndex
        var wordStart = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            if character == " " || character == "\n" {
                if wordStart < index { words += 1 }
                if words >= 8, index < text.endIndex { return String(text[..<index]) }
                wordStart = text.index(after: index)
            }
            index = text.index(after: index)
        }
        return completeSentence(text)
    }

    private func completeSentence(_ text: String) -> String? {
        guard let end = text.firstIndex(where: { $0 == "." || $0 == "!" || $0 == "?" }) else { return nil }
        let sentence = text[...end]
        guard sentence.count >= 2 else { return nil }
        return String(sentence)
    }
}

enum LiveTextSource {
    case modelText
    case outputTranscript
}

struct LiveTurnReducer {
    private var buffer = LiveSpeakBuffer()
    private var user = ""
    private var userClosed = ""

    mutating func resetTurn() {
        buffer.reset()
    }

    mutating func apply(_ event: LiveInbound) -> [LiveEffect] {
        switch event {
        case .setupComplete:
            return [.ready]
        case .modelText(let text):
            return buffer.ingest(text, source: .modelText).map(LiveEffect.speak)
        case .outputTranscript(let text):
            return buffer.ingest(text, source: .outputTranscript).map(LiveEffect.speak)
        case .inputTranscript(let text):
            user = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return user.isEmpty ? [] : [.user(user)]
        case .interrupted:
            buffer.reset()
            return [.interrupt]
        case .activityStart:
            buffer.reset()
            return [.speechStart, .interrupt]
        case .activityEnd:
            return [.speechEnd]
        case .turnComplete:
            var effects = buffer.flush().map(LiveEffect.speak)
            if !user.isEmpty, user != userClosed {
                userClosed = user
                effects.append(.userFinal(user))
            }
            buffer.reset()
            return effects
        case .toolCall(let id, let name, let arguments):
            return [.tool(id: id, name: name, arguments: arguments)]
        case .goAway:
            return [.failed("goaway")]
        case .error(let message):
            return [.failed(message)]
        }
    }
}

enum LiveMessages {
    static func parse(_ data: Data) -> [LiveInbound] {
        guard let value = try? JSONDecoder().decode(JSONValue.self, from: data) else { return [] }
        return parse(value)
    }

    static func parse(_ value: JSONValue) -> [LiveInbound] {
        var events: [LiveInbound] = []
        if value["setupComplete"] != nil { events.append(.setupComplete) }
        if let activity = value["voiceActivity"]?["type"]?.string {
            if activity == "ACTIVITY_START" { events.append(.activityStart) }
            if activity == "ACTIVITY_END" { events.append(.activityEnd) }
        }
        if value["goAway"] != nil { events.append(.goAway) }
        if let message = errorText(value["error"]) { events.append(.error(message)) }
        if let content = value["serverContent"] {
            if content["interrupted"]?.bool == true { events.append(.interrupted) }
            if let text = content["outputTranscription"]?["text"]?.string, !text.isEmpty {
                events.append(.outputTranscript(text))
            }
            if let text = content["inputTranscription"]?["text"]?.string, !text.isEmpty {
                events.append(.inputTranscript(text))
            }
            if let parts = content["modelTurn"]?["parts"]?.array {
                for part in parts {
                    if let text = part["text"]?.string, !text.isEmpty {
                        events.append(.modelText(text))
                    }
                }
            }
            if content["turnComplete"]?.bool == true { events.append(.turnComplete) }
        }
        if let calls = value["toolCall"]?["functionCalls"]?.array {
            for call in calls {
                let name = call["name"]?.string ?? ""
                guard !name.isEmpty else { continue }
                let id = call["id"]?.string ?? name
                events.append(.toolCall(id: id, name: name, arguments: arguments(call["args"])))
            }
        }
        return events
    }

    private static func errorText(_ value: JSONValue?) -> String? {
        guard let value else { return nil }
        if let text = value.string, !text.isEmpty { return text }
        if let message = value["message"]?.string, !message.isEmpty { return message }
        if let status = value["status"]?.string, !status.isEmpty { return status }
        return nil
    }

    private static func arguments(_ value: JSONValue?) -> String {
        guard let value else { return "{}" }
        if let text = value.string { return text }
        guard let data = try? JSONEncoder().encode(value),
              let text = String(data: data, encoding: .utf8) else { return "{}" }
        return text
    }
}
