import Foundation

/// "Get me quotes for X" from chat. The worker places the calls; the phone only asks.
enum ShopAround {
    static func matches(_ text: String) -> Bool {
        let folded = text.lowercased()
        if folded.range(of: #"\b(call around|ring around|shop around|compare quotes|find me a)\b"#, options: .regularExpression) != nil {
            return true
        }
        if folded.range(of: #"\b(?:get|find|compare)\s+(?:me\s+)?quotes?\b"#, options: .regularExpression) != nil {
            return true
        }
        return folded.range(
            of: #"\b(find|call|ring|get)\b.{0,48}\b(plumber|electrician|dentist|restaurant|garage|locksmith|cleaner|builder|doctor|hotel|taxi|quote|quotes)\b"#,
            options: .regularExpression
        ) != nil
    }

    /// Starts a draft list. Approve is a separate word, so a yes cannot book.
    static func confirms(_ text: String) -> Bool {
        let clean = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "[.!?]+$", with: "", options: .regularExpression)
        return ["yes", "yeah", "yep", "start", "go ahead"].contains(clean)
    }

    static func approves(_ text: String) -> Bool {
        let clean = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "[.!?]+$", with: "", options: .regularExpression)
        return clean == "approve"
    }

    static func phones(in text: String) -> [String] {
        let pattern = #"\+\d{8,15}|\+\d{1,3}(?:[\s.-]\d{2,4}){2,3}|\b0\d{4}[\s.-]\d{6}\b|\b0\d{3}[\s.-]\d{3}[\s.-]\d{4}\b|\b0\d{2}[\s.-]\d{4}[\s.-]\d{4}\b|\b0\d{9,10}\b"#
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        var found: [String] = []
        for match in expression.matches(in: text, range: range) {
            guard let slice = Range(match.range, in: text) else { continue }
            let phone = String(text[slice])
            if LocalCall.isEmergency(phone) || found.contains(phone) { continue }
            found.append(phone)
            if found.count >= 5 { break }
        }
        return found
    }

    static func providers(in text: String) -> [[String: String]] {
        phones(in: text).enumerated().map { index, phone in
            ["business": "Business \(index + 1)", "phone": phone]
        }
    }
}
