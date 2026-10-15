import Foundation

struct ChatMessage: Codable, Sendable, Hashable {
    let role: String
    let content: String
}

struct LLMEndpoint: Sendable {
    let url: URL
    let apiKey: String?
    let model: String
}

enum LLMError: LocalizedError {
    case missingKey(String)
    case badURL
    case http(Int, String)
    case emptyReply

    var errorDescription: String? {
        switch self {
        case .missingKey(let p): "No \(p) API key. Add one in Settings > API Keys."
        case .badURL: "The custom agent endpoint URL is invalid."
        case .http(let code, let body): "Server error \(code): \(body.prefix(200))"
        case .emptyReply: "The model returned an empty reply."
        }
    }
}

/// OpenAI-compatible Chat Completions client (works for OpenAI and any compatible "custom agent endpoint").
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

        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw LLMError.http(status, String(data: data, encoding: .utf8) ?? "")
        }
        let decoded = try JSONDecoder().decode(Response.self, from: data)
        guard let text = decoded.choices.first?.message.content?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty else { throw LLMError.emptyReply }
        return text
    }
}
