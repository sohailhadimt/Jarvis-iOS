import SwiftUI

struct SettingsView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(AssistantEngine.self) private var engine
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        @Bindable var settings = settings
        Form {
            AIProviderSection()
            Section("Assistant") {
                NavigationLink { PersonalitySettingsView() } label: { Label("Personality", systemImage: "person.wave.2") }
                NavigationLink { InstructionsSettingsView() } label: { Label("Instructions", systemImage: "text.alignleft") }
                NavigationLink { MemorySettingsView() } label: { Label("Memory", systemImage: "brain") }
            }
            Section("Voice & services") {
                NavigationLink { VoicesSettingsView() } label: { Label("Voice", systemImage: "waveform") }
                NavigationLink { VoiceIDSettingsView() } label: { Label("Voice ID", systemImage: "mic.badge.plus") }
                NavigationLink { IntegrationsSettingsView() } label: { Label("Integrations & Task agent", systemImage: "square.grid.3x3") }
                NavigationLink { APIKeysSettingsView() } label: { Label("API Keys & Provider", systemImage: "key") }
                NavigationLink { CloudSettingsView() } label: { Label("JARVIS Cloud", systemImage: "cloud") }
                NavigationLink { CallingSettingsView() } label: { Label("Calling", systemImage: "phone") }
            }
            Section {
                Toggle("Wake word", isOn: $settings.wakeWordEnabled)
            } header: {
                Text("Wake word")
            } footer: {
                Text("While JARVIS is open and on screen, it listens for “Jarvis” and starts a conversation. It does not listen in the background.")
            }
            .onChange(of: settings.wakeWordEnabled) { _, _ in
                engine.setForeground(scenePhase == .active)
            }
            Section("Look") {
                Picker("Orb style", selection: $settings.orbStyle) {
                    ForEach(OrbStyle.allCases) { Text($0.title).tag($0) }
                }
                NavigationLink { AppearanceSettingsView() } label: { Label("Appearance", systemImage: "paintpalette") }
            }
            Section {
                Text("""
                Action Button > Controls > search JARVIS.
                1. Open the iPhone Settings app > Action Button.
                2. Swipe to Controls.
                3. Tap the control and search JARVIS.
                Pressing it starts JARVIS in the Dynamic Island without opening the app. Press again to end it.
                Start a session in the app once and allow Microphone and Speech Recognition. iOS can only show those prompts while JARVIS is on screen.
                Talk to JARVIS is still under Shortcut > Choose a Shortcut > JARVIS. That shortcut opens the app and starts listening.
                """)
                .font(.footnote)
            } header: {
                Text("Action Button")
            }
        }
        .navigationTitle("Settings")
        .toolbar(.visible, for: .navigationBar)
    }
}
