import Foundation
import Observation
import SwiftUI
import WidgetKit

enum LLMProvider: String, CaseIterable, Identifiable, Sendable {
    case gemini, openAI, groq, custom
    var id: String { rawValue }
    var title: String {
        switch self {
        case .openAI: "OpenAI"
        case .gemini: "Gemini"
        case .groq: "Groq"
        case .custom: "Custom"
        }
    }
}

enum AppearancePreset: String, CaseIterable, Identifiable, Sendable {
    case sky, cyan, red, gold, purple, custom
    var id: String { rawValue }
    var title: String {
        switch self {
        case .sky: "ChatGPT Sky"
        case .cyan: "JARVIS Cyan"
        case .red: "Red"
        case .gold: "Gold"
        case .purple: "Purple"
        case .custom: "Custom"
        }
    }
    var tintHex: String {
        switch self {
        case .sky: "4BA8EEFF"
        case .cyan: "00E5F2FF"
        case .red: "FF3B30FF"
        case .gold: "D4AF37FF"
        case .purple: "AF52DEFF"
        case .custom: "4BA8EEFF"
        }
    }
    /// 0 leaves the sky palette alone. Any other preset shifts the sky toward the colour and leaves clouds white.
    var tintAmount: Double {
        self == .sky ? 0 : 1
    }
}

enum OrbStyle: String, CaseIterable, Identifiable, Sendable {
    case chatGPT, classic
    var id: String { rawValue }
    var title: String {
        switch self {
        case .chatGPT: "ChatGPT"
        case .classic: "JARVIS classic"
        }
    }
}

