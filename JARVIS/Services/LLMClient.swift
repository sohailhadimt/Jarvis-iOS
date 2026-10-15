import Foundation

struct ChatMessage: Codable, Sendable, Hashable {
    let role: String
    let content: String
}

struct LLMEndpoint: Sendable {
    let url: URL
    let apiKey: String?
    let model: String
    /// Shown in errors, for example "Gemini" or "Groq".
    let providerName: String
    let kind: LLMProvider
}

enum LLMError: LocalizedError, Sendable {
    case missingKey(String)
    case badURL
    case http(Int, String, provider: String)
    case emptyReply(provider: String)

    var errorDescription: String? {
        switch self {
        case .missingKey(let name):
            switch name {
            case "Gemini":
                "No Gemini API key. Create one at aistudio.google.com/apikey and save it in Settings > API Keys & Provider."
            case "Groq":
                "No Groq API key. Create one at console.groq.com/keys and save it in Settings > API Keys & Provider."
            case "OpenAI":
                "No OpenAI API key. Add one in Settings > API Keys & Provider, or save a free Gemini or Groq key and JARVIS will use that."
            case "OpenAI web search":
                "Web search needs an OpenAI API key. Add one in Settings > API Keys & Provider. Gemini and Groq answer from their own models without live web search."
            default:
                "No \(name) API key. Add one in Settings > API Keys & Provider."
            }
        case .badURL:
            "The custom agent endpoint URL is invalid."
        case .http(let code, let body, provider: let provider):
            if code < 0 {
                "\(provider) reply could not be read: \(Self.clip(body))"
            } else {
                "\(provider) error \(code): \(Self.clip(body))\(Self.hint(code: code, provider: provider))"
            }
        case .emptyReply(provider: let provider):
            "\(provider) returned an empty reply. Check the model name in Settings > API Keys & Provider."
        }
    }

    /// A 400/422 whose body says the tools payload was rejected. Callers retry once with no tools.
    var isToolFormat: Bool {
        guard case .http(let code, let body, provider: _) = self else { return false }
        guard code == 400 || code == 422 else { return false }
        let haystack = body.lowercased()
        let needles = ["tool", "function_call", "function calling", "tool_choice", "tool_use", "\"functions\""]
        return needles.contains { haystack.contains($0) }
    }

    static func clip(_ body: String) -> String {
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "no details" }
        if let data = trimmed.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let error = json["error"] as? [String: Any],
               let message = error["message"] as? String, !message.isEmpty {
                return String(message.prefix(240))
            }
            if let message = json["message"] as? String, !message.isEmpty {
                return String(message.prefix(240))
            }
            if let error = json["error"] as? String, !error.isEmpty {
                return String(error.prefix(240))
            }
        }
        return String(trimmed.prefix(200))
    }

    private static func hint(code: Int, provider: String) -> String {
        switch code {
        case 401, 403:
            " Check the \(provider) API key in Settings > API Keys & Provider."
        case 404:
            " Check the \(provider) model name in Settings > API Keys & Provider."
        case 429:
            " \(provider) is rate-limiting this key. Wait, or switch AI Provider in Settings."
        default:
            ""
        }
    }
}

/// OpenAI-compatible Chat Completions client.
/// OpenAI, Gemini, Groq and the custom agent endpoint all use this shape, including the system message.
enum LLMClient {
    private struct Request: Encodable {
        let model: String
        let messages: [ChatMessage]
        let temperature: Double
    }

    private struct Response: Decodable {
        struct Choice: Decodable {
            struct Message: Decodable { let content: String? }
            let message: Message
        }
        let choices: [Choice]
    }

    static func complete(messages: [ChatMessage], endpoint: LLMEndpoint) async throws -> String {
        var request = URLRequest(url: endpoint.url)
        request.httpMethod = "POST"
        request.timeoutInterval = 60
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let key = endpoint.apiKey, !key.isEmpty {
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = try JSONEncoder().encode(Request(model: endpoint.model, messages: messages, temperature: 0.7))

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw LLMError.http(-1, error.localizedDescription, provider: endpoint.providerName)
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw LLMError.http(status, String(data: data, encoding: .utf8) ?? "", provider: endpoint.providerName)
        }
        do {
            let decoded = try JSONDecoder().decode(Response.self, from: data)
            guard let text = decoded.choices.first?.message.content?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !text.isEmpty else { throw LLMError.emptyReply(provider: endpoint.providerName) }
            return text
        } catch let error as LLMError {
            throw error
        } catch {
            throw LLMError.http(-1, error.localizedDescription, provider: endpoint.providerName)
        }
    }

    /// Chat Completions SSE. Yields content deltas. Callers fall back to `complete` when this throws
    /// before any text arrives.
    static func streamDeltas(messages: [ChatMessage], endpoint: LLMEndpoint) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var request = URLRequest(url: endpoint.url)
                    request.httpMethod = "POST"
                    request.timeoutInterval = 60
                    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
                    if let key = endpoint.apiKey, !key.isEmpty {
                        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
                    }
                    request.httpBody = try JSONEncoder().encode(StreamRequest(
                        model: endpoint.model, messages: messages, temperature: 0.7, stream: true))
                    let bytes: URLSession.AsyncBytes
                    let response: URLResponse
                    do {
                        (bytes, response) = try await URLSession.shared.bytes(for: request)
                    } catch {
                        throw LLMError.http(-1, error.localizedDescription, provider: endpoint.providerName)
                    }
                    let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                    guard (200..<300).contains(status) else {
                        var body = Data()
                        for try await byte in bytes {
                            body.append(byte)
                            if body.count > 2_000 { break }
                        }
                        throw LLMError.http(status, String(data: body, encoding: .utf8) ?? "", provider: endpoint.providerName)
                    }
                    var line = Data()
                    for try await byte in bytes {
                        try Task.checkCancellation()
                        if byte == 10 {
                            if let delta = Self.delta(from: line) { continuation.yield(delta) }
                            line.removeAll(keepingCapacity: true)
                        } else if byte != 13 {
                            line.append(byte)
                        }
                    }
                    if let delta = Self.delta(from: line) { continuation.yield(delta) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private struct StreamRequest: Encodable {
        let model: String
        let messages: [ChatMessage]
        let temperature: Double
        let stream: Bool
    }

    private struct StreamChunk: Decodable {
        struct Choice: Decodable {
            struct Delta: Decodable { let content: String? }
            let delta: Delta?
            let message: Delta?
        }
        let choices: [Choice]?
    }

    private static func delta(from line: Data) -> String? {
        guard let text = String(data: line, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty else { return nil }
        let payload: String
        if text.hasPrefix("data:") {
            payload = String(text.dropFirst(5)).trimmingCharacters(in: .whitespaces)
        } else {
            payload = text
        }
        if payload == "[DONE]" || payload.isEmpty { return nil }
        guard payload.hasPrefix("{"),
              let data = payload.data(using: .utf8),
              let chunk = try? JSONDecoder().decode(StreamChunk.self, from: data),
              let choice = chunk.choices?.first else { return nil }
        let content = choice.delta?.content ?? choice.message?.content
        guard let content, !content.isEmpty else { return nil }
        return content
    }
}
