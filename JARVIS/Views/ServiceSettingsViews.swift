import AVFoundation
import SwiftUI

/// Picker, key and model for the selected provider. Always visible: nothing here is behind a condition that hides the picker.
struct AIProviderSection: View {
    @Environment(AppSettings.self) private var settings
    @State private var openAIKey = ""
    @State private var geminiKey = ""
    @State private var groqKey = ""
    @State private var customKey = ""
    @State private var savedMessage: String?

    var body: some View {
        @Bindable var settings = settings
        Section {
            Picker("AI Provider", selection: $settings.provider) {
                ForEach(LLMProvider.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            keyField
            Text(modelCaption)
                .font(.caption)
                .foregroundStyle(.secondary)
            providerModelField(modelBinding, presets: presets)
            if settings.provider == .custom {
                TextField("Base URL, e.g. https://example.com/v1", text: $settings.customBaseURL)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }
            if let keyURL {
                Link(keyURL.label, destination: keyURL.url)
            }
            Button("Save key") { saveSelectedKey() }
            if let savedMessage {
                Text(savedMessage).font(.footnote).foregroundStyle(.green)
            }
        } header: {
            Text("AI Provider")
        } footer: {
            Text(help)
        }
        .onAppear(perform: loadKeys)
    }

    @ViewBuilder
    private var keyField: some View {
        switch settings.provider {
        case .openAI:
            SecureField("OpenAI API key", text: $openAIKey)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
        case .gemini:
            SecureField("Gemini API key", text: $geminiKey)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
        case .groq:
            SecureField("Groq API key", text: $groqKey)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
        case .custom:
            SecureField("Bearer key (optional)", text: $customKey)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
        }
    }

    private var modelBinding: Binding<String> {
        Binding(
            get: {
                switch settings.provider {
                case .openAI: settings.openAIModel
                case .gemini: settings.geminiModel
                case .groq: settings.groqModel
                case .custom: settings.customModel
                }
            },
            set: { newValue in
                switch settings.provider {
                case .openAI: settings.openAIModel = newValue
                case .gemini: settings.geminiModel = newValue
                case .groq: settings.groqModel = newValue
                case .custom: settings.customModel = newValue
                }
            }
        )
    }

    private var modelCaption: String {
        switch settings.provider {
        case .openAI: "OpenAI model"
        case .gemini: "Gemini model"
        case .groq: "Groq model"
        case .custom: "Custom model"
        }
    }

    private var presets: [String] {
        switch settings.provider {
        case .openAI: AppSettings.modelSuggestions
        case .gemini: AppSettings.geminiModelSuggestions
        case .groq: AppSettings.groqModelSuggestions
        case .custom: []
        }
    }

    private var keyURL: (label: String, url: URL)? {
        switch settings.provider {
        case .gemini: ("aistudio.google.com/apikey", URL(string: "https://aistudio.google.com/apikey")!)
        case .groq: ("console.groq.com/keys", URL(string: "https://console.groq.com/keys")!)
        case .openAI: ("platform.openai.com/api-keys", URL(string: "https://platform.openai.com/api-keys")!)
        case .custom: nil
        }
    }

    private var help: String {
        switch settings.provider {
        case .gemini:
            "Gemini is the default provider. Free key. Default model gemini-3.8-flash. If Gemini is overloaded, JARVIS retries, then tries another free Gemini model, then Groq when that key is saved. If this key is missing, JARVIS uses another saved key."
        case .groq:
            "Free key. Default model llama-3.3-70b-versatile. A saved Groq key also transcribes speech with Whisper. Without a Groq key, JARVIS uses on-device Apple Speech. If this key is missing, JARVIS uses another saved key."
        case .openAI:
            "Default chat model gpt-4o-mini. OpenAI can also search the web; that search model is in Task agent routing. If this key is missing, JARVIS uses Gemini or another saved key."
        case .custom:
            "Any OpenAI-compatible service. JARVIS calls the base URL plus /chat/completions with Authorization: Bearer. If it is not set, JARVIS uses another saved key."
        }
    }

    private func loadKeys() {
        openAIKey = KeychainStore.get(.openAI) ?? ""
        geminiKey = KeychainStore.get(.gemini) ?? ""
        groqKey = KeychainStore.get(.groq) ?? ""
        customKey = KeychainStore.get(.customAgent) ?? ""
    }

    private func saveSelectedKey() {
        switch settings.provider {
        case .openAI: KeychainStore.set(openAIKey, for: .openAI)
        case .gemini: KeychainStore.set(geminiKey, for: .gemini)
        case .groq: KeychainStore.set(groqKey, for: .groq)
        case .custom: KeychainStore.set(customKey, for: .customAgent)
        }
        savedMessage = "Saved in the Keychain."
    }
}

func providerModelField(_ text: Binding<String>, presets: [String]) -> some View {
    HStack {
        TextField("Model", text: text)
            .textInputAutocapitalization(.never).autocorrectionDisabled()
        if !presets.isEmpty {
            Menu("Presets") {
                ForEach(presets, id: \.self) { model in
                    Button(model) { text.wrappedValue = model }
                }
            }
        }
    }
}

struct APIKeysSettingsView: View {
    @Environment(AppSettings.self) private var settings
    @State private var openAIKey = ""
    @State private var geminiKey = ""
    @State private var groqKey = ""
    @State private var elevenKey = ""
    @State private var customKey = ""
    @State private var braveKey = ""
    @State private var savedMessage: String?

    var body: some View {
        @Bindable var settings = settings
        Form {
            Section {
                Picker("AI Provider", selection: $settings.provider) {
                    ForEach(LLMProvider.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
            } footer: {
                Text("Gemini is the default. Groq is free as well. If the selected provider has no key, JARVIS uses another saved key (Gemini, then Groq, then OpenAI).")
            }

            Section {
                SecureField("Gemini API key", text: $geminiKey)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                providerModelField($settings.geminiModel, presets: AppSettings.geminiModelSuggestions)
                Link("aistudio.google.com/apikey", destination: URL(string: "https://aistudio.google.com/apikey")!)
            } header: {
                Text("Gemini")
            } footer: {
                Text("Free key. Default model: gemini-3.8-flash. If Gemini is overloaded, JARVIS retries, then tries another free Gemini model, then Groq when that key is saved.")
            }

            Section {
                SecureField("Groq API key", text: $groqKey)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                providerModelField($settings.groqModel, presets: AppSettings.groqModelSuggestions)
                Link("console.groq.com/keys", destination: URL(string: "https://console.groq.com/keys")!)
            } header: {
                Text("Groq")
            } footer: {
                Text("Free key. Default model: llama-3.3-70b-versatile. A saved Groq key also transcribes speech with Whisper. Without a Groq key, JARVIS uses on-device Apple Speech.")
            }

            Section {
                SecureField("OpenAI API key", text: $openAIKey)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                providerModelField($settings.openAIModel, presets: AppSettings.modelSuggestions)
            } header: {
                Text("OpenAI")
            } footer: {
                Text("Create a key at platform.openai.com > API keys. Default model: gpt-4o-mini. Web search uses the OpenAI search model in Integrations.")
            }

            Section {
                SecureField("ElevenLabs API key", text: $elevenKey)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
            } header: {
                Text("ElevenLabs (voice)")
            } footer: {
                Text("Optional. Without it, JARVIS uses the built-in iPhone voice.")
            }

            Section {
                SecureField("Brave Search API key", text: $braveKey)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                Link("api.search.brave.com", destination: URL(string: "https://api.search.brave.com")!)
            } header: {
                Text("Brave Search")
            } footer: {
                Text("Optional. News, weather, prices and sport use Gemini Google Search first. If that fails, JARVIS uses DuckDuckGo and Wikipedia with no key, and Brave when this key is saved.")
            }

            Section {
                TextField("Base URL, e.g. https://example.com/v1", text: $settings.customBaseURL)
                    .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                SecureField("Bearer key (optional)", text: $customKey)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                providerModelField($settings.customModel, presets: [])
            } header: {
                Text("Custom agent endpoint")
            } footer: {
                Text("Any OpenAI-compatible service. JARVIS calls <Base URL>/chat/completions with an \"Authorization: Bearer\" header.")
            }

            Section {
                Button("Save keys to Keychain") {
                    KeychainStore.set(openAIKey, for: .openAI)
                    KeychainStore.set(geminiKey, for: .gemini)
                    KeychainStore.set(groqKey, for: .groq)
                    KeychainStore.set(elevenKey, for: .elevenLabs)
                    KeychainStore.set(customKey, for: .customAgent)
                    KeychainStore.set(braveKey, for: .brave)
                    savedMessage = "Saved securely in the Keychain."
                }
                if let savedMessage { Text(savedMessage).font(.footnote).foregroundStyle(.green) }
            }
        }
        .navigationTitle("API Keys")
        .toolbar(.visible, for: .navigationBar)
        .onAppear {
            openAIKey = KeychainStore.get(.openAI) ?? ""
            geminiKey = KeychainStore.get(.gemini) ?? ""
            groqKey = KeychainStore.get(.groq) ?? ""
            elevenKey = KeychainStore.get(.elevenLabs) ?? ""
            customKey = KeychainStore.get(.customAgent) ?? ""
            braveKey = KeychainStore.get(.brave) ?? ""
        }
    }

}

struct VoicesSettingsView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(AssistantEngine.self) private var engine
    @State private var voices: [ElevenVoice] = []
    @State private var loading = false
    @State private var error: String?
    @State private var previewPlayer: AVPlayer?

    var body: some View {
        @Bindable var settings = settings
        Form {
            Section {
                Toggle("Separate full-screen mode", isOn: $settings.voiceSeparateMode)
                Toggle("Start with voice", isOn: $settings.startWithVoice)
                Toggle("Background conversations", isOn: $settings.backgroundConversations)
                Toggle("Captions on", isOn: $settings.captionsDefault)
                Picker("Language", selection: $settings.speechLocale) {
                    Text("English (UK)").tag("en-GB")
                    Text("English (US)").tag("en-US")
                    Text("English (Australia)").tag("en-AU")
                    Text("French").tag("fr-FR")
                    Text("German").tag("de-DE")
                    Text("Spanish").tag("es-ES")
                }
                VStack(alignment: .leading) {
                    Text("VAD sensitivity \(settings.vadSensitivity, format: .number.precision(.fractionLength(2)))")
                    Slider(value: $settings.vadSensitivity, in: 0...1)
                }
                Picker("Orb style", selection: $settings.orbStyle) {
                    Text("ChatGPT").tag(OrbStyle.chatGPT)
                    Text("JARVIS classic").tag(OrbStyle.classic)
                }
            } header: {
                Text("Voice mode")
            } footer: {
                Text("Full-screen voice is the default: a black screen, the sky orb, and the ask bar. Turn separate mode off for the in-chat composer. Tap the orb for the transcript. Captions are the two lines under the orb. VAD sensitivity changes how quickly silence ends your turn; higher is about 500ms and lower is about 700ms. The Action Button session is unaffected.")
            }
            Section("Selected: \(settings.voiceName)") {
                VStack(alignment: .leading) {
                    Text("Stability \(settings.stability, format: .number.precision(.fractionLength(2)))")
                    Slider(value: $settings.stability, in: 0...1)
                }
                VStack(alignment: .leading) {
                    Text("Similarity \(settings.similarity, format: .number.precision(.fractionLength(2)))")
                    Slider(value: $settings.similarity, in: 0...1)
                }
                Button("Test current voice") { Task { await engine.testVoice() } }
            }

            Section("Your ElevenLabs voices") {
                if loading { ProgressView() }
                if let error { Text(error).foregroundStyle(.orange).font(.footnote) }
                ForEach(voices) { voice in
                    HStack {
                        Button {
                            settings.voiceID = voice.voiceID
                            settings.voiceName = voice.name
                        } label: {
                            VStack(alignment: .leading) {
                                Text(voice.name)
                                if let c = voice.category { Text(c).font(.caption).foregroundStyle(.secondary) }
                            }
                        }
                        .buttonStyle(.plain)
                        Spacer()
                        if settings.voiceID == voice.voiceID {
                            Image(systemName: "checkmark").foregroundStyle(settings.accentColor)
                        }
                        if let s = voice.previewURL, let url = URL(string: s) {
                            Button {
                                previewPlayer = AVPlayer(url: url)
                                previewPlayer?.play()
                            } label: { Image(systemName: "play.circle") }
                            .buttonStyle(.borderless)
                        }
                    }
                }
            }
        }
        .navigationTitle("Voice")
        .toolbar(.visible, for: .navigationBar)
        .refreshable { await load() }
        .task { await load() }
    }

    private func load() async {
        guard let key = KeychainStore.get(.elevenLabs) else {
            error = "Add your ElevenLabs API key in Settings > API Keys to list your voices."
            return
        }
        loading = true
        defer { loading = false }
        do {
            voices = try await ElevenLabsClient.voices(apiKey: key)
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }
}

struct AppearanceSettingsView: View {
    @Environment(AppSettings.self) private var settings

    var body: some View {
        @Bindable var settings = settings
        Form {
            Section {
                SkyCloudOrbView(level: 0.2, state: .listening, tint: settings.orbTintColor, tintAmount: settings.orbTintAmount, crispEdge: true)
                    .frame(width: 180, height: 180)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .listRowBackground(Color.black)
            } header: {
                Text("Preview")
            }
            Section("Presets") {
                ForEach(AppearancePreset.allCases.filter { $0 != .custom }) { preset in
                    Button {
                        settings.apply(preset: preset)
                    } label: {
                        HStack {
                            Circle().fill(Color(hex: preset.tintHex)).frame(width: 18, height: 18)
                            Text(preset.title)
                            Spacer()
                            if settings.appearancePreset == preset.rawValue {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            Section("Colour wheel") {
                ColorPicker("Orb and accent", selection: Binding(
                    get: { settings.orbTintColor },
                    set: { settings.applyCustomTint($0) }), supportsOpacity: false)
                Text("The sky shifts toward this colour. The clouds stay white. The same colour is saved for the widget and Live Activity.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Button("Reset to ChatGPT Sky") { settings.resetColours() }
            }
            Section {
                Toggle("Auto StandBy view when charging in landscape", isOn: $settings.autoStandBy)
            }
        }
        .navigationTitle("Appearance")
        .toolbar(.visible, for: .navigationBar)
    }
}
