import Foundation

/// One camera frame on Gemini's native stream. About one JPEG a second, not the Live websocket.
enum GeminiVision {
    static func stream(system: String, history: [ChatMessage], user: ChatMessage,
                       jpeg: Data, model: String, apiKey: String) -> AsyncThrowingStream<GroundedDelta, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let url = try endpoint(model: model)
                    var request = URLRequest(url: url)
                    request.httpMethod = "POST"
                    request.timeoutInterval = 30
                    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
                    request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
                    request.httpBody = try body(system: system, history: history, user: user, jpeg: jpeg)
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
                            if let delta = piece(from: line) { continuation.yield(delta) }
                            line.removeAll(keepingCapacity: true)
                        } else if byte != 13 {
                            line.append(byte)
                        }
                    }
                    if let delta = piece(from: line) { continuation.yield(delta) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private static func endpoint(model: String) throws -> URL {
        let raw = "https://generativelanguage.googleapis.com/v1beta/models/\(model):streamGenerateContent?alt=sse"
        guard let url = URL(string: raw) else { throw LLMError.badURL }
        return url
    }

    private enum VisionPart: Encodable {
        case text(String)
        case image(String)

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: Key.self)
            switch self {
            case .text(let value):
                try container.encode(value, forKey: .text)
            case .image(let value):
                var inline = container.nestedContainer(keyedBy: InlineKey.self, forKey: .inlineData)
                try inline.encode("image/jpeg", forKey: .mime)
                try inline.encode(value, forKey: .data)
            }
        }

        private enum Key: String, CodingKey {
            case text
            case inlineData = "inline_data"
        }

        private enum InlineKey: String, CodingKey {
            case mime = "mime_type"
            case data
        }
    }

    private struct Content: Encodable {
        var role: String
        var parts: [VisionPart]
    }

    private struct Payload: Encodable {
        struct Part: Encodable { let text: String }
        struct System: Encodable { let parts: [Part] }
        struct Config: Encodable { let temperature: Double }

        let systemInstruction: System
        let contents: [Content]
        let generationConfig: Config
    }

    private static func body(system: String, history: [ChatMessage], user: ChatMessage, jpeg: Data) throws -> Data {
        var contents: [Content] = []
        for message in Array(history.suffix(4)) {
            let role = message.role == "assistant" ? "model" : "user"
            let part = VisionPart.text(message.content)
            if let index = contents.indices.last, contents[index].role == role {
                contents[index].parts.append(part)
            } else {
                contents.append(Content(role: role, parts: [part]))
            }
        }
        if contents.first?.role == "model" {
            contents.removeFirst()
        }
        let asked = user.content.trimmingCharacters(in: .whitespacesAndNewlines)
        let question = asked.isEmpty ? "What do you see?" : asked
        let image = VisionPart.image(jpeg.base64EncodedString())
        let text = VisionPart.text(question)
        if let index = contents.indices.last, contents[index].role == "user" {
            contents[index].parts.append(image)
            contents[index].parts.append(text)
        } else {
            contents.append(Content(role: "user", parts: [image, text]))
        }
        let temperature: Double = 0.4
        let payload = Payload(
            systemInstruction: Payload.System(parts: [Payload.Part(text: system)]),
            contents: contents,
            generationConfig: Payload.Config(temperature: temperature)
        )
        return try JSONEncoder().encode(payload)
    }

    private static func piece(from line: Data) -> GroundedDelta? {
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
            spoken += chunk
        }
        if spoken.isEmpty { return nil }
        return GroundedDelta(text: spoken, citations: [])
    }
}
