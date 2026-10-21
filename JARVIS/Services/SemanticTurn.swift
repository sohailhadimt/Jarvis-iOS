import Foundation

/// How quickly JARVIS decides the user has finished, following the published
/// Realtime `semantic_vad` eagerness control.
///
/// OpenAI documents `low`, `medium`, and `high` maximum waits of 8s, 4s, and 2s.
/// `auto` is defined as `medium`. LiveKit's turn detector uses a lower
/// `unlikely_threshold` to become more eager. Both are applied here.
enum TurnEagerness: String, CaseIterable, Identifiable, Sendable {
    case low, medium, high

    var id: String { rawValue }

    var title: String {
        switch self {
        case .low: "Low"
        case .medium: "Medium"
        case .high: "High"
        }
    }

    /// Published semantic VAD maximum wait.
    var maxTimeoutMs: Int {
        switch self {
        case .low: 8_000
        case .medium: 4_000
        case .high: 2_000
        }
    }

    /// End-of-turn probability at or above this commits on the short pause.
    /// A lower threshold commits more turns, which is the eager setting.
    var unlikelyThreshold: Float {
        switch self {
        case .low: 0.65
        case .medium: 0.50
        case .high: 0.35
        }
    }
}

/// On-device end-of-turn score for the transcript.
///
/// This is the published semantic VAD loop: a probability that the words are finished,
/// not a silence timer. LiveKit's open turn-detector weights are not in this build.
/// The score uses the same job as `predict_end_of_turn`: 1 means the turn looks finished.
enum SemanticTurn {
    /// Speak a short acknowledgement only after the reply has been silent this long.
    static let fillerAfterMs = 1_200

    static func probability(_ text: String) -> Float {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return 0 }
        let lower = trimmed.lowercased()
        let words = tokens(lower)
        if words.isEmpty { return 0 }
        let ended = sentenceMark(lower)
        if !ended, let last = words.last, fillers.contains(last) { return 0.12 }
        if !ended, let last = words.last, continuations.contains(last) { return 0.22 }
        if lower.hasSuffix(",") || lower.hasSuffix("…") || lower.hasSuffix("...") { return 0.32 }
        let core = lower.trimmingCharacters(in: CharacterSet(charactersIn: ".?!…"))
        if closers.contains(core) { return 0.92 }
        if words.count == 1, let only = words.first, commands.contains(only) { return 0.92 }

        var score: Float = 0.28
        if ended { score += 0.50 }
        if words.count >= 4 { score += 0.12 }
        if isQuestion(words), words.count >= 3, let last = words.last, !continuations.contains(last) {
            score += 0.28
        }
        if ended, words.count >= 3, let last = words.last, !continuations.contains(last), !fillers.contains(last) {
            score += 0.08
        }
        return min(1, max(0, score))
    }

    private static func sentenceMark(_ lower: String) -> Bool {
        guard let last = lower.last else { return false }
        return last == "." || last == "?" || last == "!"
    }

    private static func tokens(_ lower: String) -> [String] {
        lower.split { character in
            !character.isLetter && !character.isNumber && character != "'"
        }.map(String.init)
    }

    private static func isQuestion(_ words: [String]) -> Bool {
        guard let first = words.first else { return false }
        return questions.contains(first)
    }

    private static let fillers: Set<String> = ["uh", "um", "uhm", "uhhm", "hmm", "er", "ah", "like"]
    private static let continuations: Set<String> = [
        "and", "or", "but", "so", "because", "if", "when", "while", "to", "the", "a", "an",
        "of", "with", "for", "in", "on", "at", "that", "which", "from", "into", "about", "then", "also"
    ]
    private static let questions: Set<String> = [
        "who", "what", "when", "where", "why", "how", "is", "are", "can", "could",
        "do", "does", "did", "will", "would", "should", "may"
    ]
    private static let commands: Set<String> = ["yes", "no", "stop", "nope", "yeah", "okay", "ok", "thanks", "hello"]
    private static let closers: Set<String> = [
        "thank you", "thanks", "that is all", "that's all", "that's it", "that is it",
        "go ahead", "never mind", "nevermind"
    ]
}
