import Foundation
import SwiftData

struct ResearchCard: Identifiable, Equatable {
    var id: UUID
    var title: String
    var body: String
    var sources: [Citation]
    var createdAt: Date
}

@Model
final class ResearchReport {
    var id: UUID
    var title: String
    var question: String
    var bodyText: String
    var sourcesJSON: String
    var createdAt: Date

    init(id: UUID = UUID(), title: String, question: String, bodyText: String, sourcesJSON: String, createdAt: Date = .now) {
        self.id = id
        self.title = title
        self.question = question
        self.bodyText = bodyText
        self.sourcesJSON = sourcesJSON
        self.createdAt = createdAt
    }
}

private struct StoredSource: Codable {
    var title: String
    var url: String
}

/// Saved reports live in their own store so a new model cannot disturb remembered facts.
@MainActor
enum ResearchStore {
    static let container: ModelContainer = {
        let schema = Schema([ResearchReport.self])
        let stored = ModelConfiguration("JARVISResearch", schema: schema, isStoredInMemoryOnly: false, cloudKitDatabase: .none)
        if let container = try? ModelContainer(for: schema, configurations: [stored]) {
            return container
        }
        let memory = ModelConfiguration("JARVISResearch", schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        return try! ModelContainer(for: schema, configurations: [memory])
    }()

    static func save(title: String, question: String, body: String, sources: [Citation]) {
        let packed = pack(sources)
        let report = ResearchReport(title: title, question: question, bodyText: body, sourcesJSON: packed)
        container.mainContext.insert(report)
        try? container.mainContext.save()
    }

    static func cards() -> [ResearchCard] {
        let descriptor = FetchDescriptor<ResearchReport>(sortBy: [SortDescriptor(\.createdAt, order: .reverse)])
        let rows = (try? container.mainContext.fetch(descriptor)) ?? []
        return rows.map { row in
            ResearchCard(id: row.id, title: row.title, body: row.bodyText, sources: unpack(row.sourcesJSON), createdAt: row.createdAt)
        }
    }

    static func delete(id: UUID) {
        let descriptor = FetchDescriptor<ResearchReport>()
        let rows = (try? container.mainContext.fetch(descriptor)) ?? []
        for row in rows where row.id == id {
            container.mainContext.delete(row)
        }
        try? container.mainContext.save()
    }

    private static func pack(_ sources: [Citation]) -> String {
        let rows = sources.map { StoredSource(title: $0.title, url: $0.url) }
        guard let data = try? JSONEncoder().encode(rows), let text = String(data: data, encoding: .utf8) else { return "[]" }
        return text
    }

    private static func unpack(_ raw: String) -> [Citation] {
        guard let data = raw.data(using: .utf8),
              let rows = try? JSONDecoder().decode([StoredSource].self, from: data) else { return [] }
        return rows.map { Citation(title: $0.title, url: $0.url) }
    }
}

struct ResearchOutcome: Sendable {
    var title: String
    var report: String
    var spoken: String
    var citations: [Citation]
}

/// Several grounded searches, then one cited briefing. The spoken line stays short.
@MainActor
enum DeepResearch {
    static func wants(_ text: String) -> Bool {
        var cleaned = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        cleaned = cleaned.replacingOccurrences(of: "jarvis", with: "")
        cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        let fronts = ["please ", "can you ", "could you ", "would you "]
        for front in fronts where cleaned.hasPrefix(front) {
            cleaned = String(cleaned.dropFirst(front.count)).trimmingCharacters(in: .whitespaces)
        }
        let leads = ["research", "deep dive", "deep-dive", "investigate"]
        return leads.contains { cleaned.hasPrefix($0) }
    }

    static func run(question: String, persona: String, progress: @escaping (String) -> Void) async -> ResearchOutcome {
        progress("Planning the search…")
        let endpoint = try? AppSettings.shared.resolvedEndpoint()
        let queries = await plan(question: question, endpoint: endpoint)
        var notes: [WebNotes] = []
        let total: Int = queries.count
        var index: Int = 0
        while index < queries.count {
            if Task.isCancelled { break }
            let step: Int = index + 1
            progress("Searching \(step) of \(total)…")
            let found = await search(queries[index])
            if !found.context.isEmpty || !found.citations.isEmpty {
                notes.append(found)
            }
            index += 1
        }
        progress("Writing the report…")
        let citations = merge(notes)
        let written = await synthesize(question: question, persona: persona, notes: notes, endpoint: endpoint)
        let parts = splitSpoken(written)
        let report = parts.report.isEmpty ? "I couldn't find enough to write that up." : parts.report
        let spoken = parts.spoken.isEmpty ? "I couldn't finish that research." : parts.spoken
        return ResearchOutcome(title: title(for: question), report: report, spoken: spoken, citations: citations)
    }

