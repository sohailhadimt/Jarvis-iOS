import SwiftData
import SwiftUI

struct PersonalitySettingsView: View {
    @Environment(AppSettings.self) private var settings

    var body: some View {
        @Bindable var settings = settings
        Form {
            Section("Presets") {
                ForEach(PersonalityPreset.allCases) { preset in
                    Button {
                        settings.personality = preset.prompt
                    } label: {
                        HStack {
                            Text(preset.title)
                            Spacer()
                            if settings.personality == preset.prompt { Image(systemName: "checkmark") }
                        }
                    }
                }
            }
            Section("System prompt") {
                TextEditor(text: $settings.personality).frame(minHeight: 220)
            }
            Section {
                Button("Reset to default") {
                    settings.personality = PersonalityPreset.jarvis.prompt
                }
            } footer: {
                Text("This personality is used for spoken replies and for tool turns. Spoken answers stay to one to three sentences unless you ask for more.")
            }
        }
        .navigationTitle("Personality")
        .toolbar(.visible, for: .navigationBar)
    }
}

struct InstructionsSettingsView: View {
    @Environment(AppSettings.self) private var settings

    var body: some View {
        @Bindable var settings = settings
        Form {
            Section {
                TextEditor(text: $settings.instructions).frame(minHeight: 260)
            } footer: {
                Text("Extra standing instructions added after the personality, e.g. \"Always give temperatures in °C\".")
            }
        }
        .navigationTitle("Instructions")
        .toolbar(.visible, for: .navigationBar)
    }
}

struct MemorySettingsView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(\.modelContext) private var context
    @Query(sort: \MemoryFact.createdAt, order: .reverse) private var facts: [MemoryFact]
    @State private var newFact = ""

    var body: some View {
        @Bindable var settings = settings
        Form {
            Section {
                Toggle("Let JARVIS save facts automatically", isOn: $settings.autoRemember)
            } footer: {
                Text("When on, the assistant may add a hidden line \"REMEMBER: …\" to a reply; that fact is saved here.")
            }
            Section("Add a fact") {
                HStack {
                    TextField("e.g. I live in Manchester", text: $newFact)
                    Button("Add") {
                        let t = newFact.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !t.isEmpty else { return }
                        context.insert(MemoryFact(text: t))
                        try? context.save()
                        newFact = ""
                    }
                    .disabled(newFact.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            Section("Remembered (\(facts.count))") {
                ForEach(facts) { fact in
                    NavigationLink { MemoryFactEditor(fact: fact) } label: { Text(fact.text).lineLimit(2) }
                }
                .onDelete { offsets in
                    for i in offsets { context.delete(facts[i]) }
                    try? context.save()
                }
            }
        }
        .navigationTitle("Memory")
        .toolbar(.visible, for: .navigationBar)
        .toolbar { EditButton() }
    }
}

struct MemoryFactEditor: View {
    @Bindable var fact: MemoryFact
    @Environment(\.modelContext) private var context

    var body: some View {
        Form {
            TextField("Fact", text: $fact.text, axis: .vertical)
            LabeledContent("Added", value: fact.createdAt.formatted(date: .abbreviated, time: .shortened))
        }
        .navigationTitle("Edit fact")
        .toolbar(.visible, for: .navigationBar)
        .onDisappear { try? context.save() }
    }
}
