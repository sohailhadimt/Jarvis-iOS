import Contacts
import Foundation

struct PhoneLine: Sendable, Hashable {
    var label: String
    var number: String
}

struct IndexedContact: Sendable, Identifiable {
    var id: String
    var displayName: String
    var phones: [PhoneLine]
    var keys: [String]

    var bestPhone: PhoneLine? {
        phones.first { line in
            let label = line.label.lowercased()
            return label.contains("mobile") || label.contains("iphone") || label.contains("cell")
        } ?? phones.first
    }
}

struct CallChoice: Identifiable, Hashable, Sendable {
    var id: String
    var name: String
    var subtitle: String
    var number: String
}

enum CallLookup: Sendable {
    case dial(name: String, number: String)
    case choose([CallChoice])
    case missing
}

/// One in-memory pass over the address book. Later "call X" matches happen here.
@MainActor
final class ContactDirectory {
    static let shared = ContactDirectory()

    private var entries: [IndexedContact] = []
    private var ready = false
    private var generation: Int = 0
    private var loadTask: Task<Bool, Never>?
    private var changeObserver: NSObjectProtocol?

    private init() {}

    /// Loads only when Contacts is already allowed. Asking for "call X" requests access.
    func warm() {
        observeChanges()
        let status = CNContactStore.authorizationStatus(for: .contacts)
        guard status == .authorized || status == .limited else { return }
        _ = beginLoad(ask: false)
    }

    func ensureLoaded() async -> Bool {
        observeChanges()
        if ready { return true }
        while !ready {
            let task = beginLoad(ask: true)
            let finished = await task.value
            if ready { return true }
            loadTask = nil
            if !finished { return false }
        }
        return true
    }

    func lookup(_ query: String) -> CallLookup {
        let ranked = rank(query)
        guard let top = ranked.first, let phone = top.contact.bestPhone else { return .missing }
        if ranked.count == 1, top.score >= 80 {
            return .dial(name: top.contact.displayName, number: phone.number)
        }
        if ranked.count > 1 {
            let second: Int = ranked[1].score
            if top.score >= 88, second < 80 {
                return .dial(name: top.contact.displayName, number: phone.number)
            }
        }
        let choices: [CallChoice] = ranked.prefix(5).compactMap { row in
            guard let line = row.contact.bestPhone else { return nil }
            return CallChoice(id: row.contact.id, name: row.contact.displayName,
                              subtitle: "\(line.label) \(line.number)", number: line.number)
        }
        guard !choices.isEmpty else { return .missing }
        return .choose(choices)
    }

    func pick(_ spoken: String, from choices: [CallChoice]) -> CallChoice? {
        let folded = LocalCall.fold(spoken)
        if let index = Self.ordinal(folded), choices.indices.contains(index) {
            return choices[index]
        }
        let query = Self.normalize(spoken)
        guard !query.isEmpty else { return nil }
        var best: CallChoice?
        var bestScore: Int = 0
        var ties: Int = 0
        for choice in choices {
            let score: Int = Self.score(query: query, candidate: Self.normalize(choice.name))
            if score > bestScore {
                best = choice
                bestScore = score
                ties = 1
            } else if score == bestScore, score > 0 {
                ties += 1
            }
        }
        guard let best, bestScore >= 80, ties == 1 else { return nil }
        return best
    }

    func hits(matching query: String) -> [ContactHit] {
        rank(query).map { row in
            let phones = row.contact.phones.map { (label: $0.label, number: $0.number) }
            return ContactHit(name: row.contact.displayName, phones: phones, emails: [])
        }
    }

    private func rank(_ query: String) -> [(contact: IndexedContact, score: Int)] {
        let spaced: String = Self.normalize(query)
        let tight: String = Self.compact(spaced)
        guard !spaced.isEmpty else { return [] }
        var ranked: [(contact: IndexedContact, score: Int)] = []
        for contact in entries {
            var best: Int = 0
            for key in contact.keys {
                let spacedScore: Int = Self.score(query: spaced, candidate: key)
                let tightScore: Int = tight == spaced ? 0 : Self.score(query: tight, candidate: key)
                let chosen: Int = max(spacedScore, tightScore)
                if chosen > best { best = chosen }
            }
            if best >= 64 {
                ranked.append((contact: contact, score: best))
            }
        }
        ranked.sort { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            return lhs.contact.displayName < rhs.contact.displayName
        }
        if ranked.count > 8 {
            ranked = Array(ranked.prefix(8))
        }
        return ranked
    }

    private func beginLoad(ask: Bool) -> Task<Bool, Never> {
        if let loadTask { return loadTask }
        generation += 1
        let token: Int = generation
        let task = Task.detached(priority: .utility) { () -> Bool in
            let granted = await Self.allowed(ask: ask)
            guard granted else { return false }
            let items = Self.fetch()
            await ContactDirectory.shared.replace(items, token: token)
            return true
        }
        loadTask = task
        return task
    }

