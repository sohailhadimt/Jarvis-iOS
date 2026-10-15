import AVFoundation
import SwiftUI

struct APIKeysSettingsView: View {
    @Environment(AppSettings.self) private var settings
    @State private var openAIKey = ""
    @State private var geminiKey = ""
    @State private var groqKey = ""
    @State private var elevenKey = ""
    @State private var customKey = ""
    @State private var savedMessage: String?

    var body: some View {
        @Bindable var settings = settings
        Form {
            Section {
                Picker("AI Provider", selection: $settings.provider) {
                    ForEach(LLMProvider.allCases) { Text($0.title).tag($0) }
                }
            } footer: {
                Text("Gemini and Groq are free. If the selected provider has no key, JARVIS uses another saved key (Gemini, then Groq, then OpenAI).")
            }

            Section {
                SecureField("sk-…", text: $openAIKey)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                modelField($settings.openAIModel, presets: AppSettings.modelSuggestions)
            } header: {
                Text("OpenAI")
            } footer: {
                Text("Create a key at platform.openai.com > API keys. Default model: gpt-4o-mini.")
            }

            Section {
                SecureField("Gemini API key", text: $geminiKey)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                modelField($settings.geminiModel, presets: AppSettings.geminiModelSuggestions)
                Link("aistudio.google.com/apikey", destination: URL(string: "https://aistudio.google.com/apikey")!)
            } header: {
                Text("Gemini")
            } footer: {
                Text("Free key. Default model: gemini-2.5-flash. JARVIS calls Google's OpenAI-compatible chat endpoint with Authorization: Bearer.")
            }

            Section {
                SecureField("Groq API key", text: $groqKey)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                modelField($settings.groqModel, presets: AppSettings.groqModelSuggestions)
                Link("console.groq.com/keys", destination: URL(string: "https://console.groq.com/keys")!)
            } header: {
                Text("Groq")
            } footer: {
                Text("Free key. Default model: llama-3.3-70b-versatile. A saved Groq key also transcribes speech with Whisper. Without a Groq key, JARVIS uses on-device Apple Speech.")
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
                TextField("Base URL, e.g. https://example.com/v1", text: $settings.customBaseURL)
                    .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                SecureField("Bearer key (optional)", text: $customKey)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                TextField("Model name", text: $settings.customModel)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
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
        }
    }

    private func modelField(_ text: Binding<String>, presets: [String]) -> some View {
        HStack {
            TextField("Model", text: text)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
            Menu("Presets") {
                ForEach(presets, id: \.self) { model in
                    Button(model) { text.wrappedValue = model }
                }
            }
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
        .navigationTitle("Voices")
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
                OrbView(level: 0, phase: .idle, primary: settings.primaryColor, accent: settings.accentColor)
                    .frame(height: 200)
                    .listRowBackground(Color.black)
            }
            Section("Colours") {
                ColorPicker("Primary (orb glow)", selection: Binding(
                    get: { settings.primaryColor },
                    set: { settings.primaryHex = $0.hexString }))
                ColorPicker("Accent", selection: Binding(
                    get: { settings.accentColor },
                    set: { settings.accentHex = $0.hexString }))
                Button("Reset to cyan") { settings.resetColours() }
            }
            Section {
                Toggle("Auto StandBy view when charging in landscape", isOn: $settings.autoStandBy)
            }
        }
        .navigationTitle("Appearance")
        .toolbar(.visible, for: .navigationBar)
    }
}
