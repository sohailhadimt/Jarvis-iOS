import Foundation
import SwiftData

@Model
final class MemoryFact {
    var text: String
    var createdAt: Date

    init(text: String, createdAt: Date = .now) {
        self.text = text
        self.createdAt = createdAt
    }
}

@MainActor
enum JarvisStore {
    static let container: ModelContainer = {
        do {
            return try ModelContainer(for: MemoryFact.self)
        } catch {
            // Last resort so the app still launches; memory won't persist in this case.
            return try! ModelContainer(for: MemoryFact.self,
                                       configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        }
    }()

    static func allFacts() -> [MemoryFact] {
        let descriptor = FetchDescriptor<MemoryFact>(sortBy: [SortDescriptor(\.createdAt)])
        return (try? container.mainContext.fetch(descriptor)) ?? []
    }

    /// Inserts facts that are not already stored. The returned lines are the new ones.
    @discardableResult
    static func add(_ texts: [String]) -> [String] {
        guard !texts.isEmpty else { return [] }
        var existing = Set(allFacts().map { $0.text.lowercased() })
        var saved: [String] = []
        for raw in texts {
            let fact = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if fact.isEmpty { continue }
            let key = fact.lowercased()
            if existing.contains(key) { continue }
            existing.insert(key)
            container.mainContext.insert(MemoryFact(text: fact))
            saved.append(fact)
        }
        if !saved.isEmpty {
            try? container.mainContext.save()
        }
        return saved
    }
}

/// Picks the memories that share words with the question. Recent facts stand in when nothing overlaps.
enum MemoryRank {
    static func relevant(_ facts: [MemoryFact], to question: String, limit: Int) -> [MemoryFact] {
        let cap: Int = max(limit, 0)
        if cap == 0 || facts.isEmpty { return [] }
        let tokens = Set(words(in: question))
        if tokens.isEmpty {
            return Array(facts.suffix(cap))
        }
        var ranked: [(MemoryFact, Int)] = []
        for fact in facts {
            var score: Int = 0
            let factWords = words(in: fact.text)
            for word in factWords where tokens.contains(word) {
                score += 1
            }
            if score > 0 {
                ranked.append((fact, score))
            }
        }
        if ranked.isEmpty {
            let recentCap: Int = min(cap, 2)
            return Array(facts.suffix(recentCap))
        }
        ranked.sort { lhs, rhs in
            if lhs.1 == rhs.1 { return lhs.0.createdAt > rhs.0.createdAt }
            return lhs.1 > rhs.1
        }
        return ranked.prefix(cap).map(\.0)
    }

    private static func words(in text: String) -> [String] {
        let lower = text.lowercased()
        let parts = lower.split { character in
            !character.isLetter && !character.isNumber
        }
        return parts.map(String.init).filter { word in
            word.count > 2 && !stop.contains(word)
        }
    }

    private static let stop: Set<String> = [
        "the", "and", "for", "that", "this", "with", "you", "your", "are", "was", "but",
        "have", "has", "not", "sir", "jarvis", "what", "when", "where", "who", "how", "can",
    ]
}

/// Extracts lines like "REMEMBER: Sohail prefers tea" from a model reply.
enum MemoryParser {
    static func extract(from reply: String) -> (cleaned: String, facts: [String]) {
        var facts: [String] = []
        var kept: [String] = []
        for line in reply.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.uppercased().hasPrefix("REMEMBER:") {
                let fact = trimmed.dropFirst("REMEMBER:".count).trimmingCharacters(in: .whitespaces)
                if !fact.isEmpty { facts.append(fact) }
            } else {
                kept.append(line)
            }
        }
        return (kept.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines), facts)
    }
}