    private func replace(_ items: [IndexedContact], token: Int) {
        guard token == generation else { return }
        entries = items
        ready = true
    }

    private func reload() {
        ready = false
        loadTask = nil
        let status = CNContactStore.authorizationStatus(for: .contacts)
        guard status == .authorized || status == .limited else { return }
        _ = beginLoad(ask: false)
    }

    private func observeChanges() {
        guard changeObserver == nil else { return }
        changeObserver = NotificationCenter.default.addObserver(
            forName: .CNContactStoreDidChange,
            object: nil,
            queue: .main
        ) { _ in
            Task { @MainActor in
                ContactDirectory.shared.reload()
            }
        }
    }

    private nonisolated static func allowed(ask: Bool) async -> Bool {
        let status = CNContactStore.authorizationStatus(for: .contacts)
        if status == .authorized || status == .limited { return true }
        guard ask else { return false }
        return await Permissions.contacts()
    }

    /// Keys are only the name fields and phone numbers. Enumeration runs off the main actor.
    private nonisolated static func fetch() -> [IndexedContact] {
        let store = CNContactStore()
        let keys = [
            CNContactGivenNameKey,
            CNContactFamilyNameKey,
            CNContactNicknameKey,
            CNContactPhoneNumbersKey,
        ] as [CNKeyDescriptor]
        let request = CNContactFetchRequest(keysToFetch: keys)
        request.unifyResults = true
        var found: [IndexedContact] = []
        do {
            try store.enumerateContacts(with: request) { contact, _ in
                let phones: [PhoneLine] = contact.phoneNumbers.compactMap { labeled in
                    let number = labeled.value.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !number.isEmpty else { return nil }
                    let label = CNLabeledValue<CNPhoneNumber>.localizedString(forLabel: labeled.label ?? CNLabelPhoneNumberMain)
                    return PhoneLine(label: label, number: number)
                }
                guard !phones.isEmpty else { return }
                let given = contact.givenName
                let family = contact.familyName
                let nickname = contact.nickname
                let display = displayName(given: given, family: family, nickname: nickname)
                let keys = indexKeys(given: given, family: family, nickname: nickname, display: display)
                found.append(IndexedContact(id: contact.identifier, displayName: display, phones: phones, keys: keys))
            }
        } catch {
            return found
        }
        return found
    }

    private nonisolated static func displayName(given: String, family: String, nickname: String) -> String {
        let full = [given, family].filter { !$0.isEmpty }.joined(separator: " ")
        if !full.isEmpty { return full }
        if !nickname.isEmpty { return nickname }
        return "Unknown"
    }

    private nonisolated static func indexKeys(given: String, family: String, nickname: String, display: String) -> [String] {
        var keys: [String] = []
        func add(_ raw: String) {
            let key = normalize(raw)
            guard !key.isEmpty, !keys.contains(key) else { return }
            keys.append(key)
            let tight = compact(key)
            if tight != key, !keys.contains(tight) { keys.append(tight) }
        }
        add(display)
        add(given)
        add(family)
        add(nickname)
        return keys
    }

    private nonisolated static func normalize(_ raw: String) -> String {
        let folded = raw.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en_GB")).lowercased()
        var out = ""
        var spaced = false
        for character in folded {
            if character.isLetter || character.isNumber {
                out.append(character)
                spaced = false
            } else if character.isWhitespace, !out.isEmpty, !spaced {
                out.append(" ")
                spaced = true
            }
        }
        return out.trimmingCharacters(in: .whitespaces)
    }

    private nonisolated static func compact(_ key: String) -> String {
        key.replacingOccurrences(of: " ", with: "")
    }

    private nonisolated static func score(query: String, candidate: String) -> Int {
        if query.isEmpty || candidate.isEmpty { return 0 }
        if candidate == query { return 100 }
        let queryCount: Int = query.count
        if queryCount < 2 { return 0 }
        if candidate.hasPrefix(query) { return 88 }
        let candidateCount: Int = candidate.count
        if query.hasPrefix(candidate), candidateCount >= 3 { return 80 }
        if candidate.contains(query) { return 64 }
        let gap: Int = queryCount > candidateCount ? queryCount - candidateCount : candidateCount - queryCount
        if queryCount >= 4, gap <= 1 {
            let distance: Int = editDistance(query, candidate)
            if distance == 1 { return 72 }
        }
        return 0
    }

