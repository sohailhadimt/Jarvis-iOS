import SwiftUI

struct AgentsView: View {
    @State private var store = AgentStore.shared
    @State private var editing: NamedAgent?
    @State private var creating = false

    var body: some View {
        List {
            Section {
                NavigationLink {
                    GroupRoomView()
                } label: {
                    Label("Project Money", systemImage: "bubble.left.and.bubble.right")
                }
            } footer: {
                Text("EDITH, ULTRON, and FRIDAY compare notes here. Mention one with @EDITH, @ULTRON, @FRIDAY, or @JARVIS. With JARVIS Cloud on, they answer from the worker.")
            }
            Section("Missions") {
                ForEach(store.missions) { mission in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(mission.goal).lineLimit(3)
                        Text(mission.status).font(.caption).foregroundStyle(.secondary)
                        if let report = mission.report, !report.isEmpty {
                            Text(report).font(.caption).lineLimit(6)
                        }
                    }
                }
                MissionComposer()
            }
            if !store.routines.isEmpty {
                Section {
                    ForEach(store.routines) { routine in
                        Toggle(isOn: Binding(
                            get: { routine.enabled },
                            set: { on in Task { await store.setRoutine(id: routine.id, enabled: on) } }
                        )) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(routine.name)
                                Text(routine.cron).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                } header: {
                    Text("Routines")
                } footer: {
                    Text("Off until you turn one on. The worker cron then plans a mission. Nothing is sent, published, or paid.")
                }
            }
            if !store.jobs.isEmpty {
                Section("Background tasks") {
                    ForEach(store.jobs) { job in
                        AgentJobCard(job: job)
                    }
                }
            }
            Section("Agents") {
                ForEach(store.agents) { agent in
                    NavigationLink {
                        AgentThreadView(agentID: agent.id)
                    } label: {
                        HStack(spacing: 12) {
                            AgentBadge(agent: agent)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(agent.name)
                                Text(agent.role).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .swipeActions {
                        Button("Edit") { editing = agent }.tint(.blue)
                        Button("Delete", role: .destructive) { store.deleteAgent(id: agent.id) }
                    }
                }
            }
        }
        .navigationTitle("Agents")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { creating = true } label: { Image(systemName: "plus") }
            }
            ToolbarItem(placement: .cancellationAction) {
                Button("Restore") { store.restoreDefaults() }
            }
        }
        .sheet(isPresented: $creating) {
            NavigationStack { AgentEditor(agent: nil) }
        }
        .sheet(item: $editing) { agent in
            NavigationStack { AgentEditor(agent: agent) }
        }
        .task { await store.refreshCloud() }
    }
}

struct AgentThreadView: View {
    var agentID: String
    @State private var store = AgentStore.shared
    @State private var draft = ""
    @State private var memory = ""
    @State private var editing = false

    private var agent: NamedAgent? { store.agent(id: agentID) }

    var body: some View {
        VStack(spacing: 0) {
            if let agent {
                List {
                    Section("Memory") {
                        TextField("Notes this agent should remember", text: $memory, axis: .vertical)
                            .lineLimit(2...5)
                        Button("Save memory") {
                            var copy = agent
                            copy.memory = memory
                            store.saveAgent(copy, isNew: false)
                        }
                    }
                    Section("Thread") {
                        ForEach(store.threads[agentID] ?? []) { line in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(line.author).font(.caption).foregroundStyle(.secondary)
                                Text(line.text)
                            }
                        }
                    }
                }
                HStack {
                    TextField("Message \(agent.name)", text: $draft)
                    Button("Send") { send(agent) }
                        .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                .padding()
            }
        }
        .navigationTitle(agent?.name ?? "Agent")
        .toolbar {
            if agent != nil {
                Button("Edit") { editing = true }
            }
        }
        .onAppear { memory = agent?.memory ?? "" }
        .sheet(isPresented: $editing) {
            if let agent {
                NavigationStack { AgentEditor(agent: agent) }
            }
        }
    }

    private func send(_ agent: NamedAgent) {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        draft = ""
        Task { await store.reply(agent: agent, text: text) }
    }
}

struct GroupRoomView: View {
    @State private var store = AgentStore.shared
    @State private var draft = ""

    var body: some View {
        VStack {
            List(store.group) { line in
                VStack(alignment: .leading, spacing: 2) {
                    Text(line.author).font(.caption).foregroundStyle(.secondary)
                    Text(line.text)
                }
            }
            HStack {
                TextField("Message the room", text: $draft)
                Button("Send") { send() }
                    .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding()
        }
        .navigationTitle("Project Money")
    }

    private func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        draft = ""
        Task { await store.postGroup(text: text) }
    }
}

struct AgentEditor: View {
    var agent: NamedAgent?
    @Environment(\.dismiss) private var dismiss
    @State private var store = AgentStore.shared
    @State private var name = ""
    @State private var role = ""
    @State private var instructions = ""
    @State private var avatar = ""
    @State private var memory = ""
    @State private var colorHex = "4BA8EE"
    @State private var voiceID = ""
    @State private var voiceName = ""
    @State private var tools: Set<String> = []

