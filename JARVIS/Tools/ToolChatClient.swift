import Foundation

struct ToolCall: Sendable, Hashable {
    let id: String
    let name: String
    let arguments: String
}

struct Citation: Sendable, Hashable, Identifiable {
    let title: String
    let url: String
    var id: String { url }
}

/// OpenAI Chat Completions with function calling (also works with OpenAI-compatible custom endpoints that support tools).
enum ToolChatClient {
    struct Reply: Sendable {
        let content: String?
        let toolCalls: [ToolCall]

        /// The assistant message to echo back before the tool results.
        var assistantMessage: JSONValue {
            var msg: [String: JSONValue] = ["role": "assistant", "content": content.map(JSONValue.string) ?? .null]
            if !toolCalls.isEmpty {
                msg["tool_calls"] = .array(toolCalls.map { (tc: ToolCall) -> JSONValue in
                    ["id": .string(tc.id), "type": "function",
                     "function": ["name": .string(tc.name), "arguments": .string(tc.arguments)]]
                })
            }
            return .object(msg)
        }
    }

    static func send(messages: [JSONValue], tools: [JSONValue], endpoint: LLMEndpoint,
                     temperature: Double = 0.5) async throws -> Reply {
        var body: [String: JSONValue] = [
            "model": .string(endpoint.model),
            "messages": .array(messages),
            "temperature": .number(temperature),
        ]
        if !tools.isEmpty {
            body["tools"] = .array(tools)
            body["tool_choice"] = "auto"
        }
        let json = try await post(url: endpoint.url, key: endpoint.apiKey, body: .object(body))
        guard let message = json["choices"]?.array?.first?["message"] else { throw LLMError.emptyReply }
        let calls: [ToolCall] = (message["tool_calls"]?.array ?? []).compactMap { call in
            guard let id = call["id"]?.string, let name = call["function"]?["name"]?.string else { return nil }
            return ToolCall(id: id, name: name, arguments: call["function"]?["arguments"]?.string ?? "{}")
        }
        let content = message["content"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines)
        return Reply(content: content, toolCalls: calls)
    }

    static func post(url: URL, key: String?, body: JSONValue) async throws -> JSONValue {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 90
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let key, !key.isEmpty { request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
        request.httpBody = try JSONEncoder().encode(body)
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw LLMError.http(status, String(data: data, encoding: .utf8) ?? "")
        }
        return try JSONDecoder().decode(JSONValue.self, from: data)
    }
}

/// OpenAI Responses API with the hosted `web_search` tool. Used for the knowledge / search path.
enum ResponsesClient {
    struct Answer: Sendable {
        let text: String
        let citations: [Citation]
    }

    static func answer(input: [ChatMessage], instructions: String, model: String, apiKey: String) async throws -> Answer {
        let body: JSONValue = [
            "model": .string(model),
            "instructions": .string(instructions),
            "input": .array(input.map { ["role": .string($0.role), "content": .string($0.content)] }),
            "tools": [["type": "web_search"]],
        ]
        let json = try await ToolChatClient.post(url: URL(string: "https://api.openai.com/v1/responses")!,
                                                 key: apiKey, body: body)
        var text = ""
        var citations: [Citation] = []
        for item in json["output"]?.array ?? [] where item["type"]?.string == "message" {
            for part in item["content"]?.array ?? [] where part["type"]?.string == "output_text" {
                text += part["text"]?.string ?? ""
                for a in part["annotations"]?.array ?? [] where a["type"]?.string == "url_citation" {
                    if let url = a["url"]?.string, !citations.contains(where: { $0.url == url }) {
                        citations.append(Citation(title: a["title"]?.string ?? url, url: url))
                    }
                }
            }
        }
        guard !text.isEmpty else { throw LLMError.emptyReply }
        return Answer(text: text, citations: citations)
    }

    /// Removes inline markdown links / bare URLs so the spoken reply sounds natural.
    static func spokenText(_ text: String) -> String {
        text.replacingOccurrences(of: #"\s*\(\[[^\]]*\]\([^)]*\)\)"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\[([^\]]+)\]\([^)]+\)"#, with: "$1", options: .regularExpression)
            .replacingOccurrences(of: #"https?://\S+"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: "**", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

enum WebhookClient {
    /// POST {"task": ...} with a bearer key. Returns the HTTP status.
    static func sendTask(_ task: String, url: URL, key: String?) async throws -> Int {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let key, !key.isEmpty { request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
        let body: JSONValue = [
            "task": .string(task),
            "source": "JARVIS iOS",
            "sent_at": .string(Date.now.ISO8601Format()),
        ]
        request.httpBody = try JSONEncoder().encode(body)
        let (_, response) = try await URLSession.shared.data(for: request)
        return (response as? HTTPURLResponse)?.statusCode ?? 0
    }
}
