import Foundation

struct GroundedDelta: Sendable {
    var text: String
    var citations: [Citation]
}

/// Local check for questions that need the live web. No network, so ordinary chat stays fast.
enum WebKnowledge {
    static func needsLiveFacts(_ text: String) -> Bool {
        let lower = text.lowercased()
        let needles = [
            "news", "headline", "headlines",
            "weather", "forecast",
            "price of", "prices", "how much", "stock price", "share price", "exchange rate", "bitcoin",
            "sports", "football", "cricket", "tennis", "premier league", "champions league",
            "score", "fixture", "who won", "who plays",
            "search for", "look up", "lookup", "google ",
            "latest", "right now", "today's", "tonight", "this week", "this morning", "live score",
            "who is", "who's", "who was", "who are",
            "where is", "where's", "where are", "capital of",
            "when is", "when does", "when did", "what year", "which year",
            "prime minister", "president", "election",
            "opening hours", "what happened",
        ]
        return needles.contains { lower.contains($0) }
    }
}

/// Gemini `google_search` grounding on the native stream endpoint.
enum GeminiGrounding {
    static func stream(system: String, history: [ChatMessage], user: ChatMessage,
                       model: String, apiKey: String) -> AsyncThrowingStream<GroundedDelta, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let url = try endpoint(model: model)
                    var request = URLRequest(url: url)
                    request.httpMethod = "POST"
                    request.timeoutInterval = 20
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

    private struct GroundBody: Encodable {
        struct Part: Encodable { let text: String }
        struct Content: Encodable { let role: String; let parts: [Part] }
        struct System: Encodable { let parts: [Part] }
        struct Search: Encodable {}
        struct Tool: Encodable { let google_search: Search }
        struct Config: Encodable {
            let temperature: Double
        }

        let systemInstruction: System
        let contents: [Content]
        let tools: [Tool]
        let generationConfig: Config
    }

