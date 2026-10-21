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
                NavigationLink { IntegrationsSettingsView() } label: { Label("Apps", systemImage: "square.grid.3x3") }
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
                Toggle("Live Activity", isOn: $settings.liveActivityEnabled)
            } header: {
                Text("Always available")
            } footer: {
                Text("Say “Hey Siri, JARVIS” or “Talk to JARVIS” to open listening. The Action Button control Talk to JARVIS does the same, and so does a Lock Screen widget tap. The Live Activity shows listening, thinking, responding, and an active call. Turn it off to hide that. Tasks keep running on the Cloudflare Worker, not on this iPhone.")
            }
            .onChange(of: settings.liveActivityEnabled) { _, _ in
                engine.applyLiveActivityPreference()
            }
            Section {
                Text("""
                Action Button > Controls > search Talk to JARVIS.
                1. Open the iPhone Settings app > Action Button.
                2. Swipe to Controls.
                3. Tap the control and search Talk to JARVIS.
                Pressing it opens JARVIS and starts listening. The same phrase works with Hey Siri.
                The JARVIS toggle still starts a session in the Dynamic Island without opening the app. Press it again to end that session.
                Start a session in the app once and allow Microphone and Speech Recognition. iOS can only show those prompts while JARVIS is on screen.
                """)
                .font(.footnote)
            } header: {
                Text("Action Button")
            }
            Section {
                Toggle("Lock with Face ID", isOn: $settings.privacyLock)
                Toggle("Start-up sequence", isOn: $settings.startupSequence)
                if settings.startupSequence {
                    Toggle("Short version", isOn: $settings.startupShort)
                }
                Toggle("Startup chime", isOn: $settings.bootChime)
                Toggle("Haptics", isOn: $settings.hapticsEnabled)
                Toggle("Weather and agenda", isOn: $settings.glanceEnabled)
                Toggle("Daily briefing", isOn: $settings.briefingEnabled)
                if settings.briefingEnabled {
                    Stepper(value: $settings.briefingHour, in: 0...23) {
                        Text("Hour \(settings.briefingHour), London")
                    }
                    Stepper(value: $settings.briefingMinute, in: 0...59) {
                        Text(String(format: "Minute %02d", settings.briefingMinute))
                    }
                }
                Button("Show the first-run setup again") {
                    settings.onboarded = false
                }
            } header: {
                Text("This iPhone")
            } footer: {
                Text("The start-up sequence plays when JARVIS opens, and again after it has been in the background for more than five minutes. Tap anywhere to skip. Short version keeps the same phases in about three seconds. Reduce Motion uses a fade. Startup chime keeps the sequence sounds. Spoken lines follow the silent switch. Face ID uses your passcode if Face ID is unavailable. The briefing reminder is on this iPhone. The worker's own routine stays in Agents and starts off.")
            }
            .onChange(of: settings.briefingEnabled) { _, _ in BriefingClock.schedule() }
            .onChange(of: settings.briefingHour) { _, _ in BriefingClock.schedule() }
            .onChange(of: settings.briefingMinute) { _, _ in BriefingClock.schedule() }
            Section("More") {
                NavigationLink { CloudBriefingView() } label: { Label("Briefing", systemImage: "sun.horizon") }
                NavigationLink { CloudActivityView() } label: { Label("Activity", systemImage: "list.bullet.rectangle") }
                NavigationLink { CloudBusinessView() } label: { Label("Business", systemImage: "chart.bar") }
                NavigationLink { VisionStudioView() } label: { Label("Camera", systemImage: "camera") }
                Button {
                    NotificationCenter.default.post(name: .jarvisOpenStandBy, object: nil)
                } label: {
                    Label("StandBy", systemImage: "moon.stars")
                }
            }
        }
        .navigationTitle("Settings")
        .toolbar(.visible, for: .navigationBar)
    }
}
