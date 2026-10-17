import Foundation
import Observation

enum AgentJobStatus: String, Codable {
    case queued, working, done
    case needsApproval = "needs_approval"
}

struct NamedAgent: Codable, Identifiable, Hashable {
    var id: String
    var name: String
    var role: String
    var instructions: String
    var avatar: String
    var colorHex: String
    var memory: String
    var builtin: Bool
}

struct AgentLine: Codable, Identifiable, Hashable {
    var id: String
    var role: String
    var author: String
    var text: String
    var createdAt: Date
}

struct AgentJob: Codable, Identifiable, Hashable {
    var id: String
    var agentID: String
    var goal: String
    var status: AgentJobStatus
    var result: String?
    var approvalSummary: String?
    var announced: Bool
}

@MainActor
@Observable
final class AgentStore {
    static let shared = AgentStore()

    private(set) var agents: [NamedAgent] = []
    private(set) var threads: [String: [AgentLine]] = [:]
    private(set) var jobs: [AgentJob] = []
    private(set) var group: [AgentLine] = []

    @ObservationIgnored private var cloudLoop: Task<Void, Never>?
    private let defaultsKey = "namedAgents.v1"

    private init() {
        if let data = UserDefaults.standard.data(forKey: defaultsKey),
           let saved = try? JSONDecoder().decode(Snapshot.self, from: data) {
            agents = saved.agents
            threads = saved.threads
            jobs = saved.jobs
            group = saved.group
        }
        if agents.isEmpty { agents = Self.defaults }
        save()
    }

