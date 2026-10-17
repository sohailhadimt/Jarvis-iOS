import SwiftUI

struct IntegrationsSettingsView: View {
    @Environment(AppSettings.self) private var settings
    @State private var newShortcut = ""
    @State private var newNote = ""
    @State private var agentKey = ""
    @State private var grokKey = ""
    @State private var saved = false

    var body: some View {
        @Bindable var settings = settings
        Form {
            AIProviderSection()
            Section {
                Picker("Routing", selection: $settings.routing) {
                    ForEach(TaskRouting.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.inline)
                .labelsHidden()
                Text("OpenAI web search model")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack {
                    TextField("OpenAI web search model", text: $settings.searchModel)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    Menu("Presets") {
                        ForEach(["gpt-4.1-mini", "gpt-4.1", "gpt-4o-mini", "gpt-4o"], id: \.self) { m in
                            Button(m) { settings.searchModel = m }
                        }
                    }
                }
            } header: {
                Text("Task agent routing")
            } footer: {
                Text("Questions are answered by the AI Provider above. Gemini uses gemini-3.8-flash unless you change it. Current facts use Gemini Google Search, then DuckDuckGo, Wikipedia, or Brave if that key is saved. Sources show under the reply. Groq uses llama-3.3-70b-versatile. Actions use tools: contacts, calls, messages, calendar, reminders, music, maps, apps and Shortcuts. One matching contact is called immediately. Messages, deletes and agent tasks ask you to confirm first.")
            }

            Section {
                ForEach(settings.shortcuts) { sc in
                    VStack(alignment: .leading) {
                        Text(sc.name)
                        if !sc.note.isEmpty { Text(sc.note).font(.caption).foregroundStyle(.secondary) }
                    }
                }
                .onDelete { settings.shortcuts.remove(atOffsets: $0) }
                TextField("Exact shortcut name", text: $newShortcut)
                TextField("What it does (helps JARVIS choose)", text: $newNote)
                Button("Add shortcut") {
                    settings.shortcuts.append(RegisteredShortcut(name: newShortcut.trimmingCharacters(in: .whitespaces),
                                                                 note: newNote))
                    newShortcut = ""
                    newNote = ""
                }
                .disabled(newShortcut.trimmingCharacters(in: .whitespaces).isEmpty)
            } header: {
                Text("My Shortcuts")
            } footer: {
                Text("JARVIS can run these through the Shortcuts app (it briefly switches to Shortcuts, then comes back).")
            }

            Section {
                LabeledContent("Timer") { TextField("Shortcut name", text: $settings.timerShortcut).multilineTextAlignment(.trailing) }
                LabeledContent("Alarm") { TextField("Shortcut name", text: $settings.alarmShortcut).multilineTextAlignment(.trailing) }
                LabeledContent("Music") { TextField("Optional", text: $settings.musicShortcut).multilineTextAlignment(.trailing) }
                LabeledContent("Country code") { TextField("44", text: $settings.countryCode).keyboardType(.numberPad).multilineTextAlignment(.trailing) }
            } header: {
                Text("Timer, alarm & music shortcuts")
            } footer: {
                Text("Apps can't set Clock timers or alarms directly. Make a Shortcut (see README) that takes text input and uses Start Timer / Create Alarm. The country code turns 07… numbers into WhatsApp links.")
            }

            Section {
                TextField("Name, e.g. Home server", text: $settings.agentWebhookName)
                TextField("https://…", text: $settings.agentWebhookURL)
                    .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                SecureField("Bearer key (optional)", text: $agentKey)
            } header: {
                Text("Agent webhook (send_task_to_agent)")
            } footer: {
                Text("JARVIS POSTs {\"task\": \"…\"} as JSON with an Authorization: Bearer header.")
            }

            Section {
                TextField("Routine webhook URL (POST to)", text: $settings.grokBotWebhookURL)
                    .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                SecureField("Routine webhook key", text: $grokKey)
            } header: {
                Text("Grok Bot")
            } footer: {
                Text("In Grok Bot, ask your Bot to create a routine with a webhook trigger, then copy its URL and key here. The Bot runs the routine and posts its result in its own chat; JARVIS only learns that the task was accepted.")
            }

            Section {
                Button("Save webhook keys") {
                    KeychainStore.set(agentKey, for: .agentWebhook)
                    KeychainStore.set(grokKey, for: .grokBotWebhook)
                    saved = true
                }
                if saved { Text("Saved in the Keychain.").font(.footnote).foregroundStyle(.green) }
            }
        }
        .navigationTitle("Integrations")
        .toolbar(.visible, for: .navigationBar)
        .onAppear {
            agentKey = KeychainStore.get(.agentWebhook) ?? ""
            grokKey = KeychainStore.get(.grokBotWebhook) ?? ""
        }
    }
}
