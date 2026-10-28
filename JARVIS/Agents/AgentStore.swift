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
    var tools: [String]
    var voiceID: String
    var voiceName: String

    init(id: String, name: String, role: String, instructions: String, avatar: String, colorHex: String, memory: String, builtin: Bool, tools: [String] = [], voiceID: String = "", voiceName: String = "") {
        self.id = id
        self.name = name
        self.role = role
        self.instructions = instructions
        self.avatar = avatar
        self.colorHex = colorHex
        self.memory = memory
        self.builtin = builtin
        self.tools = tools
        self.voiceID = voiceID
        self.voiceName = voiceName
    }

    enum CodingKeys: String, CodingKey {
        case id, name, role, instructions, avatar, colorHex, memory, builtin, tools, voiceID, voiceName
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        role = try c.decode(String.self, forKey: .role)
        instructions = try c.decode(String.self, forKey: .instructions)
        avatar = try c.decode(String.self, forKey: .avatar)
        colorHex = try c.decode(String.self, forKey: .colorHex)
        memory = try c.decode(String.self, forKey: .memory)
        builtin = try c.decode(Bool.self, forKey: .builtin)
        tools = try c.decodeIfPresent([String].self, forKey: .tools) ?? []
        voiceID = try c.decodeIfPresent(String.self, forKey: .voiceID) ?? ""
        voiceName = try c.decodeIfPresent(String.self, forKey: .voiceName) ?? ""
    }
}

struct AgentMission: Codable, Identifiable, Hashable {
    var id: String
    var goal: String
    var status: String
    var report: String?
}

struct AgentRoutine: Codable, Identifiable, Hashable {
    var id: String
    var name: String
    var cron: String
    var enabled: Bool
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
    private(set) var missions: [AgentMission] = []
    private(set) var routines: [AgentRoutine] = []

    @ObservationIgnored private var cloudLoop: Task<Void, Never>?
    private let defaultsKey = "namedAgents.v1"

