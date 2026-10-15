import SwiftUI

struct SettingsView: View {
    @Environment(AppSettings.self) private var settings

    var body: some View {
        Form {
            Section("Assistant") {
                NavigationLink { PersonalitySettingsView() } label: { Label("Personality", systemImage: "person.wave.2") }
                NavigationLink { InstructionsSettingsView() } label: { Label("Instructions", systemImage: "text.alignleft") }
                NavigationLink { MemorySettingsView() } label: { Label("Memory", systemImage: "brain") }
            }
            Section("Voice & services") {
                NavigationLink { VoicesSettingsView() } label: { Label("Voices", systemImage: "speaker.wave.3") }
                NavigationLink { IntegrationsSettingsView() } label: { Label("Integrations & Task agent", systemImage: "square.grid.3x3") }
                NavigationLink { APIKeysSettingsView() } label: { Label("API Keys & Provider", systemImage: "key") }
            }
            Section("Look") {
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
