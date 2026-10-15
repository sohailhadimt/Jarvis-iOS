import Foundation
import Observation
import SwiftUI
import WidgetKit

enum LLMProvider: String, CaseIterable, Identifiable, Sendable {
    case openAI, gemini, groq, custom
    var id: String { rawValue }
    var title: String {
        switch self {
        case .openAI: "OpenAI"
        case .gemini: "Gemini"
        case .groq: "Groq"
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
    static let defaultGeminiModel = "gemini-3.8-flash"
    static let retiredGeminiModel = "gemini-2.5-flash"
    static let defaultGroqModel = "llama-3.3-70b-versatile"
    static let geminiModelSuggestions = ["gemini-3.8-flash", "gemini-2.5-pro", "gemini-2.0-flash"]
    static let groqModelSuggestions = ["llama-3.3-70b-versatile", "llama-3.1-8b-instant"]

    private static let openAIURL = URL(string: "https://api.openai.com/v1/chat/completions")!
    private static let geminiURL = URL(string: "https://generativelanguage.googleapis.com/v1beta/openai/chat/completions")!
    private static let groqURL = URL(string: "https://api.groq.com/openai/v1/chat/completions")!

    @ObservationIgnored private let d = UserDefaults.standard

    var personality: String { didSet { d.set(personality, forKey: "personality") } }
    var instructions: String { didSet { d.set(instructions, forKey: "instructions") } }
    var autoRemember: Bool { didSet { d.set(autoRemember, forKey: "autoRemember") } }
    var provider: LLMProvider { didSet { d.set(provider.rawValue, forKey: "provider") } }
    var openAIModel: String { didSet { d.set(openAIModel, forKey: "openAIModel") } }
    var geminiModel: String { didSet { d.set(geminiModel, forKey: "geminiModel") } }
    var groqModel: String { didSet { d.set(groqModel, forKey: "groqModel") } }
    var customBaseURL: String { didSet { d.set(customBaseURL, forKey: "customBaseURL") } }
    var customModel: String { didSet { d.set(customModel, forKey: "customModel") } }
    var voiceID: String { didSet { d.set(voiceID, forKey: "voiceID") } }
    var voiceName: String { didSet { d.set(voiceName, forKey: "voiceName") } }
    var stability: Double { didSet { d.set(stability, forKey: "stability") } }
    var similarity: Double { didSet { d.set(similarity, forKey: "similarity") } }
    var autoStandBy: Bool { didSet { d.set(autoStandBy, forKey: "autoStandBy") } }
    /// Listens for "Jarvis" only while the app is open and on screen.
    var wakeWordEnabled: Bool { didSet { d.set(wakeWordEnabled, forKey: "wakeWordEnabled") } }
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
    var cloudBaseURL: String { didSet { d.set(cloudBaseURL, forKey: "cloudBaseURL") } }
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
        let storedGemini = d.string(forKey: "geminiModel")
        if storedGemini?.trimmingCharacters(in: .whitespacesAndNewlines) == Self.retiredGeminiModel {
            geminiModel = Self.defaultGeminiModel
            // didSet does not run during init, so write the migrated model through explicitly.
            d.set(Self.defaultGeminiModel, forKey: "geminiModel")
        } else {
            geminiModel = storedGemini ?? Self.defaultGeminiModel
        }
        groqModel = d.string(forKey: "groqModel") ?? Self.defaultGroqModel
        customBaseURL = d.string(forKey: "customBaseURL") ?? ""
        customModel = d.string(forKey: "customModel") ?? ""
        voiceID = d.string(forKey: "voiceID") ?? ElevenLabsClient.defaultVoiceID
        voiceName = d.string(forKey: "voiceName") ?? "George"
        stability = d.object(forKey: "stability") as? Double ?? 0.5
        similarity = d.object(forKey: "similarity") as? Double ?? 0.75
        autoStandBy = d.object(forKey: "autoStandBy") as? Bool ?? true
        wakeWordEnabled = d.object(forKey: "wakeWordEnabled") as? Bool ?? true
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
        cloudBaseURL = d.string(forKey: "cloudBaseURL") ?? ""
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

    /// The selected provider when its key is saved. If that key is missing, another saved provider is used.
    func resolvedEndpoint() throws -> LLMEndpoint {
        if let endpoint = try configuredEndpoint(for: provider, strict: true) {
            return endpoint
        }
        for candidate in fallbacks(after: provider) {
            if let endpoint = try configuredEndpoint(for: candidate, strict: false) {
                return endpoint
            }
        }
        throw LLMError.missingKey(provider.title)
    }

    private func fallbacks(after selected: LLMProvider) -> [LLMProvider] {
        switch selected {
        case .openAI: [.gemini, .groq, .custom]
        case .gemini: [.groq, .openAI, .custom]
        case .groq: [.gemini, .openAI, .custom]
        case .custom: [.gemini, .groq, .openAI]
        }
    }

    private func configuredEndpoint(for provider: LLMProvider, strict: Bool) throws -> LLMEndpoint? {
        switch provider {
        case .openAI:
            guard let key = KeychainStore.get(.openAI) else { return nil }
            return LLMEndpoint(url: Self.openAIURL, apiKey: key,
                               model: Self.cleaned(openAIModel, fallback: "gpt-4o-mini"),
                               providerName: "OpenAI", kind: .openAI)
        case .gemini:
            guard let key = KeychainStore.get(.gemini) else { return nil }
            return LLMEndpoint(url: Self.geminiURL, apiKey: key,
                               model: Self.cleaned(geminiModel, fallback: Self.defaultGeminiModel),
                               providerName: "Gemini", kind: .gemini)
        case .groq:
            guard let key = KeychainStore.get(.groq) else { return nil }
            return LLMEndpoint(url: Self.groqURL, apiKey: key,
                               model: Self.cleaned(groqModel, fallback: Self.defaultGroqModel),
                               providerName: "Groq", kind: .groq)
        case .custom:
            return try customEndpoint(strict: strict)
        }
    }

    private func customEndpoint(strict: Bool) throws -> LLMEndpoint? {
        var base = customBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if base.isEmpty {
            if strict { throw LLMError.badURL }
            return nil
        }
        while base.hasSuffix("/") { base.removeLast() }
        if !base.hasSuffix("/chat/completions") { base += "/chat/completions" }
        guard let url = URL(string: base), url.scheme == "http" || url.scheme == "https" else {
            if strict { throw LLMError.badURL }
            return nil
        }
        let model = customModel.trimmingCharacters(in: .whitespacesAndNewlines)
        return LLMEndpoint(url: url, apiKey: KeychainStore.get(.customAgent), model: model,
                           providerName: "Custom agent", kind: .custom)
    }

    private static func cleaned(_ raw: String, fallback: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? fallback : trimmed
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
        if JarvisCloud.isConfigured {
            parts.append("""
            JARVIS Cloud is connected. Use the cloud tools for tasks, the briefing, approvals, cloud memory and the sales pipeline.
            Never invent tasks, numbers, companies, findings or approvals. If a tool result is empty, say nothing is stored.
            Speak a briefing as two parts: facts first, then recommendations. A recommendation is not an extra fact. Use only the tool result.
            Approving or rejecting waits for the user to say yes. Call approve_approval or reject_approval and let the app ask. Nothing is emailed, published or paid.
            create_cloud_task schedule is an optional 5-field UTC cron. Omit it to run once.
            """)
            if CloudMonitor.shared.lastRefresh != nil {
                let lines = CloudMonitor.shared.memory.prefix(12).map { "- \($0.content)" }
                if !lines.isEmpty {
                    parts.append("Cloud memory already stored:\n" + lines.joined(separator: "\n"))
                }
            }
        } else {
            parts.append("JARVIS Cloud is not configured. If the user asks about cloud tasks, the briefing, the pipeline or cloud memory, say the backend URL and app token are not set in Settings, JARVIS Cloud. Do not invent that data.")
        }
        let date = Date.now.formatted(date: .complete, time: .shortened)
        parts.append("Current date and time (UK): \(date).")
        return parts.joined(separator: "\n\n")
    }
}