enum TaskRouting: String, CaseIterable, Identifiable {
    case split, auto, chatOnly
    var id: String { rawValue }
    var title: String {
        switch self {
        case .split: "Questions → chat, actions → tools"
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
    /// Fastest free models for spoken chit-chat. Tool turns keep the selected model.
    static let fastGeminiModel = "gemini-3.5-flash-lite"
    static let fastGroqModel = "llama-3.1-8b-instant"
    /// Free models that are still served. gemini-2.0-flash and gemini-2.0-flash-lite shut down on 1 June 2026.
    static let geminiModelSuggestions = [
        "gemini-3.8-flash",
        "gemini-3.5-flash-lite",
        "gemini-3.1-flash-lite",
        "gemini-2.5-flash-lite",
    ]
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
    /// ChatGPT cloud is the default. JARVIS classic keeps the Metal geodesic orb.
    var orbStyle: OrbStyle { didSet { d.set(orbStyle.rawValue, forKey: "orbStyle") } }
    /// On (the default) is the full-screen sky voice screen. Off uses the in-chat composer.
    var voiceSeparateMode: Bool { didSet { d.set(voiceSeparateMode, forKey: "voiceSeparateMode") } }
    var startWithVoice: Bool { didSet { d.set(startWithVoice, forKey: "startWithVoice") } }
    /// When on, an in-app voice session keeps listening after the app leaves the screen.
    var backgroundConversations: Bool { didSet { d.set(backgroundConversations, forKey: "backgroundConversations") } }
    /// BCP-47 locale for on-device speech recognition.
    var speechLocale: String { didSet { d.set(speechLocale, forKey: "speechLocale") } }
    /// Full-screen captions start on when a voice session opens.
    var captionsDefault: Bool { didSet { d.set(captionsDefault, forKey: "captionsDefault") } }
    /// 0 waits about 700ms of silence. 1 ends a turn after about 500ms.
    var vadSensitivity: Double { didSet { d.set(vadSensitivity, forKey: "vadSensitivity") } }
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
    /// Chosen wheel colour. Amount 0 keeps the ChatGPT sky palette; 1 shifts the sky hue toward it.
    var orbTintHex: String { didSet { persistTint() } }
    var orbTintAmount: Double { didSet { persistTint() } }
    var appearancePreset: String { didSet { d.set(appearancePreset, forKey: "appearancePreset") } }

    var primaryColor: Color { Color(hex: primaryHex) }
    var accentColor: Color { Color(hex: accentHex) }
    var orbTintColor: Color { Color(hex: orbTintHex) }

    private init() {
        let d = UserDefaults.standard
        personality = d.string(forKey: "personality") ?? PersonalityPreset.jarvis.prompt
        instructions = d.string(forKey: "instructions")
            ?? "Your replies are spoken aloud, so keep them short and conversational. Never use markdown, lists or emojis."
        autoRemember = d.object(forKey: "autoRemember") as? Bool ?? true
        let storedProvider = d.string(forKey: "provider")
        var resolvedProvider = LLMProvider(rawValue: storedProvider ?? "") ?? .gemini
        // Fresh installs have no provider. An old default of OpenAI with no saved key moves to Gemini.
        if resolvedProvider == .openAI, KeychainStore.get(.openAI) == nil {
            resolvedProvider = .gemini
        }
        provider = resolvedProvider
        // didSet does not run during init, so persist the migration explicitly.
        if storedProvider != resolvedProvider.rawValue {
            d.set(resolvedProvider.rawValue, forKey: "provider")
        }
        openAIModel = d.string(forKey: "openAIModel") ?? "gpt-4o-mini"
        let storedGemini = d.string(forKey: "geminiModel")
        if Self.isRetiredGemini(storedGemini) {
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
        orbStyle = OrbStyle(rawValue: d.string(forKey: "orbStyle") ?? "") ?? .chatGPT
        if d.object(forKey: "fullScreenVoiceDefault") == nil {
            voiceSeparateMode = true
            d.set(true, forKey: "voiceSeparateMode")
            d.set(true, forKey: "fullScreenVoiceDefault")
        } else {
            voiceSeparateMode = d.object(forKey: "voiceSeparateMode") as? Bool ?? true
        }
        startWithVoice = d.object(forKey: "startWithVoice") as? Bool ?? false
        backgroundConversations = d.object(forKey: "backgroundConversations") as? Bool ?? false
        speechLocale = d.string(forKey: "speechLocale") ?? "en-GB"
        captionsDefault = d.object(forKey: "captionsDefault") as? Bool ?? true
        vadSensitivity = d.object(forKey: "vadSensitivity") as? Double ?? 0.5
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
        orbTintHex = d.string(forKey: "orbTintHex") ?? "4BA8EEFF"
        orbTintAmount = d.object(forKey: "orbTintAmount") as? Double ?? 0
        appearancePreset = d.string(forKey: "appearancePreset") ?? AppearancePreset.sky.rawValue
        SharedConfig.defaults.set(orbTintHex, forKey: SharedConfig.Key.orbTintHex)
        SharedConfig.defaults.set(orbTintAmount, forKey: SharedConfig.Key.orbTintAmount)
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
        apply(preset: .sky)
    }

    func apply(preset: AppearancePreset) {
        appearancePreset = preset.rawValue
        orbTintHex = preset.tintHex
        orbTintAmount = preset.tintAmount
        primaryHex = preset.tintHex
        accentHex = preset.tintHex
    }

    func applyCustomTint(_ color: Color) {
        appearancePreset = AppearancePreset.custom.rawValue
        let hex = color.hexString
        orbTintHex = hex
        orbTintAmount = 1
        primaryHex = hex
        accentHex = hex
    }

    /// gemini-2.5-flash was replaced in-app. Every gemini-2.0 id was shut down by Google.
    private static func isRetiredGemini(_ stored: String?) -> Bool {
        guard let stored else { return false }
        let name = stored.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if name == retiredGeminiModel { return true }
        if name.hasPrefix("gemini-2.0") { return true }
        return false
    }

    /// Agents and tools ask Gemini directly. The main voice still falls back when that key is missing.
    func geminiEndpoint() throws -> LLMEndpoint {
        if let endpoint = try configuredEndpoint(for: .gemini, strict: true) {
            return endpoint
        }
        throw LLMError.missingKey("Gemini")
    }

    private func persistTint() {
        d.set(orbTintHex, forKey: "orbTintHex")
        d.set(orbTintAmount, forKey: "orbTintAmount")
        SharedConfig.defaults.set(orbTintHex, forKey: SharedConfig.Key.orbTintHex)
        SharedConfig.defaults.set(orbTintAmount, forKey: SharedConfig.Key.orbTintAmount)
        WidgetCenter.shared.reloadTimelines(ofKind: SharedConfig.standByWidgetKind)
    }

    /// Spoken turns use flash-lite or Llama 3.1 8B. The selected model is left as-is for tools.
    func conversationalEndpoint(from endpoint: LLMEndpoint) -> LLMEndpoint {
        switch endpoint.kind {
        case .gemini:
            return LLMEndpoint(url: endpoint.url, apiKey: endpoint.apiKey, model: Self.fastGeminiModel,
                               providerName: endpoint.providerName, kind: .gemini)
        case .groq:
            return LLMEndpoint(url: endpoint.url, apiKey: endpoint.apiKey, model: Self.fastGroqModel,
                               providerName: endpoint.providerName, kind: .groq)
        case .openAI, .custom:
            return endpoint
        }
    }

    /// Groq's fast model, when a key is saved. Used after a conversational Gemini failure.
    func fastGroqEndpoint() -> LLMEndpoint? {
        guard let base = groqEndpoint() else { return nil }
        return LLMEndpoint(url: base.url, apiKey: base.apiKey, model: Self.fastGroqModel,
                           providerName: base.providerName, kind: .groq)
    }

    /// Nil when no Groq key is saved. Used only after Gemini is overloaded.
    func groqEndpoint() -> LLMEndpoint? {
        let found: LLMEndpoint?
        do {
            found = try configuredEndpoint(for: .groq, strict: false)
        } catch {
            found = nil
        }
        return found
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

    /// Short prompt for spoken chit-chat. Tool turns keep `systemPrompt`.
    func voicePrompt(facts: [MemoryFact]) -> String {
        var parts: [String] = [spokenPersona(), "Spoken reply only: one or two short sentences. No markdown, lists, or emojis."]
        let kept = Array(facts.prefix(3))
        if !kept.isEmpty {
            let joined = kept.map(\.text).joined(separator: "; ")
            parts.append("Known: \(joined)")
        }
        if autoRemember {
            parts.append("If they share a lasting fact, end with a separate line REMEMBER: <fact>. Do not speak that line.")
        }
        return parts.joined(separator: " ")
    }

    private func spokenPersona() -> String {
        if personality == PersonalityPreset.jarvis.prompt {
            return "You are J.A.R.V.I.S., a brief British butler. Address Sohail as sir occasionally."
        }
        if personality == PersonalityPreset.concise.prompt {
            return "You are a precise voice assistant."
        }
        if personality == PersonalityPreset.friendly.prompt {
            return "You are a warm voice assistant for Sohail."
        }
        return String(personality.prefix(240))
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
        - A phone call to one matching contact is placed immediately. Messages and anything that sends still wait for confirmation in the app; call the tool, don't ask twice.
        - You cannot read the user's messages in iMessage, WhatsApp, Snapchat or Instagram. Say so if asked.
        - Look up IDs with the list tools before updating or deleting.
        - Use local times in ISO 8601 without an offset (e.g. 2026-10-15T14:30).
        """)
        if JarvisCloud.isConfigured {
            parts.append("""
            JARVIS Cloud is connected. Use the cloud tools for tasks, the briefing, approvals, cloud memory and the sales pipeline.
            Never invent tasks, numbers, companies, findings or approvals. If a tool result is empty, say nothing is stored.
            Speak a briefing as two parts: facts first, then recommendations. A recommendation is not an extra fact. Use only the tool result.
            Approving or rejecting shows a card in the app. Call approve_approval or reject_approval and stop. The user taps the card. Do not ask them to say yes. Nothing is emailed, published or paid.
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
