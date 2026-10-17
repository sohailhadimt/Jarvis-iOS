import Foundation

/// Holds the private reasoning while the spoken answer streams.
final class ReasoningBox: @unchecked Sendable {
    private let lock = NSLock()
    private var text = ""

    func add(_ chunk: String) {
        let trimmed = chunk.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return }
        lock.lock()
        if text.isEmpty {
            text = trimmed
        } else if text.count < 1_200 {
            text += "\n" + trimmed
            if text.count > 1_200 {
                text = String(text.prefix(1_200))
            }
        }
        lock.unlock()
    }

    func copy() -> String {
        lock.lock()
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        lock.unlock()
        return value
    }
}

/// Gemini native stream with a thinking budget. Thought parts are not spoken.
enum GeminiThinking {
    static func stream(system: String, history: [ChatMessage], user: ChatMessage,
                       model: String, apiKey: String, box: ReasoningBox) -> AsyncThrowingStream<GroundedDelta, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let raw = "https://generativelanguage.googleapis.com/v1beta/models/\(model):streamGenerateContent?alt=sse"
                    guard let url = URL(string: raw) else { throw LLMError.badURL }
                    var request = URLRequest(url: url)
                    request.httpMethod = "POST"
                    request.timeoutInterval = 60
                    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
                    request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
                    request.httpBody = try body(system: system, history: history, user: user)
                    let bytes: URLSession.AsyncBytes
                    let response: URLResponse
                    do {
                        (bytes, response) = try await HTTPConnections.session.bytes(for: request)
                    } catch {
                        throw LLMError.http(-1, error.localizedDescription, provider: "Gemini")
                    }
                    let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                    guard (200..<300).contains(status) else {
                        var errorBody = Data()
                        for try await byte in bytes {
                            errorBody.append(byte)
                            if errorBody.count > 2_000 { break }
                        }
                        let note = String(data: errorBody, encoding: .utf8) ?? ""
                        throw LLMError.http(status, note, provider: "Gemini")
                    }
                    var line = Data()
                    for try await byte in bytes {
                        try Task.checkCancellation()
                        if byte == 10 {
                            if let delta = piece(from: line, box: box) { continuation.yield(delta) }
                            line.removeAll(keepingCapacity: true)
                        } else if byte != 13 {
                            line.append(byte)
                        }
                    }
                    if let delta = piece(from: line, box: box) { continuation.yield(delta) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private struct Payload: Encodable {
        struct Part: Encodable { let text: String }
        struct Content: Encodable { let role: String; let parts: [Part] }
        struct System: Encodable { let parts: [Part] }
        struct Thinking: Encodable {
            let thinkingBudget: Int
            let includeThoughts: Bool
        }
        struct Config: Encodable {
            let temperature: Double
            let thinkingConfig: Thinking
        }

        let systemInstruction: System
        let contents: [Content]
        let generationConfig: Config
    }

    private static func body(system: String, history: [ChatMessage], user: ChatMessage) throws -> Data {
        var contents: [Payload.Content] = []
        for message in Array((history + [user]).suffix(6)) {
            let role = message.role == "assistant" ? "model" : "user"
            let part = Payload.Part(text: message.content)
            if let index = contents.indices.last, contents[index].role == role {
                let prior = contents[index].parts.first?.text ?? ""
                let joined = prior.isEmpty ? message.content : prior + "\n" + message.content
                contents[index] = Payload.Content(role: role, parts: [Payload.Part(text: joined)])
            } else {
                contents.append(Payload.Content(role: role, parts: [part]))
            }
        }
        if contents.first?.role == "model" {
            contents.removeFirst()
        }
        guard !contents.isEmpty else { throw LLMError.emptyReply(provider: "Gemini") }
        let budget: Int = 1024
        let temperature: Double = 0.6
        let payload = Payload(
            systemInstruction: Payload.System(parts: [Payload.Part(text: system)]),
            contents: contents,
            generationConfig: Payload.Config(
                temperature: temperature,
                thinkingConfig: Payload.Thinking(thinkingBudget: budget, includeThoughts: true)
            )
        )
        return try JSONEncoder().encode(payload)
    }

    private static func piece(from line: Data, box: ReasoningBox) -> GroundedDelta? {
        guard let raw = String(data: line, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else { return nil }
        let payload: String
        if raw.hasPrefix("data:") {
            payload = String(raw.dropFirst(5)).trimmingCharacters(in: .whitespaces)
        } else {
            payload = raw
        }
        if payload == "[DONE]" || !payload.hasPrefix("{") { return nil }
        guard let data = payload.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let candidates = root["candidates"] as? [Any],
              let first = candidates.first as? [String: Any],
              let content = first["content"] as? [String: Any],
              let parts = content["parts"] as? [Any] else { return nil }
        var spoken = ""
        for part in parts {
            guard let dict = part as? [String: Any], let chunk = dict["text"] as? String else { continue }
            let thought = (dict["thought"] as? Bool) ?? false
            if thought {
                box.add(chunk)
            } else {
                spoken += chunk
            }
        }
        if spoken.isEmpty { return nil }
        return GroundedDelta(text: spoken, citations: [])
    }
}

struct ThoughtAnswer: Sendable {
    var answer: String
    var reasoning: String
}

/// Groq DeepSeek-R1 distill. The 70B distill was shut down; this is the documented distill.
enum GroqThinking {
    static let model = "deepseek-r1-distill-qwen-32b"

    private struct GroqBody: Encodable {
        struct Message: Encodable { let role: String; let content: String }
        let model: String
        let temperature: Double
        let stream: Bool
        let messages: [Message]
    }

    static func collect(system: String, history: [ChatMessage], user: ChatMessage, apiKey: String) async throws -> ThoughtAnswer {
        guard let url = URL(string: "https://api.groq.com/openai/v1/chat/completions") else { throw LLMError.badURL }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 60
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        let temperature: Double = 0.6
        let messages = [ChatMessage(role: "system", content: system)] + Array((history + [user]).suffix(6))
        let payload = GroqBody(
            model: model,
            temperature: temperature,
            stream: true,
            messages: messages.map { GroqBody.Message(role: $0.role, content: $0.content) }
        )
        request.httpBody = try JSONEncoder().encode(payload)
        let bytes: URLSession.AsyncBytes
        let response: URLResponse
        do {
            (bytes, response) = try await HTTPConnections.session.bytes(for: request)
        } catch {
            throw LLMError.http(-1, error.localizedDescription, provider: "Groq")
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            var errorBody = Data()
            for try await byte in bytes {
                errorBody.append(byte)
                if errorBody.count > 2_000 { break }
            }
            let note = String(data: errorBody, encoding: .utf8) ?? ""
            throw LLMError.http(status, note, provider: "Groq")
        }
        var answer = ""
        var reasoning = ""
        var line = Data()
        for try await byte in bytes {
            try Task.checkCancellation()
            if byte == 10 {
                let piece = chunk(from: line)
                answer += piece.answer
                reasoning += piece.reasoning
                line.removeAll(keepingCapacity: true)
            } else if byte != 13 {
                line.append(byte)
            }
        }
        let tail = chunk(from: line)
        answer += tail.answer
        reasoning += tail.reasoning
        let split = splitThink(answer)
        let spoken = split.answer.trimmingCharacters(in: .whitespacesAndNewlines)
        var privateNotes = reasoning.trimmingCharacters(in: .whitespacesAndNewlines)
        if privateNotes.isEmpty { privateNotes = split.reasoning }
        if privateNotes.count > 1_200 { privateNotes = String(privateNotes.prefix(1_200)) }
        if spoken.isEmpty { throw LLMError.emptyReply(provider: "Groq") }
        return ThoughtAnswer(answer: spoken, reasoning: privateNotes)
    }

    private static func chunk(from line: Data) -> (answer: String, reasoning: String) {
        guard let raw = String(data: line, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else { return ("", "") }
        let payload: String
        if raw.hasPrefix("data:") {
            payload = String(raw.dropFirst(5)).trimmingCharacters(in: .whitespaces)
        } else {
            payload = raw
        }
        if payload == "[DONE]" || !payload.hasPrefix("{") { return ("", "") }
        guard let data = payload.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = root["choices"] as? [Any],
              let first = choices.first as? [String: Any] else { return ("", "") }
        let delta = (first["delta"] as? [String: Any]) ?? (first["message"] as? [String: Any]) ?? [:]
        let answer = (delta["content"] as? String) ?? ""
        let reasoning = (delta["reasoning"] as? String)
            ?? (delta["reasoning_content"] as? String)
            ?? ""
        return (answer, reasoning)
    }

    private static func splitThink(_ raw: String) -> (answer: String, reasoning: String) {
        guard let open = raw.range(of: "<think>") else {
            return (raw, "")
        }
        let after = raw[open.upperBound...]
        guard let close = after.range(of: "</think>") else {
            return ("", String(after))
        }
        let reasoning = String(after[..<close.lowerBound])
        let answer = String(after[close.upperBound...])
        return (answer, reasoning)
    }
}
