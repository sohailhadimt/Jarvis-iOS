import Foundation

struct NewsBriefing: Equatable {
    var text: String
    var citations: [Citation]
    var createdAt: Date
}

/// The last world briefing, kept on this iPhone. Cloud "what's been happening" is a different path.
enum NewsPulseStore {
    private static let textKey = "jarvis.news.text"
    private static let sourcesKey = "jarvis.news.sources"
    private static let dateKey = "jarvis.news.date"

    static func save(text: String, citations: [Citation]) {
        let defaults = UserDefaults.standard
        defaults.set(text, forKey: textKey)
        defaults.set(Date.now.timeIntervalSince1970, forKey: dateKey)
        let rows = citations.map { ["title": $0.title, "url": $0.url] }
        if let data = try? JSONSerialization.data(withJSONObject: rows) {
            defaults.set(data, forKey: sourcesKey)
        }
    }

    static func load() -> NewsBriefing? {
        let defaults = UserDefaults.standard
        guard let text = defaults.string(forKey: textKey), !text.isEmpty else { return nil }
        let stamp = defaults.double(forKey: dateKey)
        let created = stamp > 0 ? Date(timeIntervalSince1970: stamp) : Date.now
        var citations: [Citation] = []
        if let data = defaults.data(forKey: sourcesKey),
           let rows = try? JSONSerialization.jsonObject(with: data) as? [[String: String]] {
            for row in rows {
                let url = row["url"] ?? ""
                guard url.hasPrefix("http") else { continue }
                let title = row["title"] ?? "Source"
                citations.append(Citation(title: title, url: url))
            }
        }
        return NewsBriefing(text: text, citations: citations, createdAt: created)
    }
}

/// A short 'what's happening' briefing from grounded search. Not the cloud work briefing.
@MainActor
enum NewsPulse {
    static func wants(_ text: String) -> Bool {
        let lower = text.lowercased()
        if lower.contains("been happening") || lower.contains("have you been") || lower.contains("what has been") {
            return false
        }
        let needles = [
            "what's happening", "whats happening", "the news", "headlines",
            "news briefing", "news pulse", "in the news",
        ]
        return needles.contains { lower.contains($0) }
    }

    static func run(question: String, persona: String, progress: @escaping (String) -> Void) async -> (report: String, spoken: String, citations: [Citation]) {
        progress("Checking the news…")
        let queries = plan(question)
        var notes: [WebNotes] = []
        let total: Int = queries.count
        var index: Int = 0
        while index < queries.count {
            if Task.isCancelled { break }
            let step: Int = index + 1
            progress("Headline \(step) of \(total)…")
            let found = await search(queries[index])
            if !found.context.isEmpty || !found.citations.isEmpty {
                notes.append(found)
            }
            index += 1
        }
        progress("Writing the briefing…")
        let citations = merge(notes)
        let written = await synthesize(question: question, persona: persona, notes: notes)
        let spoken = firstSentences(written, limit: 3)
        let report = written.isEmpty ? "I couldn't find a news briefing just now." : written
        return (report, spoken.isEmpty ? report : spoken, citations)
    }

    private static func plan(_ question: String) -> [String] {
        var folded = question.lowercased().replacingOccurrences(of: "jarvis", with: "")
        folded = folded.trimmingCharacters(in: .whitespacesAndNewlines)
        folded = folded.trimmingCharacters(in: .punctuationCharacters)
        let bare: Set<String> = [
            "what's happening", "whats happening", "what is happening",
            "the news", "what's the news", "whats the news",
            "headlines", "the headlines", "news briefing", "news pulse",
        ]
        if bare.contains(folded) {
            return ["top world news headlines today", "UK news headlines today"]
        }
        let clipped = question.count > 180 ? String(question.prefix(180)) : question
        return [clipped]
    }

    private static func search(_ query: String) async -> WebNotes {
        if let key = KeychainStore.get(.gemini), !key.isEmpty {
            let grounded = await grounded(query: query, apiKey: key)
            if !grounded.context.isEmpty { return grounded }
        }
        return await FreeWebSearch.gather(query: query)
    }

    private static func grounded(query: String, apiKey: String) async -> WebNotes {
        var models: [String] = [AppSettings.fastGeminiModel]
        if AppSettings.defaultGeminiModel != AppSettings.fastGeminiModel {
            models.append(AppSettings.defaultGeminiModel)
        }
        let user = ChatMessage(role: "user", content: query)
        let system = "Search and list the main headlines in under 120 words. No preamble."
        var index: Int = 0
        while index < models.count {
            let model = models[index]
            do {
                let stream = GeminiGrounding.stream(system: system, history: [], user: user, model: model, apiKey: apiKey)
                var text = ""
                var cites: [Citation] = []
                for try await delta in stream {
                    try Task.checkCancellation()
                    text += delta.text
                    for cite in delta.citations where !cites.contains(where: { $0.url == cite.url }) {
                        cites.append(cite)
                    }
                }
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    let clipped = trimmed.count > 900 ? String(trimmed.prefix(900)) : trimmed
                    return WebNotes(context: clipped, citations: Array(cites.prefix(4)))
                }
            } catch {
                if Task.isCancelled { return WebNotes(context: "", citations: []) }
            }
            index += 1
        }
        return WebNotes(context: "", citations: [])
    }

    private static func synthesize(question: String, persona: String, notes: [WebNotes]) async -> String {
        var blocks: [String] = []
        var offset: Int = 0
        while offset < notes.count {
            let number: Int = offset + 1
            blocks.append("Notes \(number):\n\(notes[offset].context)")
            offset += 1
        }
        let packed = blocks.joined(separator: "\n\n")
        if packed.isEmpty { return "" }
        guard let endpoint = try? AppSettings.shared.resolvedEndpoint() else { return packed }
        let fast = AppSettings.shared.conversationalEndpoint(from: endpoint)
        let date = Date.now.formatted(date: .complete, time: .shortened)
        let system = """
        \(persona)
        Give Sohail a news briefing. British English. Five short sentences. Use only the notes. \
        Do not invent numbers. Do not paste raw URLs. Today is \(date).
        """
        let temperature: Double = 0.4
        let messages = [
            ChatMessage(role: "system", content: system),
            ChatMessage(role: "user", content: "Question: \(question)\n\n\(packed)"),
        ]
        do {
            let raw = try await LLMClient.complete(messages: messages, endpoint: fast, temperature: temperature)
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { return packed }
            return trimmed.count > 2000 ? String(trimmed.prefix(2000)) : trimmed
        } catch {
            return packed
        }
    }

    private static func merge(_ notes: [WebNotes]) -> [Citation] {
        var cites: [Citation] = []
        for note in notes {
            for cite in note.citations where !cites.contains(where: { $0.url == cite.url }) {
                cites.append(cite)
                if cites.count >= 8 { return cites }
            }
        }
        return cites
    }

    private static func firstSentences(_ text: String, limit: Int) -> String {
        var found: [String] = []
        var current = ""
        for character in text {
            current.append(character)
            if character == "." || character == "!" || character == "?" {
                let piece = current.trimmingCharacters(in: .whitespacesAndNewlines)
                if !piece.isEmpty { found.append(piece) }
                current = ""
                if found.count >= limit { break }
            }
        }
        if found.isEmpty { return text }
        return found.joined(separator: " ")
    }
}
