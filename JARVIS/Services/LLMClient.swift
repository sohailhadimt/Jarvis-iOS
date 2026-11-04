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
                "Web search needs an OpenAI API key, or a free Gemini key. Gemini Google Search covers current questions. Add a key in Settings > API Keys & Provider."
            default:
                "No \(name) API key. Add one in Settings > API Keys & Provider."
            }
        case .badURL:
            "The custom agent endpoint URL is invalid."
        case .http(let code, _, provider: _):
            if Self.busyCodes.contains(code) {
                "JARVIS is busy. Try again in a moment."
            } else if code == 401 || code == 403 {
                "The API key was rejected. Check Settings > API Keys & Provider."
            } else if code == 404 {
                "That model is unavailable. Check Settings > API Keys & Provider."
            } else if code < 0 {
                "JARVIS could not reach the model."
            } else {
                "JARVIS could not answer just now."
            }
        case .emptyReply(provider: _):
            "JARVIS got an empty reply."
        }
    }

    /// 429 and 5xx mean the model is overloaded or briefly down. Callers retry, then switch models.
    var isBusy: Bool {
        guard case .http(let code, _, _) = self else { return false }
        return Self.busyCodes.contains(code)
    }

    private static let busyCodes: Set<Int> = [429, 500, 502, 503, 504]

    static func short(_ error: Error) -> String {
        JarvisLines.explain(error)
    }

    /// A 400/422 whose body says the tools payload was rejected. Callers retry once with no tools.
    var isToolFormat: Bool {
        guard case .http(let code, let body, provider: _) = self else { return false }
        guard code == 400 || code == 422 else { return false }
        let haystack = body.lowercased()
        let needles = ["tool", "function_call", "function calling", "tool_choice", "tool_use", "\"functions\""]
        return needles.contains { haystack.contains($0) }
    }
}

/// Retries an overloaded model, then a free Gemini model, then Groq when that key exists.
@MainActor
enum ModelFallback {
    static let busyLine = "JARVIS is busy, retrying…"
    /// gemini-2.0-flash and gemini-2.0-flash-lite shut down on 1 June 2026.
    static let alternateGeminiModels = [
        "gemini-3.5-flash-lite",
        "gemini-3.1-flash-lite",
        "gemini-2.5-flash-lite",
    ]

    static func run<T>(
        primary: LLMEndpoint,
        groq: LLMEndpoint?,
        status: @escaping (String?) -> Void,
        work: @escaping (LLMEndpoint) async throws -> T
    ) async throws -> T {
        let chain = endpoints(primary: primary, groq: groq)
        var last: Error = LLMError.http(503, "", provider: primary.providerName)
        var overloaded = false
        var index = 0
        while index < chain.count {
            let endpoint = chain[index]
            let tries: Int = index == 0 ? 4 : 1
            var attempt = 0
            var advance = true
            while attempt < tries {
                do {
                    let value = try await work(endpoint)
                    status(nil)
                    return value
                } catch {
                    if Task.isCancelled { throw error }
                    last = error
                    guard let llm = error as? LLMError else { throw error }
                    if llm.isBusy {
                        overloaded = true
                        let moreHere: Bool = attempt + 1 < tries
                        if moreHere {
                            status(busyLine)
                            let shift: Int = attempt
                            let delay: Int = 400 * (1 << shift)
                            try await Task.sleep(for: .milliseconds(delay))
                            attempt += 1
                            continue
                        }
                        break
                    }
                    if case .http(let code, _, _) = llm, code == 404 {
                        break
                    }
                    if case .http(let code, _, _) = llm, (code == 401 || code == 403), endpoint.kind == .gemini {
                        if let groqIndex = chain.firstIndex(where: { $0.kind == .groq }), groqIndex > index {
                            index = groqIndex
                            advance = false
                            break
                        }
                    }
                    throw error
                }
            }
            if advance { index += 1 }
            if overloaded, index < chain.count {
                status(busyLine)
            }
        }
        status(nil)
        throw last
    }

    private static func endpoints(primary: LLMEndpoint, groq: LLMEndpoint?) -> [LLMEndpoint] {
        var chain: [LLMEndpoint] = [primary]
        if primary.kind == .gemini {
            for model in alternateGeminiModels where model != primary.model {
                let next = LLMEndpoint(url: primary.url, apiKey: primary.apiKey, model: model,
                                       providerName: primary.providerName, kind: .gemini)
                chain.append(next)
            }
        }
        if let groq, primary.kind != .groq {
            chain.append(groq)
        }
        return chain
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

    static func complete(messages: [ChatMessage], endpoint: LLMEndpoint, temperature: Double = 0.7) async throws -> String {
        var request = URLRequest(url: endpoint.url)
        request.httpMethod = "POST"
        request.timeoutInterval = 60
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let key = endpoint.apiKey, !key.isEmpty {
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = try JSONEncoder().encode(Request(model: endpoint.model, messages: messages, temperature: temperature))

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await HTTPConnections.session.data(for: request)
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

    /// SSE for Gemini and Groq. Gemini uses the OpenAI-compatible `stream: true` chat
    /// endpoint (the same events as `streamGenerateContent?alt=sse`). Groq uses the same
    /// shape. Yields content deltas. Callers fall back to `complete` when this throws
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
                        (bytes, response) = try await HTTPConnections.session.bytes(for: request)
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