    private static let toolChoices = [
        "web_search", "fetch_url", "save_finding", "save_lead", "draft_document",
        "request_approval", "list_findings", "list_pipeline", "memory", "draft_call",
        "reminder", "files", "image_gen",
    ]

    var body: some View {
        Form {
            TextField("Name", text: $name)
            TextField("Role", text: $role)
            TextField("Avatar letter", text: $avatar)
            TextField("Colour hex", text: $colorHex)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            TextField("Personality and instructions", text: $instructions, axis: .vertical)
                .lineLimit(4...8)
            TextField("Memory", text: $memory, axis: .vertical)
                .lineLimit(2...6)
            TextField("ElevenLabs voice id", text: $voiceID)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            TextField("Voice name", text: $voiceName)
            Section("Tools") {
                ForEach(Self.toolChoices, id: \.self) { tool in
                    Toggle(tool, isOn: Binding(
                        get: { tools.contains(tool) },
                        set: { on in
                            if on { tools.insert(tool) } else { tools.remove(tool) }
                        }
                    ))
                }
            }
        }
        .navigationTitle(agent == nil ? "New agent" : "Edit agent")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") { save() }.disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .onAppear {
            name = agent?.name ?? ""
            role = agent?.role ?? ""
            instructions = agent?.instructions ?? ""
            avatar = agent?.avatar ?? ""
            memory = agent?.memory ?? ""
            colorHex = agent?.colorHex ?? "4BA8EE"
            voiceID = agent?.voiceID ?? ""
            voiceName = agent?.voiceName ?? ""
            let stored = agent?.tools ?? []
            tools = Set(stored.isEmpty ? AgentStore.presetTools(id: agent?.id ?? "") : stored)
        }
    }

    private func save() {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let letter = avatar.trimmingCharacters(in: .whitespacesAndNewlines)
        let hex = colorHex.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "#", with: "")
        let saved = NamedAgent(
            id: agent?.id ?? "agent_\(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(12))",
            name: trimmed,
            role: role.trimmingCharacters(in: .whitespacesAndNewlines),
            instructions: instructions.trimmingCharacters(in: .whitespacesAndNewlines),
            avatar: letter.isEmpty ? String(trimmed.prefix(1)) : String(letter.prefix(2)),
            colorHex: hex.isEmpty ? "4BA8EE" : hex,
            memory: memory,
            builtin: agent?.builtin ?? false,
            tools: Self.toolChoices.filter { tools.contains($0) },
            voiceID: voiceID.trimmingCharacters(in: .whitespacesAndNewlines),
            voiceName: voiceName.trimmingCharacters(in: .whitespacesAndNewlines))
        store.saveAgent(saved, isNew: agent == nil)
        dismiss()
    }
}

private struct MissionComposer: View {
    @State private var store = AgentStore.shared
    @State private var goal = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Mission for JARVIS", text: $goal, axis: .vertical)
                .lineLimit(2...4)
            Button("Assign to the team") { assign() }
                .disabled(goal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }

    private func assign() {
        let text = goal.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        goal = ""
        Task { _ = await store.startMission(goal: text) }
    }
}

struct AgentBadge: View {
    var agent: NamedAgent

    var body: some View {
        Text(agent.avatar)
            .font(.headline)
            .foregroundStyle(.white)
            .frame(width: 36, height: 36)
            .background(Color(hex: agent.colorHex), in: Circle())
    }
}

struct AgentJobCard: View {
    var job: AgentJob
    @State private var store = AgentStore.shared

    private var name: String { store.agent(id: job.agentID)?.name ?? "Agent" }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(name).font(.subheadline.weight(.semibold))
            Text(job.goal).font(.caption).lineLimit(2)
            Text(label).font(.caption2).foregroundStyle(.secondary)
            if let result = job.result, job.status == .done || job.status == .needsApproval {
                Text(result).font(.caption).lineLimit(4)
            }
            if job.status == .needsApproval {
                HStack {
                    Button("Decline") { Task { await store.settle(jobID: job.id, approve: false) } }
                    Button("Approve draft") { Task { await store.settle(jobID: job.id, approve: true) } }
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(.vertical, 4)
    }

    private var label: String {
        switch job.status {
        case .queued: "Queued"
        case .working: "Working"
        case .done: "Done"
        case .needsApproval: "Needs approval"
        }
    }
}

struct AgentJobStrip: View {
    @State private var store = AgentStore.shared

    var body: some View {
        let open = store.jobs.filter { $0.status != .done }
        if !open.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(open.prefix(6)) { job in
                        AgentJobCard(job: job)
                            .padding(10)
                            .frame(width: 220, alignment: .leading)
                            .background(Color(white: 0.12), in: RoundedRectangle(cornerRadius: 14))
                    }
                }
            }
        }
    }
}
