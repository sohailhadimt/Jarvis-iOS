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
                1. Open the iPhone Settings app > Action Button.
                2. Swipe to "Shortcut", tap "Choose a Shortcut".
                3. Pick JARVIS > "Talk to JARVIS".
                That opens JARVIS and starts listening. "Toggle JARVIS" starts or ends a session from the Lock Screen.
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