    private init() {
        if let data = UserDefaults.standard.data(forKey: defaultsKey),
           let saved = try? JSONDecoder().decode(Snapshot.self, from: data) {
            agents = saved.agents
            threads = saved.threads
            jobs = saved.jobs
            group = saved.group
            missions = saved.missions ?? []
            routines = saved.routines ?? []
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

    /// Exact squashed name, so a missed contact named Edith can still reach E.D.I.T.H.
    func agentNamed(_ spoken: String) -> NamedAgent? {
        let key = Self.squash(spoken)
        guard key.count >= 4 else { return nil }
        return agents.first { Self.squash($0.name) == key }
    }

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

    /// "EDITH, research X" or "ask EDITH to research X".
    func delegation(in text: String) -> (agent: NamedAgent, goal: String)? {
        if let direct = directAddress(in: text) { return direct }
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

    private func directAddress(in text: String) -> (agent: NamedAgent, goal: String)? {
        let pattern = #"(?i)^(?:hey\s+)?([A-Za-z.]+)\s*[,:]\s+(.+)$"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let nameRange = Range(match.range(at: 1), in: text),
              let goalRange = Range(match.range(at: 2), in: text) else { return nil }
        let spoken = Self.squash(String(text[nameRange]))
        guard spoken.count >= 4, let agent = agents.first(where: { Self.squash($0.name) == spoken }) else { return nil }
        let goal = String(text[goalRange]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !goal.isEmpty else { return nil }
        return (agent, goal)
    }

    func startMission(goal: String) async -> String {
        guard JarvisCloud.isConfigured, let client = try? JarvisCloudAPI.client() else {
            return "That mission needs JARVIS Cloud. Add the backend URL and app token in Settings."
        }
        do {
            let mission = try await client.createMission(goal: goal)
            upsert(mission)
            save()
            return "I'll plan that and hand it to the team."
        } catch {
            return JarvisLines.explain(error)
        }
    }

    func setRoutine(id: String, enabled: Bool) async {
        if let index = routines.firstIndex(where: { $0.id == id }) {
            routines[index].enabled = enabled
            save()
        }
        guard JarvisCloud.isConfigured, let client = try? JarvisCloudAPI.client() else { return }
        try? await client.setRoutine(id: id, enabled: enabled)
        await refreshCloud()
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
        if JarvisCloud.isConfigured {
            await delegate(agent: agent, goal: text)
            return
        }
        append(agentID: agent.id, role: "user", author: "You", text: text)
        await complete(agent: agent, goal: text, jobID: nil)
    }

    func postGroup(text: String, author: String = "You") async {
        if JarvisCloud.isConfigured, let client = try? JarvisCloudAPI.client() {
            try? await client.postGroupLine(author: author, text: text)
            await refreshCloud()
            return
        }
        group.append(AgentLine(id: UUID().uuidString, role: "user", author: author, text: text, createdAt: .now))
        save()
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
                                       avatar: item.avatar, colorHex: item.colorHex, memory: item.memory, builtin: item.builtin,
                                       tools: item.tools, voiceID: item.voiceID, voiceName: item.voiceName)
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
            group = lines.map {
                AgentLine(id: $0.id, role: $0.role ?? "user", author: $0.author, text: $0.text,
                          createdAt: $0.createdAt.flatMap(CloudTime.date) ?? .now)
            }
        }
        if let remoteMissions = try? await client.missions() {
            missions = remoteMissions.map {
                AgentMission(id: $0.id, goal: $0.goal, status: $0.status, report: $0.report)
            }
        }
        if let remoteRoutines = try? await client.routines() {
            routines = remoteRoutines.map {
                AgentRoutine(id: $0.id, name: $0.name, cron: $0.cron, enabled: $0.enabled)
            }
        }
        save()
    }

    private func upsert(_ mission: CloudMission) {
        let item = AgentMission(id: mission.id, goal: mission.goal, status: mission.status, report: mission.report)
        if let index = missions.firstIndex(where: { $0.id == item.id }) {
            missions[index] = item
        } else {
            missions.insert(item, at: 0)
        }
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
            AssistantEngine.shared.speakAgentLine("\(agent.name): \(answer)", voiceID: agent.voiceID)
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
        let speaker = agent(id: job.agentID)
        let name = speaker?.name ?? "Agent"
        let body: String
        switch jobs[index].status {
        case .needsApproval:
            body = "\(name) needs approval before anything goes out.\n\(jobs[index].approvalSummary ?? "")"
        case .done:
            body = "\(name): \(jobs[index].result ?? "Done.")"
        case .queued, .working:
            body = "\(name) is working on it."
        }
        AssistantEngine.shared.speakAgentLine(body, voiceID: speaker?.voiceID ?? "")
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
                                   avatar: agent.avatar, colorHex: agent.colorHex, memory: agent.memory, builtin: agent.builtin,
                                   tools: agent.tools, voiceID: agent.voiceID, voiceName: agent.voiceName)
        _ = try? await client.savePersona(persona, creating: true)
    }

    private func append(agentID: String, role: String, author: String, text: String) {
        var lines = threads[agentID] ?? []
        lines.append(AgentLine(id: UUID().uuidString, role: role, author: author, text: text, createdAt: .now))
        threads[agentID] = lines
        save()
    }

    private func save() {
        let snapshot = Snapshot(agents: agents, threads: threads, jobs: jobs, group: group, missions: missions, routines: routines)
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
        var missions: [AgentMission]?
        var routines: [AgentRoutine]?
    }

    static func presetTools(id: String) -> [String] {
        defaults.first { $0.id == id }?.tools ?? ["memory"]
    }

    private static let defaults: [NamedAgent] = [
        NamedAgent(id: "agent_jarvis", name: "J.A.R.V.I.S.", role: "Chief of staff",
                   instructions: "Plan the mission, delegate to EDITH, ULTRON, and FRIDAY, check what they stored, and report back. Any send, spend, publish, or call stays a draft until Sohail approves it. You do not send, publish, spend, or dial.",
                   avatar: "J", colorHex: "4BA8EE", memory: "", builtin: true,
                   tools: ["list_findings", "list_pipeline", "request_approval", "memory", "reminder"]),
        NamedAgent(id: "agent_edith", name: "E.D.I.T.H.", role: "Research and intelligence",
                   instructions: "Do deep research with web search and opened pages. Build prospect dossiers only from those pages and keep the source URL on every claim. Do not contact anyone, and do not invent companies, prices, or emails.",
                   avatar: "E", colorHex: "7AA2FF", memory: "", builtin: true,
                   tools: ["web_search", "fetch_url", "save_finding", "save_lead", "list_findings", "memory"]),
        NamedAgent(id: "agent_ultron", name: "U.L.T.R.O.N.", role: "Sales and strategy",
                   instructions: "Draft pitch outlines, pricing notes, proposals, and outreach from stored findings. Leave every send as a draft. Do not email, publish, or spend.",
                   avatar: "U", colorHex: "E15B64", memory: "", builtin: true,
                   tools: ["list_findings", "list_pipeline", "draft_document", "request_approval", "draft_call", "memory"]),
        NamedAgent(id: "agent_friday", name: "F.R.I.D.A.Y.", role: "Builder and operations",
                   instructions: "Draft landing pages, HTML, code snippets, automations, and schedules. Do not publish a site, run a payment, or send a message.",
                   avatar: "F", colorHex: "C9A227", memory: "", builtin: true,
                   tools: ["web_search", "fetch_url", "draft_document", "reminder", "request_approval", "memory"]),
    ]
}
