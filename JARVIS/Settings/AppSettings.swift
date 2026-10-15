import Foundation
import Observation
import SwiftUI
import WidgetKit

enum LLMProvider: String, CaseIterable, Identifiable {
    case openAI, custom
    var id: String { rawValue }
    var title: String {
        switch self {
        case .openAI: "OpenAI"
        case .custom: "Custom agent endpoint"
        }
    }
}

enum TaskRouting: String, CaseIterable, Identifiable {
    case split, auto, chatOnly
    var id: String { rawValue }
    var title: String {
        switch self {
        case .split: "Questions → ChatGPT, actions → tools"
        case .auto: "Smart: model picks tools for everything"
        case .chatOnly: "Chat only (no tools)"
        }
    }
}

struct RegisteredShortcut: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var note: String
}

enum PersonalityPreset: String, CaseIterable, Identifiable {
    case jarvis, concise, friendly
    var id: String { rawValue }
    var title: String {
        switch self {
        case .jarvis: "J.A.R.V.I.S. (British butler)"
        case .concise: "Concise"
        case .friendly: "Friendly"
        }
    }
    var prompt: String {
        switch self {
        case .jarvis:
            "You are J.A.R.V.I.S., a refined British AI butler serving Sohail in the United Kingdom. "
            + "You are impeccably polite, dryly witty and quietly competent. Address him as \"sir\" occasionally. "
            + "Use British spelling, the metric system, °C and GBP unless asked otherwise."
        case .concise:
            "You are a precise voice assistant. Answer in one or two short sentences. No filler, no pleasantries."
        case .friendly:
            "You are a warm, upbeat and encouraging voice assistant for Sohail in the UK. Be casual and kind, keep it brief."
        }
    }
}

@MainActor
@Observable
final class AppSettings {
    static let shared = AppSettings()
    static let modelSuggestions = ["gpt-4o-mini", "gpt-4o", "gpt-4.1-mini", "gpt-4.1"]

    @ObservationIgnored private let d = UserDefaults.standard

    var personality: String { didSet { d.set(personality, forKey: "personality") } }
    var instructions: String { didSet { d.set(instructions, forKey: "instructions") } }
    var autoRemember: Bool { didSet { d.set(autoRemember, forKey: "autoRemember") } }
    var provider: LLMProvider { didSet { d.set(provider.rawValue, forKey: "provider") } }
    var openAIModel: String { didSet { d.set(openAIModel, forKey: "openAIModel") } }
    var customBaseURL: String { didSet { d.set(customBaseURL, forKey: "customBaseURL") } }
    var customModel: String { didSet { d.set(customModel, forKey: "customModel") } }
    var voiceID: String { didSet { d.set(voiceID, forKey: "voiceID") } }
    var voiceName: String { didSet { d.set(voiceName, forKey: "voiceName") } }
    var stability: Double { didSet { d.set(stability, forKey: "stability") } }
    var similarity: Double { didSet { d.set(similarity, forKey: "similarity") } }
    var autoStandBy: Bool { didSet { d.set(autoStandBy, forKey: "autoStandBy") } }
    var routing: TaskRouting { didSet { d.set(routing.rawValue, forKey: "routing") } }
    var searchModel: String { didSet { d.set(searchModel, forKey: "searchModel") } }
    var shortcuts: [RegisteredShortcut] {
        didSet { d.set(try? JSONEncoder().encode(shortcuts), forKey: "shortcuts") }
    }
    var timerShortcut: String { didSet { d.set(timerShortcut, forKey: "timerShortcut") } }
    var alarmShortcut: String { didSet { d.set(alarmShortcut, forKey: "alarmShortcut") } }
    var musicShortcut: String { didSet { d.set(musicShortcut, forKey: "musicShortcut") } }
    var countryCode: String { didSet { d.set(countryCode, forKey: "countryCode") } }
    var agentWebhookURL: String { didSet { d.set(agentWebhookURL, forKey: "agentWebhookURL") } }
    var agentWebhookName: String { didSet { d.set(agentWebhookName, forKey: "agentWebhookName") } }
    var grokBotWebhookURL: String { didSet { d.set(grokBotWebhookURL, forKey: "grokBotWebhookURL") } }
    var primaryHex: String { didSet { persistColour(primaryHex, key: SharedConfig.Key.primaryHex) } }
    var accentHex: String { didSet { persistColour(accentHex, key: SharedConfig.Key.accentHex) } }

    var primaryColor: Color { Color(hex: primaryHex) }
    var accentColor: Color { Color(hex: accentHex) }