    private static func plan(question: String, endpoint: LLMEndpoint?) async -> [String] {
        let fallback = [clip(question, limit: 180)]
        guard let endpoint else { return fallback }
        let fast = AppSettings.shared.conversationalEndpoint(from: endpoint)
        let system = "Turn the request into exactly 3 web search queries. One query per line. No numbers or extra words."
        let temperature: Double = 0.2
        let messages = [
            ChatMessage(role: "system", content: system),
            ChatMessage(role: "user", content: question),
        ]
        let raw: String
        do {
            raw = try await LLMClient.complete(messages: messages, endpoint: fast, temperature: temperature)
        } catch {
            return fallback
        }
        var queries: [String] = []
        for line in raw.components(separatedBy: .newlines) {
            let trimmed = cleanQuery(line)
            if trimmed.isEmpty { continue }
            queries.append(clip(trimmed, limit: 180))
            if queries.count == 3 { break }
        }
        if queries.isEmpty { return fallback }
        return queries
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
        let system = "Search and report the useful facts in under 120 words. No preamble."
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
                    return WebNotes(context: clip(trimmed, limit: 900), citations: Array(cites.prefix(4)))
                }
            } catch {
                if Task.isCancelled { return WebNotes(context: "", citations: []) }
            }
            index += 1
        }
        return WebNotes(context: "", citations: [])
    }

    private static func synthesize(question: String, persona: String, notes: [WebNotes], endpoint: LLMEndpoint?) async -> String {
        var blocks: [String] = []
        var offset: Int = 0
        while offset < notes.count {
            let number: Int = offset + 1
            blocks.append("Notes \(number):\n\(notes[offset].context)")
            offset += 1
        }
        let packed = blocks.joined(separator: "\n\n")
        let fallback = packed.isEmpty ? "No notes were found." : packed
        guard let endpoint else { return fallback }
        let fast = AppSettings.shared.conversationalEndpoint(from: endpoint)
        let date = Date.now.formatted(date: .complete, time: .shortened)
        let system = """
        \(persona)
        Write a cited briefing for Sohail. British English. Four to eight short paragraphs. \
        Use only the notes. Do not invent numbers. Do not paste raw URLs. \
        Today is \(date). End with a final line in the exact form SPOKEN: two sentences that can be read aloud.
        """
        let ask = "Question: \(question)\n\n\(packed)"
        let temperature: Double = 0.4
        let messages = [
            ChatMessage(role: "system", content: system),
            ChatMessage(role: "user", content: ask),
        ]
        do {
            let raw = try await LLMClient.complete(messages: messages, endpoint: fast, temperature: temperature)
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { return fallback }
            return clip(trimmed, limit: 8000)
        } catch {
            return fallback
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

    private static func splitSpoken(_ text: String) -> (report: String, spoken: String) {
        var reportLines: [String] = []
        var spoken = ""
        for line in text.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.uppercased().hasPrefix("SPOKEN:") {
                spoken = String(trimmed.dropFirst("SPOKEN:".count)).trimmingCharacters(in: .whitespaces)
            } else {
                reportLines.append(line)
            }
        }
        let report = reportLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        if spoken.isEmpty {
            spoken = firstSentences(report)
        }
        return (report, spoken)
    }

    private static func firstSentences(_ text: String) -> String {
        var found: [String] = []
        var current = ""
        for character in text {
            current.append(character)
            if character == "." || character == "!" || character == "?" {
                let piece = current.trimmingCharacters(in: .whitespacesAndNewlines)
                if !piece.isEmpty { found.append(piece) }
                current = ""
                if found.count >= 2 { break }
            }
        }
        if found.isEmpty {
            return clip(text, limit: 280)
        }
        return found.joined(separator: " ")
    }

    private static func title(for question: String) -> String {
        clip(question.trimmingCharacters(in: .whitespacesAndNewlines), limit: 80)
    }

    private static func cleanQuery(_ line: String) -> String {
        var trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        while let first = trimmed.first {
            if first.isNumber || first == "." || first == "-" || first == ")" || first == "*" {
                trimmed.removeFirst()
                continue
            }
            break
        }
        return trimmed.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func clip(_ text: String, limit: Int) -> String {
        if text.count <= limit { return text }
        return String(text.prefix(limit))
    }
}
