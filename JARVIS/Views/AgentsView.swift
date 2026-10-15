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
                    Label("Group room", systemImage: "bubble.left.and.bubble.right")
                }
            } footer: {
                Text("Mention an agent with @EDITH, @ULTRON, @FRIDAY, or @JARVIS. They answer here and can reply to each other.")
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
        .navigationTitle("Group room")
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

    var body: some View {
        Form {
            TextField("Name", text: $name)
            TextField("Role", text: $role)
            TextField("Avatar letter", text: $avatar)
            TextField("Personality and instructions", text: $instructions, axis: .vertical)
                .lineLimit(4...8)
            TextField("Memory", text: $memory, axis: .vertical)
                .lineLimit(2...6)
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
        }
    }

    private func save() {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let letter = avatar.trimmingCharacters(in: .whitespacesAndNewlines)
        let saved = NamedAgent(
            id: agent?.id ?? "agent_\(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(12))",
            name: trimmed,
            role: role.trimmingCharacters(in: .whitespacesAndNewlines),
            instructions: instructions.trimmingCharacters(in: .whitespacesAndNewlines),
            avatar: letter.isEmpty ? String(trimmed.prefix(1)) : String(letter.prefix(2)),
            colorHex: agent?.colorHex ?? "4BA8EE",
            memory: memory,
            builtin: agent?.builtin ?? false)
        store.saveAgent(saved, isNew: agent == nil)
        dismiss()
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
