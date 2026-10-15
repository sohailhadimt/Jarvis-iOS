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

    static func add(_ texts: [String]) {
        guard !texts.isEmpty else { return }
        let existing = Set(allFacts().map { $0.text.lowercased() })
        for t in texts where !existing.contains(t.lowercased()) {
            container.mainContext.insert(MemoryFact(text: t))
        }
        try? container.mainContext.save()
    }
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