    private nonisolated static func editDistance(_ left: String, _ right: String) -> Int {
        let a: [Character] = Array(left)
        let b: [Character] = Array(right)
        let n: Int = a.count
        let m: Int = b.count
        if n == 0 { return m }
        if m == 0 { return n }
        var previous: [Int] = []
        previous.reserveCapacity(m + 1)
        var column: Int = 0
        while column <= m {
            previous.append(column)
            column += 1
        }
        var row: Int = 1
        while row <= n {
            var current: [Int] = [row]
            var col: Int = 1
            while col <= m {
                let cost: Int = a[row - 1] == b[col - 1] ? 0 : 1
                let deletion: Int = previous[col] + 1
                let insertion: Int = current[col - 1] + 1
                let substitution: Int = previous[col - 1] + cost
                let best: Int = min(deletion, min(insertion, substitution))
                current.append(best)
                col += 1
            }
            previous = current
            row += 1
        }
        return previous[m]
    }

    private static func ordinal(_ folded: String) -> Int? {
        let words = folded.split(separator: " ").map(String.init)
        let token = words.last ?? folded
        switch token {
        case "1", "one", "first": return 0
        case "2", "two", "second": return 1
        case "3", "three", "third": return 2
        case "4", "four", "fourth": return 3
        case "5", "five", "fifth": return 4
        default: return nil
        }
    }
}

/// "call X" is recognised here so the phone app opens before any model request.
enum LocalCall {
    struct Request: Sendable {
        var spoken: String
        var number: String?
    }

    static func parse(_ raw: String) -> Request? {
        var text = fold(raw)
        for prefix in ["hey jarvis ", "ok jarvis ", "okay jarvis ", "jarvis ", "please ", "can you ", "could you ", "would you "] {
            text = strip(text, prefix: prefix)
        }
        let name: String
        if let captured = capture(text, verbs: ["call", "phone", "ring", "dial"]) {
            name = captured
        } else if text.hasPrefix("make a call to ") {
            name = String(text.dropFirst("make a call to ".count))
        } else if text.hasPrefix("place a call to ") {
            name = String(text.dropFirst("place a call to ".count))
        } else if let captured = giveCall(text) {
            name = captured
        } else {
            return nil
        }
        var cleaned = name.trimmingCharacters(in: .whitespacesAndNewlines)
        for tail in [" please", " right now", " now", " for me", " on mobile", " on his mobile", " on her mobile",
                     " on their mobile", " on the phone", " on phone"] {
            if cleaned.hasSuffix(tail) { cleaned = String(cleaned.dropLast(tail.count)) }
        }
        cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.isEmpty { return nil }
        if cleaned == "me" || cleaned.hasPrefix("me ") { return nil }
        if cleaned == "it" || cleaned.hasPrefix("it ") { return nil }
        if cleaned.contains("facetime") || cleaned.contains("video") { return nil }
        if let number = phoneNumber(cleaned) {
            return Request(spoken: number, number: number)
        }
        return Request(spoken: cleaned, number: nil)
    }

    static func isCancel(_ raw: String) -> Bool {
        let text = fold(raw)
        return text == "cancel" || text == "never mind" || text == "stop" || text == "no"
    }

    static func fold(_ raw: String) -> String {
        let lowered = raw.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en_GB")).lowercased()
        var out = ""
        var pendingSpace = false
        for character in lowered {
            if character.isLetter || character.isNumber || character == "+" {
                if pendingSpace, !out.isEmpty { out.append(" ") }
                pendingSpace = false
                out.append(character)
            } else if character.isWhitespace || character.isPunctuation {
                pendingSpace = true
            }
        }
        return out.trimmingCharacters(in: .whitespaces)
    }

    private static func strip(_ text: String, prefix: String) -> String {
        guard text.hasPrefix(prefix) else { return text }
        return String(text.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
    }

    private static func capture(_ text: String, verbs: [String]) -> String? {
        for verb in verbs {
            let prefix = verb + " "
            if text.hasPrefix(prefix) {
                return String(text.dropFirst(prefix.count))
            }
        }
        return nil
    }

    private static func giveCall(_ text: String) -> String? {
        guard text.hasPrefix("give ") else { return nil }
        if let range = text.range(of: " a call") {
            let name = text[text.index(text.startIndex, offsetBy: 5)..<range.lowerBound]
            return String(name)
        }
        if let range = text.range(of: " a ring") {
            let name = text[text.index(text.startIndex, offsetBy: 5)..<range.lowerBound]
            return String(name)
        }
        return nil
    }

    private static func phoneNumber(_ text: String) -> String? {
        let digits = text.filter { $0.isNumber }
        let letters = text.filter { $0.isLetter }
        if !letters.isEmpty || digits.count < 3 { return nil }
        var kept = ""
        for character in text where character.isNumber || character == "+" {
            kept.append(character)
        }
        return kept.isEmpty ? nil : kept
    }
}