    private init() {
        let d = UserDefaults.standard
        personality = d.string(forKey: "personality") ?? PersonalityPreset.jarvis.prompt
        instructions = d.string(forKey: "instructions")
            ?? "Your replies are spoken aloud, so keep them short and conversational. Never use markdown, lists or emojis."
        autoRemember = d.object(forKey: "autoRemember") as? Bool ?? true
        provider = LLMProvider(rawValue: d.string(forKey: "provider") ?? "") ?? .openAI
        openAIModel = d.string(forKey: "openAIModel") ?? "gpt-4o-mini"
        customBaseURL = d.string(forKey: "customBaseURL") ?? ""
        customModel = d.string(forKey: "customModel") ?? ""
        voiceID = d.string(forKey: "voiceID") ?? ElevenLabsClient.defaultVoiceID
        voiceName = d.string(forKey: "voiceName") ?? "George"
        stability = d.object(forKey: "stability") as? Double ?? 0.5
        similarity = d.object(forKey: "similarity") as? Double ?? 0.75
        autoStandBy = d.object(forKey: "autoStandBy") as? Bool ?? true
        routing = TaskRouting(rawValue: d.string(forKey: "routing") ?? "") ?? .split
        searchModel = d.string(forKey: "searchModel") ?? "gpt-4.1-mini"
        shortcuts = (d.data(forKey: "shortcuts")).flatMap { try? JSONDecoder().decode([RegisteredShortcut].self, from: $0) } ?? []
        timerShortcut = d.string(forKey: "timerShortcut") ?? "JARVIS Timer"
        alarmShortcut = d.string(forKey: "alarmShortcut") ?? "JARVIS Alarm"
        musicShortcut = d.string(forKey: "musicShortcut") ?? ""
        countryCode = d.string(forKey: "countryCode") ?? "44"
        agentWebhookURL = d.string(forKey: "agentWebhookURL") ?? ""
        agentWebhookName = d.string(forKey: "agentWebhookName") ?? "your agent"
        grokBotWebhookURL = d.string(forKey: "grokBotWebhookURL") ?? ""
        let resolvedPrimary = Self.replacingFactoryDefault(d.string(forKey: SharedConfig.Key.primaryHex),
                                                          previous: ["00D8FFFF", "00D8FF"],
                                                          fallback: Theme.defaultPrimaryHex)
        let resolvedAccent = Self.replacingFactoryDefault(d.string(forKey: SharedConfig.Key.accentHex),
                                                         previous: ["D4AF37FF", "D4AF37"],
                                                         fallback: Theme.defaultAccentHex)
        primaryHex = resolvedPrimary
        accentHex = resolvedAccent
        // didSet does not run during init, so write a migrated factory colour through explicitly.
        if d.string(forKey: SharedConfig.Key.primaryHex) != resolvedPrimary {
            persistColour(resolvedPrimary, key: SharedConfig.Key.primaryHex)
        }
        if d.string(forKey: SharedConfig.Key.accentHex) != resolvedAccent {
            persistColour(resolvedAccent, key: SharedConfig.Key.accentHex)
        }
    }

    /// Keeps a colour the user actually picked, and moves the old factory cyan/gold onto the new defaults.
    private static func replacingFactoryDefault(_ stored: String?, previous: [String], fallback: String) -> String {
        guard let stored else { return fallback }
        return previous.contains(stored.uppercased()) ? fallback : stored
    }

    private func persistColour(_ hex: String, key: String) {
        d.set(hex, forKey: key)
        SharedConfig.defaults.set(hex, forKey: key)
        WidgetCenter.shared.reloadTimelines(ofKind: SharedConfig.standByWidgetKind)
    }

    func resetColours() {
        primaryHex = Theme.defaultPrimaryHex
        accentHex = Theme.defaultAccentHex
    }

    func resolvedEndpoint() throws -> LLMEndpoint {
        switch provider {
        case .openAI:
            guard let key = KeychainStore.get(.openAI) else { throw LLMError.missingKey("OpenAI") }
            let model = openAIModel.trimmingCharacters(in: .whitespaces)
            return LLMEndpoint(url: URL(string: "https://api.openai.com/v1/chat/completions")!,
                               apiKey: key, model: model.isEmpty ? "gpt-4o-mini" : model)
        case .custom:
            var base = customBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
            while base.hasSuffix("/") { base.removeLast() }
            if !base.hasSuffix("/chat/completions") { base += "/chat/completions" }
            guard let url = URL(string: base), url.scheme?.hasPrefix("http") == true else { throw LLMError.badURL }
            return LLMEndpoint(url: url, apiKey: KeychainStore.get(.customAgent), model: customModel)
        }
    }

    func systemPrompt(facts: [MemoryFact]) -> String {
        var parts = [personality]
        if !instructions.isEmpty { parts.append("Instructions:\n" + instructions) }
        if !facts.isEmpty {
            parts.append("Things you know about the user:\n" + facts.map { "- \($0.text)" }.joined(separator: "\n"))
        }
        if autoRemember {
            parts.append("If the user tells you a lasting personal fact or preference worth remembering, add a separate final line "
                         + "in the exact form `REMEMBER: <fact>`. That line is hidden from the user and not spoken.")
        }
        parts.append("""
        You can use tools to act on the iPhone. Rules:
        - Anything that calls, messages or sends is confirmed by the user in the app; just call the tool, don't ask twice.
        - You cannot read the user's messages in iMessage, WhatsApp, Snapchat or Instagram. Say so if asked.
        - Look up IDs with the list tools before updating or deleting.
        - Use local times in ISO 8601 without an offset (e.g. 2026-10-15T14:30).
        """)
        let date = Date.now.formatted(date: .complete, time: .shortened)
        parts.append("Current date and time (UK): \(date).")
        return parts.joined(separator: "\n\n")
    }
}
