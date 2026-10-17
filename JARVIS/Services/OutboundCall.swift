import Foundation

/// A briefed outbound call waiting for a spoken or tapped yes.
struct PendingCallBrief: Equatable, Sendable {
    var contactName: String
    var number: String
    var brief: String
}

/// Yes and no for a phone brief only. Other tool cards stay tap-only.
enum CallApproval {
    static func isYes(_ raw: String) -> Bool {
        let text = LocalCall.fold(raw)
        if text.contains(" but ") { return false }
        let answers: Set<String> = [
            "yes", "yeah", "yep", "yup", "yes please", "yeah please",
            "ok", "okay", "okay yes", "approve", "approved", "confirm", "confirmed",
            "do it", "go ahead", "go for it", "place the call", "make the call",
            "call them", "call him", "call her", "please do", "yes do it", "yes call them",
        ]
        return answers.contains(text)
    }

    static func isNo(_ raw: String) -> Bool {
        if LocalCall.isCancel(raw) { return true }
        let text = LocalCall.fold(raw)
        let answers: Set<String> = [
            "nope", "nah", "no thanks", "no thank you", "dont", "do not", "dont call", "do not call",
        ]
        return answers.contains(text)
    }
}

/// "call X and tell them Y" is recognised here so it never opens the Phone app.
enum BriefedCall {
    struct Request: Sendable, Equatable {
        var who: String
        var brief: String
    }

    /// Longer phrases first so "and tell them to" wins over "and tell them".
    private static let connectors = [
        "and let them know", "and let him know", "and let her know",
        "and tell them to", "and tell him to", "and tell her to",
        "and tell them", "and tell him", "and tell her",
        "and ask them to", "and ask him to", "and ask her to",
        "and ask them", "and ask him", "and ask her",
        "and say",
        "to let them know", "to tell them", "to tell him", "to tell her",
        "to ask them", "to say", "and pass on",
    ]

    static func parse(_ raw: String) -> Request? {
        let folded = stripPrefixes(LocalCall.fold(raw))
        guard let found = split(folded) else { return nil }
        let lifted = lift(original: stripPrefixesSoft(raw), connector: found.connector)
        let who = tidyWho(lifted?.who ?? found.who)
        let brief = tidyBrief(lifted?.brief ?? found.brief)
        if who.isEmpty { return nil }
        if who == "me" || who.hasPrefix("me ") { return nil }
        return Request(who: who, brief: brief)
    }

    static func phoneNumber(_ text: String) -> String? {
        let digits = text.filter { $0.isNumber }
        let letters = text.filter { $0.isLetter }
        if !letters.isEmpty || digits.count < 3 { return nil }
        var kept = ""
        for character in text where character.isNumber || character == "+" {
            kept.append(character)
        }
        return kept.isEmpty ? nil : kept
    }

    static func isEmergency(_ number: String) -> Bool {
        let digits = number.filter { $0.isNumber }
        let national: String
        if digits.hasPrefix("44"), digits.count > 2 {
            national = String(digits.dropFirst(2))
        } else if digits.hasPrefix("0") {
            national = String(digits.dropFirst())
        } else {
            national = digits
        }
        let blocked: Set<String> = ["999", "112", "911", "101", "111", "000"]
        return blocked.contains(national) || blocked.contains(digits)
    }

    private struct Found {
        var who: String
        var brief: String
        var connector: String
    }

    private static func split(_ text: String) -> Found? {
        if text.hasPrefix("give ") {
            guard let range = text.range(of: " a call") else { return nil }
            let start = text.index(text.startIndex, offsetBy: 5)
            guard start <= range.lowerBound else { return nil }
            let who = String(text[start..<range.lowerBound])
            let after = String(text[range.upperBound...]).trimmingCharacters(in: .whitespaces)
            guard let suffix = connectorSuffix(after) else { return nil }
            return Found(who: who, brief: suffix.brief, connector: suffix.connector)
        }
        guard let rest = afterVerb(text) else { return nil }
        return splitConnectors(rest)
    }

    private static func afterVerb(_ text: String) -> String? {
        let verbs = ["call ", "phone ", "ring ", "dial ", "make a call to ", "place a call to "]
        for verb in verbs where text.hasPrefix(verb) {
            return String(text.dropFirst(verb.count))
        }
        return nil
    }