    func startCloudSync() {
        guard cloudLoop == nil else { return }
        cloudLoop = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refreshCloud()
                try? await Task.sleep(for: .seconds(12))
            }
        }
    }

    func agent(id: String) -> NamedAgent? { agents.first { $0.id == id } }

    func saveAgent(_ agent: NamedAgent, isNew: Bool) {
        if let index = agents.firstIndex(where: { $0.id == agent.id }) {
            agents[index] = agent
        } else {
            agents.append(agent)
        }
        save()
        Task { await pushAgent(agent) }
    }

    func deleteAgent(id: String) {
        agents.removeAll { $0.id == id }
        threads[id] = nil
        save()
        Task {
            guard JarvisCloud.isConfigured, let client = try? JarvisCloudAPI.client() else { return }
            try? await client.deletePersona(id: id)
        }
    }

    func restoreDefaults() {
        for agent in Self.defaults where !agents.contains(where: { $0.id == agent.id }) {
            agents.append(agent)
            let restored = agent
            Task { await pushAgent(restored) }
        }
        save()
    }

    /// "ask EDITH to research X" and the same shape for the other names.
    func delegation(in text: String) -> (agent: NamedAgent, goal: String)? {
        let pattern = #"(?i)\b(?:ask|tell|have|get)\s+([A-Za-z.]+)\s+(?:to\s+)?(.+)$"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let nameRange = Range(match.range(at: 1), in: text),
              let goalRange = Range(match.range(at: 2), in: text) else { return nil }
        let spoken = Self.squash(String(text[nameRange]))
        guard spoken.count >= 4 else { return nil }
        guard let agent = agents.first(where: { Self.squash($0.name) == spoken }) else { return nil }
        let goal = String(text[goalRange]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !goal.isEmpty else { return nil }
        return (agent, goal)
    }

    func delegate(agent: NamedAgent, goal: String) async {
        let job = AgentJob(id: "job_\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))",
                           agentID: agent.id, goal: goal, status: .queued,
                           result: nil, approvalSummary: nil, announced: false)
        jobs.insert(job, at: 0)
        append(agentID: agent.id, role: "user", author: "You", text: goal)
        save()
        if JarvisCloud.isConfigured, let client = try? JarvisCloudAPI.client() {
            if let remote = try? await client.enqueuePersona(id: job.id, agentID: agent.id, goal: goal) {
                updateJob(remote, announced: false)
                return
            }
        }
        await runLocally(jobID: job.id)
    }

    func reply(agent: NamedAgent, text: String) async {
        append(agentID: agent.id, role: "user", author: "You", text: text)
        if JarvisCloud.isConfigured, let client = try? JarvisCloudAPI.client() {
            try? await client.addPersonaMessage(agentID: agent.id, author: "You", role: "user", text: text)
        }
        await complete(agent: agent, goal: text, jobID: nil)
    }

    func postGroup(text: String, author: String = "You") async {
        group.append(AgentLine(id: UUID().uuidString, role: "user", author: author, text: text, createdAt: .now))
        save()
        if JarvisCloud.isConfigured, let client = try? JarvisCloudAPI.client() {
            try? await client.postGroupLine(author: author, text: text)
        }
        let folded = text.lowercased().replacingOccurrences(of: ".", with: "")
        let mentioned = agents.filter { folded.contains("@\(Self.squash($0.name))") }
        let targets = mentioned.isEmpty ? [] : mentioned
        for agent in targets {
            let answer = await speak(agent: agent, prompt: text)
            let line = "\(agent.name): \(answer)"
            group.append(AgentLine(id: UUID().uuidString, role: "agent", author: agent.name, text: answer, createdAt: .now))
            save()
            if JarvisCloud.isConfigured, let client = try? JarvisCloudAPI.client() {
                try? await client.postGroupLine(author: agent.name, text: answer)
            }
            if answer.uppercased().hasPrefix("APPROVAL:") {
                await openApproval(agent: agent, goal: text, draft: answer)
            } else if line.contains("@") {
                // One hop so agents can answer each other without a loop.
                let foldedAnswer = answer.lowercased().replacingOccurrences(of: ".", with: "")
                let next = agents.filter { $0.id != agent.id && foldedAnswer.contains("@\(Self.squash($0.name))") }
                for other in next.prefix(1) {
                    let follow = await speak(agent: other, prompt: answer)
                    group.append(AgentLine(id: UUID().uuidString, role: "agent", author: other.name, text: follow, createdAt: .now))
                    save()
                    if JarvisCloud.isConfigured, let client = try? JarvisCloudAPI.client() {
                        try? await client.postGroupLine(author: other.name, text: follow)
                    }
                }
            }
        }
    }

    func settle(jobID: String, approve: Bool) async {
        guard let index = jobs.firstIndex(where: { $0.id == jobID }) else { return }
        let note = approve
            ? "Approved as a draft. Nothing was sent, published, or paid."
            : "Declined. Nothing was sent, published, or paid."
        let draft = jobs[index].approvalSummary ?? jobs[index].result ?? ""
        jobs[index].status = .done
        jobs[index].result = [draft, note].filter { !$0.isEmpty }.joined(separator: "\n\n")
        jobs[index].announced = false
        save()
        announce(jobs[index])
        if JarvisCloud.isConfigured, let client = try? JarvisCloudAPI.client() {
            try? await client.settlePersona(id: jobID, approve: approve)
        }
    }

    func refreshCloud() async {
        guard JarvisCloud.isConfigured, let client = try? JarvisCloudAPI.client() else { return }
        if let remote = try? await client.personaAgents(), !remote.isEmpty {
            for item in remote {
                let agent = NamedAgent(id: item.id, name: item.name, role: item.role, instructions: item.instructions,
                                       avatar: item.avatar, colorHex: item.colorHex, memory: item.memory, builtin: item.builtin)
                if let index = agents.firstIndex(where: { $0.id == agent.id }) {
                    agents[index] = agent
                } else {
                    agents.append(agent)
                }
            }
        } else {
            for agent in agents { await pushAgent(agent) }
        }
        if let tasks = try? await client.personaTasks() {
            for task in tasks { updateJob(task, announced: jobs.first { $0.id == task.id }?.announced ?? false) }
        }
        if let lines = try? await client.groupLines() {
            let known = Set(group.map(\.id))
            for line in lines where !known.contains(line.id) {
                group.append(AgentLine(id: line.id, role: line.role ?? "user", author: line.author, text: line.text, createdAt: .now))
            }
        }
        save()
    }

    private func runLocally(jobID: String) async {
        guard let index = jobs.firstIndex(where: { $0.id == jobID }),
              let agent = agent(id: jobs[index].agentID) else { return }
        jobs[index].status = .working
        save()
        await complete(agent: agent, goal: jobs[index].goal, jobID: jobID)
    }

    private func complete(agent: NamedAgent, goal: String, jobID: String?) async {
        let answer = await speak(agent: agent, prompt: goal)
        append(agentID: agent.id, role: "agent", author: agent.name, text: answer)
        if JarvisCloud.isConfigured, let client = try? JarvisCloudAPI.client() {
            try? await client.addPersonaMessage(agentID: agent.id, author: agent.name, role: "agent", text: answer)
        }
        guard let jobID, let index = jobs.firstIndex(where: { $0.id == jobID }) else {
            AssistantEngine.shared.postAgentUpdate("\(agent.name): \(answer)")
            return
        }
        if Self.external(goal) || answer.uppercased().hasPrefix("APPROVAL:") {
            let draft = answer.replacingOccurrences(of: "APPROVAL:", with: "", options: .caseInsensitive).trimmingCharacters(in: .whitespacesAndNewlines)
            jobs[index].status = .needsApproval
            jobs[index].approvalSummary = draft
            jobs[index].result = draft
        } else {
            jobs[index].status = .done
            jobs[index].result = answer
        }
        save()
        announce(jobs[index])
    }

    private func speak(agent: NamedAgent, prompt: String) async -> String {
        do {
            let endpoint = try AppSettings.shared.geminiEndpoint()
            let memory = threads[agent.id]?.suffix(8).map { "\($0.author): \($0.text)" }.joined(separator: "\n") ?? ""
            let system = """
            You are \(agent.name), \(agent.role).
            \(agent.instructions)
            Memory:
            \(agent.memory.isEmpty ? "(none)" : agent.memory)
            Recent thread:
            \(memory.isEmpty ? "(none)" : memory)
            If the request would send a message, publish, or spend money, start with APPROVAL: and give the draft only. Never claim you sent, published, or paid.
            """
            let messages = [
                ChatMessage(role: "system", content: system),
                ChatMessage(role: "user", content: prompt),
            ]
            let reply = try await ModelFallback.run(
                primary: endpoint,
                groq: AppSettings.shared.groqEndpoint(),
                status: { line in AssistantEngine.shared.noteStatus(line) },
                work: { endpoint in
                    try await LLMClient.complete(messages: messages, endpoint: endpoint)
                }
            )
            return reply.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            AssistantEngine.shared.noteStatus(nil)
            return LLMError.short(error)
        }
    }

    private func openApproval(agent: NamedAgent, goal: String, draft: String) async {
        let cleaned = draft.replacingOccurrences(of: "APPROVAL:", with: "", options: .caseInsensitive)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let job = AgentJob(id: "job_\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))",
                           agentID: agent.id, goal: goal, status: .needsApproval,
                           result: cleaned, approvalSummary: cleaned, announced: false)
        jobs.insert(job, at: 0)
        save()
        announce(job)
    }

    private func announce(_ job: AgentJob) {
        guard let index = jobs.firstIndex(where: { $0.id == job.id }), !jobs[index].announced else { return }
        jobs[index].announced = true
        save()
        let name = agent(id: job.agentID)?.name ?? "Agent"
        let body: String
        switch jobs[index].status {
        case .needsApproval:
            body = "\(name) needs approval before anything goes out.\n\(jobs[index].approvalSummary ?? "")"
        case .done:
            body = "\(name): \(jobs[index].result ?? "Done.")"
        case .queued, .working:
            body = "\(name) is working on it."
        }
        AssistantEngine.shared.postAgentUpdate(body)
    }

    private func updateJob(_ remote: CloudPersonaTask, announced: Bool) {
        let status = AgentJobStatus(rawValue: remote.status) ?? .queued
        let job = AgentJob(id: remote.id, agentID: remote.agentId, goal: remote.goal, status: status,
                           result: remote.result, approvalSummary: remote.approvalSummary, announced: announced)
        if let index = jobs.firstIndex(where: { $0.id == job.id }) {
            let was = jobs[index].status
            jobs[index].goal = job.goal
            jobs[index].status = job.status
            jobs[index].result = job.result
            jobs[index].approvalSummary = job.approvalSummary
            if (was == .queued || was == .working), job.status == .done || job.status == .needsApproval {
                recordResult(jobs[index])
                announce(jobs[index])
            }
        } else {
            jobs.insert(job, at: 0)
            if job.status == .done || job.status == .needsApproval {
                recordResult(job)
            }
        }
    }

    private func recordResult(_ job: AgentJob) {
        guard let text = job.result?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return }
        let lines = threads[job.agentID] ?? []
        if lines.contains(where: { $0.role == "agent" && $0.text == text }) { return }
        let name = agent(id: job.agentID)?.name ?? "Agent"
        append(agentID: job.agentID, role: "agent", author: name, text: text)
    }

    private func pushAgent(_ agent: NamedAgent) async {
        guard JarvisCloud.isConfigured, let client = try? JarvisCloudAPI.client() else { return }
        let persona = CloudPersona(id: agent.id, name: agent.name, role: agent.role, instructions: agent.instructions,
                                   avatar: agent.avatar, colorHex: agent.colorHex, memory: agent.memory, builtin: agent.builtin)
        _ = try? await client.savePersona(persona, creating: true)
    }

    private func append(agentID: String, role: String, author: String, text: String) {
        var lines = threads[agentID] ?? []
        lines.append(AgentLine(id: UUID().uuidString, role: role, author: author, text: text, createdAt: .now))
        threads[agentID] = lines
        save()
    }

    private func save() {
        let snapshot = Snapshot(agents: agents, threads: threads, jobs: jobs, group: group)
        if let data = try? JSONEncoder().encode(snapshot) {
            UserDefaults.standard.set(data, forKey: defaultsKey)
        }
    }

    private static func squash(_ text: String) -> String {
        text.lowercased().filter(\.isLetter)
    }

    private static func external(_ goal: String) -> Bool {
        let lower = goal.lowercased()
        return ["send ", "email them", "publish", "post this", "spend", "pay ", "purchase"].contains { lower.contains($0) }
    }

    private struct Snapshot: Codable {
        var agents: [NamedAgent]
        var threads: [String: [AgentLine]]
        var jobs: [AgentJob]
        var group: [AgentLine]
    }

    private static let defaults: [NamedAgent] = [
        NamedAgent(id: "agent_jarvis", name: "J.A.R.V.I.S.", role: "Chief of staff",
                   instructions: "Coordinate the other agents, break a request into assignments, and report back in a few sentences. Draft plans only. Do not send, publish, or spend.",
                   avatar: "J", colorHex: "4BA8EE", memory: "", builtin: true),
        NamedAgent(id: "agent_edith", name: "E.D.I.T.H.", role: "Research and leads",
                   instructions: "Research the question, name sources when you have them, and draft lead notes. Do not contact anyone.",
                   avatar: "E", colorHex: "7AA2FF", memory: "", builtin: true),
        NamedAgent(id: "agent_ultron", name: "U.L.T.R.O.N.", role: "Sales",
                   instructions: "Draft outreach, proposals, and follow-ups. Leave them as drafts. Never send them.",
                   avatar: "U", colorHex: "E15B64", memory: "", builtin: true),
        NamedAgent(id: "agent_friday", name: "F.R.I.D.A.Y.", role: "Websites, content, and design",
                   instructions: "Draft page structure, copy, and design notes. Never publish a site or post.",
                   avatar: "F", colorHex: "C9A227", memory: "", builtin: true),
    ]
}