    private static func body(system: String, history: [ChatMessage], user: ChatMessage) throws -> Data {
        let recent = Array((history + [user]).suffix(6))
        var contents: [GroundBody.Content] = []
        for message in recent {
            let role = message.role == "assistant" ? "model" : "user"
            if let last = contents.last, last.role == role {
                let prior = last.parts.first?.text ?? ""
                let joined = prior.isEmpty ? message.content : prior + "\n" + message.content
                contents[contents.count - 1] = GroundBody.Content(role: role, parts: [GroundBody.Part(text: joined)])
            } else {
                contents.append(GroundBody.Content(role: role, parts: [GroundBody.Part(text: message.content)]))
            }
        }
        if contents.first?.role == "model" {
            contents.removeFirst()
        }
        guard !contents.isEmpty else { throw LLMError.emptyReply(provider: "Gemini") }
        let temperature: Double = 0.5
        let payload = GroundBody(
            systemInstruction: GroundBody.System(parts: [GroundBody.Part(text: system)]),
            contents: contents,
            tools: [GroundBody.Tool(google_search: GroundBody.Search())],
            generationConfig: GroundBody.Config(temperature: temperature)
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
              let first = candidates.first as? [String: Any] else { return nil }
        let spoken = text(in: first)
        let cites = citations(in: first)
        if spoken.isEmpty && cites.isEmpty { return nil }
        return GroundedDelta(text: spoken, citations: cites)
    }

    private static func text(in candidate: [String: Any]) -> String {
        guard let content = candidate["content"] as? [String: Any],
              let parts = content["parts"] as? [Any] else { return "" }
        var spoken = ""
        for part in parts {
            guard let dict = part as? [String: Any], let chunk = dict["text"] as? String else { continue }
            spoken += chunk
        }
        return spoken
    }

    private static func citations(in candidate: [String: Any]) -> [Citation] {
        let meta = (candidate["groundingMetadata"] as? [String: Any])
            ?? (candidate["grounding_metadata"] as? [String: Any])
        guard let meta else { return [] }
        let chunks = (meta["groundingChunks"] as? [Any]) ?? (meta["grounding_chunks"] as? [Any]) ?? []
        var cites: [Citation] = []
        for chunk in chunks {
            guard let dict = chunk as? [String: Any], let web = dict["web"] as? [String: Any] else { continue }
            let uri = ((web["uri"] as? String) ?? (web["url"] as? String) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard uri.hasPrefix("http://") || uri.hasPrefix("https://") else { continue }
            let rawTitle = (web["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let title = rawTitle.isEmpty ? "Source" : rawTitle
            if cites.contains(where: { $0.url == uri }) { continue }
            cites.append(Citation(title: title, url: uri))
            if cites.count >= 6 { break }
        }
        return cites
    }
}

struct WebNotes: Sendable {
    var context: String
    var citations: [Citation]
}

/// Free notes when Gemini grounding is down or out of quota.
enum FreeWebSearch {
    static func gather(query: String) async -> WebNotes {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return WebNotes(context: "", citations: []) }
        let clipped = trimmed.count > 180 ? String(trimmed.prefix(180)) : trimmed
        async let braveNotes = brave(clipped)
        async let duckNotes = duck(clipped)
        async let wikiNotes = wiki(clipped)
        let combined = await braveNotes + duckNotes + wikiNotes
        return pack(combined)
    }

    private static func pack(_ notes: [Note]) -> WebNotes {
        var lines: [String] = []
        var cites: [Citation] = []
        var used: Int = 0
        var seen = Set<String>()
        for note in notes {
            if !note.url.isEmpty, seen.insert(note.url).inserted, cites.count < 5 {
                cites.append(Citation(title: note.title, url: note.url))
            }
            let line = "- \(note.title): \(note.snippet)"
            let next: Int = used + line.count
            if next > 1_400 { continue }
            lines.append(line)
            used = next
            if lines.count >= 5 { break }
        }
        return WebNotes(context: lines.joined(separator: "\n"), citations: cites)
    }

    private struct Note: Sendable {
        var title: String
        var url: String
        var snippet: String
    }

    private static func brave(_ query: String) async -> [Note] {
        guard let key = KeychainStore.get(.brave), !key.isEmpty else { return [] }
        guard let url = searchURL("https://api.search.brave.com/res/v1/web/search", query: query, extra: ["count": "5"]) else {
            return []
        }
        guard let object = await json(url, headers: ["X-Subscription-Token": key, "Accept": "application/json"]) else {
            return []
        }
        guard let web = object["web"] as? [String: Any], let results = web["results"] as? [Any] else { return [] }
        var notes: [Note] = []
        for item in results {
            guard let dict = item as? [String: Any] else { continue }
            let title = string(dict["title"]) ?? "Brave"
            let link = string(dict["url"]) ?? ""
            let snippet = clip(string(dict["description"]) ?? "")
            guard !snippet.isEmpty else { continue }
            notes.append(Note(title: title, url: link, snippet: snippet))
            if notes.count >= 4 { break }
        }
        return notes
    }

    private static func duck(_ query: String) async -> [Note] {
        guard let url = searchURL("https://api.duckduckgo.com/", query: query, extra: [
            "format": "json", "no_html": "1", "skip_disambig": "1",
        ]) else { return [] }
        guard let object = await json(url, headers: [:]) else { return [] }
        var notes: [Note] = []
        let answer = string(object["Answer"]) ?? ""
        let abstract = string(object["AbstractText"]) ?? ""
        let heading = string(object["Heading"]) ?? "DuckDuckGo"
        let abstractURL = string(object["AbstractURL"]) ?? ""
        if !answer.isEmpty {
            notes.append(Note(title: heading, url: abstractURL, snippet: clip(answer)))
        }
        if !abstract.isEmpty {
            notes.append(Note(title: heading, url: abstractURL, snippet: clip(abstract)))
        }
        if let topics = object["RelatedTopics"] as? [Any] {
            for item in topics {
                guard let dict = item as? [String: Any] else { continue }
                let text = string(dict["Text"]) ?? ""
                let link = string(dict["FirstURL"]) ?? ""
                guard !text.isEmpty else { continue }
                notes.append(Note(title: heading, url: link, snippet: clip(text)))
                if notes.count >= 4 { break }
            }
        }
        return notes
    }

    private static func wiki(_ query: String) async -> [Note] {
        guard let url = searchURL("https://en.wikipedia.org/w/api.php", query: query, extra: [
            "action": "query", "list": "search", "srlimit": "3", "format": "json", "utf8": "1",
        ], queryName: "srsearch") else { return [] }
        guard let object = await json(url, headers: ["User-Agent": "JARVIS/1.0 (personal assistant; iOS)", "Accept": "application/json"]),
              let queryObject = object["query"] as? [String: Any],
              let hits = queryObject["search"] as? [Any] else { return [] }
        var notes: [Note] = []
        for item in hits {
            guard let dict = item as? [String: Any], let title = string(dict["title"]) else { continue }
            let snippet = clip(stripTags(string(dict["snippet"]) ?? ""))
            guard !snippet.isEmpty else { continue }
            let slug = title.replacingOccurrences(of: " ", with: "_")
            let encoded = slug.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? slug
            let link = "https://en.wikipedia.org/wiki/\(encoded)"
            notes.append(Note(title: title, url: link, snippet: snippet))
        }
        return notes
    }

    private static func searchURL(_ base: String, query: String, extra: [String: String], queryName: String = "q") -> URL? {
        guard var parts = URLComponents(string: base) else { return nil }
        var items = [URLQueryItem(name: queryName, value: query)]
        for key in extra.keys.sorted() {
            items.append(URLQueryItem(name: key, value: extra[key]))
        }
        parts.queryItems = items
        return parts.url
    }

    private static func json(_ url: URL, headers: [String: String]) async -> [String: Any]? {
        var request = URLRequest(url: url)
        request.timeoutInterval = 4
        request.setValue("JARVIS/1.0", forHTTPHeaderField: "User-Agent")
        for (field, value) in headers {
            request.setValue(value, forHTTPHeaderField: field)
        }
        guard let (data, response) = try? await HTTPConnections.session.data(for: request),
              let status = (response as? HTTPURLResponse)?.statusCode,
              (200..<300).contains(status) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    private static func string(_ value: Any?) -> String? {
        guard let text = value as? String else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func clip(_ text: String) -> String {
        let cap: Int = 280
        if text.count <= cap { return text }
        return String(text.prefix(cap))
    }

    private static func stripTags(_ html: String) -> String {
        var out = ""
        var inside = false
        for character in html {
            if character == "<" {
                inside = true
                continue
            }
            if character == ">" {
                inside = false
                continue
            }
            if !inside { out.append(character) }
        }
        return out
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#039;", with: "'")
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&nbsp;", with: " ")
    }
}