    private static func splitConnectors(_ rest: String) -> Found? {
        var bestIndex: Int = Int.max
        var bestConnector = ""
        for connector in connectors {
            let needle = " " + connector
            guard let range = rest.range(of: needle) else { continue }
            let index: Int = rest.distance(from: rest.startIndex, to: range.lowerBound)
            if index < bestIndex || (index == bestIndex && connector.count > bestConnector.count) {
                bestIndex = index
                bestConnector = connector
            }
        }
        guard !bestConnector.isEmpty, let range = rest.range(of: " " + bestConnector) else { return nil }
        let who = String(rest[..<range.lowerBound])
        var brief = String(rest[range.upperBound...])
        if brief.hasPrefix(" ") { brief.removeFirst() }
        return Found(who: who, brief: brief, connector: bestConnector)
    }

    private static func connectorSuffix(_ text: String) -> (brief: String, connector: String)? {
        for connector in connectors {
            if text == connector { return ("", connector) }
            let prefix = connector + " "
            if text.hasPrefix(prefix) {
                return (String(text.dropFirst(prefix.count)), connector)
            }
        }
        return nil
    }

    /// Pulls the brief from the original words so apostrophes survive folding.
    private static func lift(original: String, connector: String) -> (who: String, brief: String)? {
        let words = connector.split(separator: " ").map(String.init)
        let pattern = words.map { NSRegularExpression.escapedPattern(for: $0) }.joined(separator: "\\s+")
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        let range = NSRange(location: 0, length: (original as NSString).length)
        guard let match = regex.firstMatch(in: original, options: [], range: range) else { return nil }
        let ns = original as NSString
        let before = ns.substring(with: NSRange(location: 0, length: match.range.location))
        let afterStart: Int = match.range.location + match.range.length
        let after = ns.substring(from: afterStart)
        guard let who = whoFrom(before), !who.isEmpty else { return nil }
        return (who, after.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private static func whoFrom(_ before: String) -> String? {
        var text = before.trimmingCharacters(in: .whitespacesAndNewlines)
        let folded = text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en_GB")).lowercased()
        let verbs = ["make a call to ", "place a call to ", "call ", "phone ", "ring ", "dial "]
        for verb in verbs where folded.hasPrefix(verb) {
            if text.count >= verb.count {
                text = String(text.dropFirst(verb.count))
            }
            break
        }
        if folded.hasPrefix("give "), text.count >= 5, let range = text.range(of: " a call", options: [.caseInsensitive]) {
            let start = text.index(text.startIndex, offsetBy: 5)
            if start <= range.lowerBound {
                return tidyWho(String(text[start..<range.lowerBound]))
            }
        }
        return tidyWho(text)
    }

    private static func tidyWho(_ raw: String) -> String {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        while text.hasPrefix(",") || text.hasPrefix(":") {
            text = String(text.dropFirst()).trimmingCharacters(in: .whitespaces)
        }
        while text.hasSuffix(",") || text.hasSuffix(":") || text.hasSuffix(".") {
            text = String(text.dropLast()).trimmingCharacters(in: .whitespaces)
        }
        let lower = text.lowercased()
        for tail in [" please", " right now", " for me"] where lower.hasSuffix(tail) {
            text = String(text.dropLast(tail.count)).trimmingCharacters(in: .whitespaces)
        }
        return text
    }

    private static func tidyBrief(_ raw: String) -> String {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        while text.hasPrefix(",") || text.hasPrefix(":") {
            text = String(text.dropFirst()).trimmingCharacters(in: .whitespaces)
        }
        let lower = text.lowercased()
        if lower.hasSuffix(" please") {
            text = String(text.dropLast(" please".count)).trimmingCharacters(in: .whitespaces)
        }
        return text
    }

    private static func stripPrefixes(_ text: String) -> String {
        var value = text
        let prefixes = ["hey jarvis ", "ok jarvis ", "okay jarvis ", "jarvis ", "please ", "can you ", "could you ", "would you "]
        var changed = true
        while changed {
            changed = false
            for prefix in prefixes where value.hasPrefix(prefix) {
                value = String(value.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
                changed = true
            }
        }
        return value
    }

    private static func stripPrefixesSoft(_ raw: String) -> String {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let prefixes = ["hey jarvis", "ok jarvis", "okay jarvis", "jarvis", "please", "can you", "could you", "would you"]
        var changed = true
        while changed {
            changed = false
            let folded = text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en_GB")).lowercased()
            for prefix in prefixes where folded.hasPrefix(prefix + " ") || folded == prefix {
                let drop = folded.hasPrefix(prefix + " ") ? prefix.count + 1 : prefix.count
                if text.count >= drop {
                    text = String(text.dropFirst(drop)).trimmingCharacters(in: .whitespacesAndNewlines)
                    while text.hasPrefix(",") {
                        text = String(text.dropFirst()).trimmingCharacters(in: .whitespacesAndNewlines)
                    }
                    changed = true
                }
                break
            }
        }
        return text
    }
}

struct StoredCallLine: Codable, Equatable, Identifiable {
    var id: String
    var role: String
    var text: String

    var label: String { role == "them" ? "Them" : "Assistant" }
}

struct StoredCall: Codable, Equatable, Identifiable {
    var id: String
    var contactName: String
    var number: String
    var brief: String
    var status: String
    var transcript: [StoredCallLine]
    var summary: String
    var detail: String
    var spoken: Bool
    var createdAt: Date
    var updatedAt: Date

    var titleStatus: String {
        switch status {
        case "not_set_up": "Not set up"
        case "placing": "Placing"
        case "ringing": "Ringing"
        case "in_progress": "On the call"
        case "wrapping": "Finishing"
        case "completed": "Completed"
        case "failed": "Failed"
        case "cancelled": "Cancelled"
        default: status
        }
    }

    static func local(name: String, number: String, brief: String, status: String, detail: String, spoken: Bool) -> StoredCall {
        let now = Date()
        let suffix = UUID().uuidString.replacingOccurrences(of: "-", with: "")
        return StoredCall(
            id: "local_\(suffix)",
            contactName: name,
            number: number,
            brief: brief,
            status: status,
            transcript: [],
            summary: "",
            detail: detail,
            spoken: spoken,
            createdAt: now,
            updatedAt: now
        )
    }
}

extension StoredCall {
    static func fromServer(_ record: PhoneCallRecord, spoken: Bool) -> StoredCall {
        let lines: [StoredCallLine] = record.transcript.enumerated().map { index, line in
            StoredCallLine(id: "\(record.id)-\(index)", role: line.role, text: line.text)
        }
        return StoredCall(
            id: record.id,
            contactName: record.contactName,
            number: record.to,
            brief: record.brief,
            status: record.status,
            transcript: lines,
            summary: record.summary ?? "",
            detail: record.error ?? "",
            spoken: spoken,
            createdAt: Self.date(record.createdAt),
            updatedAt: Self.date(record.updatedAt)
        )
    }

    private static func date(_ iso: String) -> Date {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return fractional.date(from: iso) ?? plain.date(from: iso) ?? Date()
    }
}

enum CallReport {
    static func spoken(name: String, summary: String, status: String) -> String {
        if status == "failed" {
            if summary.isEmpty { return "The call to \(name) didn't go through, sir." }
            return "The call to \(name) didn't go through, sir. \(clip(summary))"
        }
        if summary.isEmpty { return "I've finished with \(name), sir. I don't have their words yet." }
        return "Back from \(name), sir. \(clip(summary))"
    }

    private static func clip(_ text: String) -> String {
        if text.count <= 420 { return text }
        return String(text.prefix(420)) + "…"
    }
}

/// Phone call history on this iPhone. It is not stored in the memory database.
@MainActor
enum CallLogStore {
    private static let key = "jarvis.call.log.v1"

    static func entries() -> [StoredCall] {
        guard let data = UserDefaults.standard.data(forKey: key) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([StoredCall].self, from: data)) ?? []
    }

    static func add(_ row: StoredCall) {
        var rows = entries()
        rows.insert(row, at: 0)
        save(rows)
    }

    static func update(_ row: StoredCall) {
        var rows = entries()
        if let index = rows.firstIndex(where: { $0.id == row.id }) {
            rows[index] = row
        } else {
            rows.insert(row, at: 0)
        }
        save(rows)
    }

    static func remove(id: String) {
        save(entries().filter { $0.id != id })
    }

    static func openCalls() -> [StoredCall] {
        entries().filter { ["placing", "ringing", "in_progress", "wrapping"].contains($0.status) }
    }

    private static func save(_ rows: [StoredCall]) {
        var trimmed = rows
        if trimmed.count > 40 { trimmed = Array(trimmed.prefix(40)) }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(trimmed) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }
}
