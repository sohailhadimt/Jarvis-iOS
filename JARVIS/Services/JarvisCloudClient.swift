import Foundation

enum CloudFailure: LocalizedError {
    case notConfigured
    case badURL
    case http(Int, String)

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            "The JARVIS cloud isn't configured. Add the backend URL and app token in Settings, JARVIS Cloud."
        case .badURL:
            "The JARVIS Cloud backend URL is invalid."
        case .http(let code, let message):
            if code < 0 {
                "JARVIS Cloud could not be reached: \(message)"
            } else {
                "JARVIS Cloud error \(code): \(message)"
            }
        }
    }
}

enum JarvisCloud {
    static func baseURL(_ raw: String) -> URL? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        while text.hasSuffix("/") { text.removeLast() }
        guard let url = URL(string: text),
              let scheme = url.scheme?.lowercased(),
              scheme == "https" || scheme == "http",
              let host = url.host, !host.isEmpty else { return nil }
        return url
    }

    @MainActor
    static var isConfigured: Bool {
        baseURL(AppSettings.shared.cloudBaseURL) != nil && KeychainStore.get(.jarvisCloud) != nil
    }
}

enum CloudStage {
    static let order = [
        "prospect", "qualified", "contacted", "positive", "meeting",
        "proposal_sent", "negotiation", "won", "lost", "active_client",
    ]

    static func label(_ stage: String) -> String {
        stage.replacingOccurrences(of: "_", with: " ")
    }
}

enum CloudTime {
    static func date(_ iso: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return fractional.date(from: iso) ?? plain.date(from: iso)
    }

    static func display(_ iso: String?) -> String {
        guard let iso, !iso.isEmpty else { return "" }
        return date(iso)?.formatted(date: .abbreviated, time: .shortened) ?? iso
    }
}

struct AgentPending: Decodable, Sendable {
    var messageId: String
    var status: String
}

struct AgentMessage: Decodable, Sendable {
    var id: String
    var conversationId: String
    var role: String
    var text: String
    var status: String
    var replyTo: String?
    var createdAt: String
}

struct CloudChatReply: Decodable, Sendable {
    var ok: Bool
    var reply: String
}

struct LiveTicket: Decodable, Sendable {
    var ok: Bool
    var token: String
    var model: String
    var websocketURL: String
    var expiresAt: String?
    var sessionExpiresAt: String?

    enum CodingKeys: String, CodingKey {
        case ok, token, model
        case websocketURL = "websocket_url"
        case expiresAt = "expires_at"
        case sessionExpiresAt = "session_expires_at"
    }
}

enum LiveTicketResult: Sendable {
    case ready(LiveTicket)
    case unavailable(String)
}

struct CloudHealth: Decodable, Sendable {
    var ok: Bool
    var service: String
    var version: String
    var time: String
    var cron: String
    var externalActions: Bool
    var db: String
    var message: String?

    enum CodingKeys: String, CodingKey {
        case ok, service, version, time, cron, db, message
        case externalActions = "external_actions"
    }
}

struct CloudTask: Decodable, Identifiable, Sendable, Hashable {
    var id: String
    var goal: String
    var status: String
    var schedule: String?
    var scheduledJobId: String?
    var error: String?
    var resultSummary: String?
    var createdAt: String
    var updatedAt: String
    var completedAt: String?

    enum CodingKeys: String, CodingKey {
        case id, goal, status, schedule, error
        case scheduledJobId = "scheduled_job_id"
        case resultSummary = "result_summary"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case completedAt = "completed_at"
    }
}

struct CloudSubtask: Decodable, Identifiable, Sendable {
    var id: String
    var taskId: String
    var agent: String
    var title: String
    var instruction: String
    var actionLevel: String
    var dependsOn: [String]
    var status: String
    var step: Int
    var maxSteps: Int
    var attempt: Int
    var resultSummary: String?
    var error: String?
    var nextAttemptAt: String?
    var createdAt: String
    var updatedAt: String

    enum CodingKeys: String, CodingKey {
        case id, agent, title, instruction, status, step, attempt
        case taskId = "task_id"
        case actionLevel = "action_level"
        case dependsOn = "depends_on"
        case maxSteps = "max_steps"
        case resultSummary = "result_summary"
        case error
        case nextAttemptAt = "next_attempt_at"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }
}

struct CloudProgress: Decodable, Identifiable, Sendable {
    var id: String
    var taskId: String
    var subtaskId: String?
    var level: String
    var message: String
    var detail: JSONValue?
    var createdAt: String

    enum CodingKeys: String, CodingKey {
        case id, level, message, detail
        case taskId = "task_id"
        case subtaskId = "subtask_id"
        case createdAt = "created_at"
    }
}

struct CloudFinding: Decodable, Identifiable, Sendable {
    var id: String
    var taskId: String
    var subtaskId: String
    var claim: String
    var sourceUrls: [String]
    var excerpt: String?
    var createdAt: String

    enum CodingKeys: String, CodingKey {
        case id, claim, excerpt
        case taskId = "task_id"
        case subtaskId = "subtask_id"
        case sourceUrls = "source_urls"
        case createdAt = "created_at"
    }
}

struct CloudDocument: Decodable, Identifiable, Sendable {
    var id: String
    var taskId: String
    var subtaskId: String
    var kind: String
    var title: String
    var body: String
    var sourceUrls: [String]
    var createdAt: String

    enum CodingKeys: String, CodingKey {
        case id, kind, title, body
        case taskId = "task_id"
        case subtaskId = "subtask_id"
        case sourceUrls = "source_urls"
        case createdAt = "created_at"
    }
}

struct CloudApproval: Decodable, Identifiable, Sendable, Hashable {
    var id: String
    var taskId: String?
    var subtaskId: String?
    var action: String
    var level: String
    var summary: String
    var payload: JSONValue?
    var status: String
    var reason: String?
    var createdAt: String
    var decidedAt: String?

    enum CodingKeys: String, CodingKey {
        case id, action, level, summary, payload, status, reason
        case taskId = "task_id"
        case subtaskId = "subtask_id"
        case createdAt = "created_at"
        case decidedAt = "decided_at"
    }
}

struct CloudMemory: Decodable, Identifiable, Sendable {
    var id: String
    var key: String?
    var content: String
    var tags: [String]
    var sourceUrls: [String]
    var createdAt: String
    var updatedAt: String

    enum CodingKeys: String, CodingKey {
        case id, key, content, tags
        case sourceUrls = "source_urls"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }
}

struct CloudLead: Decodable, Identifiable, Sendable, Hashable {
    var id: String
    var company: String
    var contactName: String?
    var contactEmail: String?
    var website: String?
    var stage: String
    var mrr: Double?
    var notes: String?
    var sourceUrls: [String]
    var taskId: String?
    var createdAt: String
    var updatedAt: String

    enum CodingKeys: String, CodingKey {
        case id, company, website, stage, mrr, notes
        case contactName = "contact_name"
        case contactEmail = "contact_email"
        case sourceUrls = "source_urls"
        case taskId = "task_id"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }
}

struct CloudActivity: Decodable, Identifiable, Sendable {
    var id: String
    var actor: String
    var action: String
    var taskId: String?
    var detail: JSONValue?
    var createdAt: String

    enum CodingKeys: String, CodingKey {
        case id, actor, action, detail
        case taskId = "task_id"
        case createdAt = "created_at"
    }
}

struct CloudTaskDetail: Decodable, Sendable {
    var task: CloudTask
    var subtasks: [CloudSubtask]
    var progress: [CloudProgress]
    var findings: [CloudFinding]
    var documents: [CloudDocument]
    var approvals: [CloudApproval]
}

struct CloudBriefing: Decodable, Sendable {
    var generatedAt: String
    var windowStart: String
    var separation: String
    var facts: Facts
    var recommendations: [Recommendation]
    var reminders: [String]?

    struct Facts: Decodable, Sendable {
        var completedTasks: [CloudTask]
        var failedTasks: [CloudTask]
        var pendingApprovals: [CloudApproval]
        var results: Results
        var pipeline: Pipeline

        enum CodingKeys: String, CodingKey {
            case pipeline, results
            case completedTasks = "completed_tasks"
            case failedTasks = "failed_tasks"
            case pendingApprovals = "pending_approvals"
        }
    }

    struct Results: Decodable, Sendable {
        var findings: [CloudFinding]
        var documents: [CloudDocument]
    }

    struct Pipeline: Decodable, Sendable {
        var byStage: [String: Int]
        var rows: [CloudLead]
        var mrr: MRR

        enum CodingKeys: String, CodingKey {
            case rows, mrr
            case byStage = "by_stage"
        }
    }

    struct MRR: Decodable, Sendable {
        var currency: String
        var stagesCounted: [String]
        var knownTotal: Double
        var rowsWithMrr: Int
        var rowsMissingMrr: Int
        var note: String

        enum CodingKeys: String, CodingKey {
            case currency, note
            case stagesCounted = "stages_counted"
            case knownTotal = "known_total"
            case rowsWithMrr = "rows_with_mrr"
            case rowsMissingMrr = "rows_missing_mrr"
        }
    }

    struct Recommendation: Decodable, Identifiable, Sendable {
        var id: String
        var text: String
        var basedOn: [String]

        enum CodingKeys: String, CodingKey {
            case id, text
            case basedOn = "based_on"
        }
    }

    enum CodingKeys: String, CodingKey {
        case facts, recommendations, separation, reminders
        case generatedAt = "generated_at"
        case windowStart = "window_start"
    }
}

struct CloudDecision: Decodable, Sendable {
    var approval: CloudApproval
    var externalActionTaken: Bool

    enum CodingKeys: String, CodingKey {
        case approval
        case externalActionTaken = "external_action_taken"
    }
}

enum CloudSpeech {
    static func briefing(_ briefing: CloudBriefing) -> String {
        var facts: [String] = []
        let completed = briefing.facts.completedTasks
        let failed = briefing.facts.failedTasks
        if completed.isEmpty && failed.isEmpty {
            facts.append("No completed or failed tasks are stored in the last day.")
        }
        if !completed.isEmpty {
            facts.append("Completed. " + joined(completed.map { taskLine($0) }, count: completed.count))
        }
        if !failed.isEmpty {
            facts.append("Failed. " + joined(failed.map { task in
                var line = task.goal
                if let error = task.error, !error.isEmpty { line += ". \(JarvisLines.explain(error))" }
                return line
            }, count: failed.count))
        }
        let waiting = briefing.facts.pendingApprovals
        if waiting.isEmpty {
            facts.append("No approvals are waiting.")
        } else {
            facts.append("Approvals waiting. " + joined(waiting.map(\.summary), count: waiting.count))
        }
        if let reminders = briefing.reminders, !reminders.isEmpty {
            facts.append("Reminders. " + joined(reminders, count: reminders.count))
        }
        let findings = briefing.facts.results.findings
        if findings.isEmpty {
            facts.append("No findings were stored in that window.")
        } else {
            let lines = findings.map { finding in
                var line = finding.claim
                if !finding.sourceUrls.isEmpty { line += " Source \(finding.sourceUrls.joined(separator: ", "))." }
                return line
            }
            facts.append("Findings. " + joined(lines, count: findings.count))
        }
        let documents = briefing.facts.results.documents
        if !documents.isEmpty {
            let lines = documents.map { "\($0.kind) \($0.title)" }
            facts.append("Drafts stored. " + joined(lines, count: documents.count) + " These drafts have not been sent or published.")
        }
        facts.append(pipelineFacts(briefing.facts.pipeline))
        let recommendations = briefing.recommendations.map(\.text)
        let recommendationText = recommendations.isEmpty
            ? "No recommendations were returned."
            : joined(recommendations, count: recommendations.count)
        return "\(briefing.separation) Facts. \(facts.joined(separator: " ")) Recommendations. \(recommendationText)"
    }

    static func tasks(_ tasks: [CloudTask]) -> String {
        if tasks.isEmpty { return "No tasks are stored." }
        return joined(tasks.map { taskLine($0) }, count: tasks.count)
    }

    static func taskDetail(_ detail: CloudTaskDetail) -> String {
        var parts = [taskLine(detail.task)]
        if let summary = detail.task.resultSummary, !summary.isEmpty {
            parts.append("Result summary. \(summary)")
        }
        if detail.subtasks.isEmpty {
            parts.append("No subtasks are stored.")
        } else {
            let lines = detail.subtasks.map { sub in
                var line = "\(sub.agent) \(sub.status): \(sub.title)"
                if let summary = sub.resultSummary, !summary.isEmpty { line += ". \(summary)" }
                if let error = sub.error, !error.isEmpty { line += ". \(JarvisLines.explain(error))" }
                return line
            }
            parts.append("Subtasks. " + lines.joined(separator: " "))
        }
        if !detail.progress.isEmpty {
            let lines = detail.progress.suffix(6).map { "\($0.level). \($0.message)" }
            parts.append("Progress. " + lines.joined(separator: " "))
        }
        if !detail.findings.isEmpty {
            let lines = detail.findings.map { finding in
                finding.claim + (finding.sourceUrls.isEmpty ? "" : " Source \(finding.sourceUrls.joined(separator: ", ")).")
            }
            parts.append("Findings. " + joined(lines, count: detail.findings.count))
        }
        if !detail.documents.isEmpty {
            let lines = detail.documents.map { "\($0.kind) \($0.title)" }
            parts.append("Drafts. " + lines.joined(separator: ". ") + ". These drafts have not been sent or published.")
        }
        return parts.joined(separator: " ")
    }

    static func approvals(_ approvals: [CloudApproval]) -> String {
        if approvals.isEmpty { return "No approvals are stored." }
        let lines = approvals.map { "\($0.id) \($0.status): \($0.summary)" }
        return joined(lines, count: approvals.count)
    }

    static func memory(_ rows: [CloudMemory]) -> String {
        if rows.isEmpty { return "No cloud memory is stored." }
        return joined(rows.map(\.content), count: rows.count)
    }

    static func pipeline(_ rows: [CloudLead]) -> String {
        if rows.isEmpty { return "The pipeline has no rows stored." }
        var counts: [String: Int] = [:]
        for row in rows { counts[row.stage, default: 0] += 1 }
        let bits = CloudStage.order.compactMap { stage -> String? in
            guard let count = counts[stage], count > 0 else { return nil }
            return "\(CloudStage.label(stage)): \(count)"
        }
        let counted: Set<String> = ["won", "active_client"]
        var known = 0.0
        var withFigure = 0
        var missing = 0
        for row in rows where counted.contains(row.stage) {
            if let mrr = row.mrr {
                known += mrr
                withFigure += 1
            } else {
                missing += 1
            }
        }
        let stages = bits.isEmpty ? "No stage counts." : bits.joined(separator: ", ")
        return "Pipeline. \(stages). Known monthly revenue GBP \(format(known)) from won and active clients. \(withFigure) of those rows have a figure. \(missing) have no figure. Null revenue is unknown and is not counted as zero."
    }

    private static func pipelineFacts(_ pipeline: CloudBriefing.Pipeline) -> String {
        let bits = CloudStage.order.compactMap { stage -> String? in
            let count = pipeline.byStage[stage] ?? 0
            guard count > 0 else { return nil }
            return "\(CloudStage.label(stage)): \(count)"
        }
        let stages = bits.isEmpty ? "The pipeline has no rows." : bits.joined(separator: ", ")
        let mrr = pipeline.mrr
        let names = mrr.stagesCounted.map { CloudStage.label($0) }.joined(separator: " and ")
        return "Pipeline. \(stages). Known monthly revenue \(mrr.currency) \(format(mrr.knownTotal)) from \(names). \(mrr.rowsWithMrr) rows have a figure. \(mrr.rowsMissingMrr) have no figure. \(mrr.note)"
    }

    private static func taskLine(_ task: CloudTask) -> String {
        var line = "\(task.status): \(task.goal)"
        if let summary = task.resultSummary, !summary.isEmpty { line += ". \(summary)" }
        if let error = task.error, !error.isEmpty { line += ". \(JarvisLines.explain(error))" }
        return line
    }

    private static func joined(_ lines: [String], count: Int) -> String {
        let shown = lines.prefix(4)
        var text = shown.joined(separator: ". ")
        if count > shown.count { text += ". And \(count - shown.count) more stored." }
        return text
    }

    private static func format(_ value: Double) -> String {
        String(format: "%.2f", value)
    }
}

private struct CloudErrorEnvelope: Decodable {
    struct Inner: Decodable { var code: String; var message: String }
    var error: Inner
}

private struct ListEnvelope<Item: Decodable>: Decodable {
    var tasks: [Item]?
    var approvals: [Item]?
    var memory: [Item]?
    var activity: [Item]?
    var pipeline: [Item]?
}

struct BrainPersona: Decodable, Sendable {
    var persona: String
    var voice: String?
    var voiceID: String?

    enum CodingKeys: String, CodingKey {
        case persona, voice
        case voiceID = "voice_id"
    }
}

struct BrainTurn: Decodable, Sendable {
    var role: String
    var body: String
    var source: String?
}

struct BrainHistory: Decodable, Sendable {
    var revision: String?
    var turns: [BrainTurn]
    var reminders: [String]?
    var voiceID: String?

    enum CodingKeys: String, CodingKey {
        case revision, turns, reminders
        case voiceID = "voice_id"
    }
}

struct BrainSay: Decodable, Sendable {
    var reply: String
    var voiceID: String?

    enum CodingKeys: String, CodingKey {
        case reply
        case voiceID = "voice_id"
    }
}

private struct BrainAck: Decodable {
    var ok: Bool?
}

struct CloudClient: Sendable {
    var base: URL
    var token: String

    func postAgentChat(message: String, conversationId: String) async throws -> AgentPending {
        try await sendJSON(method: "POST", path: "/agent/chat", body: [
            "message": message,
            "conversationId": conversationId,
        ])
    }

    func agentMessages(conversationId: String, since: String) async throws -> [AgentMessage] {
        struct Envelope: Decodable { var messages: [AgentMessage] }
        let envelope: Envelope = try await sendNoBody(
            method: "GET",
            path: "/agent/messages",
            query: [
                URLQueryItem(name: "conversationId", value: conversationId),
                URLQueryItem(name: "since", value: since),
            ]
        )
        return envelope.messages
    }

    func converse(messages: [[String: String]], location: (lat: Double, lon: Double)? = nil) async -> String? {
        do {
            var body: [String: Any] = ["messages": messages]
            if let location {
                body["location"] = ["lat": location.lat, "lon": location.lon]
            }
            let envelope: CloudChatReply = try await sendJSON(method: "POST", path: "/chat", body: body)
            let text = envelope.reply.trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? nil : text
        } catch {
            return nil
        }
    }

    func health() async throws -> CloudHealth {
        let (data, status) = try await raw(method: "GET", path: "/health", authorize: false, body: nil, query: [])
        if let health = try? JSONDecoder().decode(CloudHealth.self, from: data), status == 200 || status == 503 {
            return health
        }
        throw Self.failure(data: data, status: status)
    }

    func tasks(status: String? = nil) async throws -> [CloudTask] {
        try await list(\.tasks, path: "/tasks", query: query(status: status, limit: 50))
    }

    func task(id: String) async throws -> CloudTaskDetail {
        try await decode(path: "/tasks/\(Self.path(id))")
    }

    func createTask(goal: String, schedule: String?) async throws -> CloudTask {
        var body: [String: Any] = ["goal": goal]
        if let schedule, !schedule.isEmpty { body["schedule"] = schedule }
        let envelope: TaskEnvelope = try await sendJSON(method: "POST", path: "/tasks", body: body)
        return envelope.task
    }

    func briefing() async throws -> CloudBriefing {
        try await decode(path: "/briefing")
    }

    /// A short-lived Gemini Live token. The API key stays on the worker.
    func liveTicket() async -> LiveTicketResult {
        do {
            let body = Data("{}".utf8)
            let (data, status) = try await raw(method: "POST", path: "/voice/live-token", authorize: true, body: body, query: [])
            guard (200..<300).contains(status),
                  let ticket = try? JSONDecoder().decode(LiveTicket.self, from: data),
                  ticket.ok,
                  ticket.websocketURL.hasPrefix("wss://"),
                  !ticket.token.isEmpty else {
                return .unavailable(Self.liveFailure(data: data, status: status))
            }
            return .ready(ticket)
        } catch {
            return .unavailable("I can't reach the JARVIS server. Check that the phone is online, then try voice again.")
        }
    }

    private static func liveFailure(data: Data, status: Int) -> String {
        if status == 401 || status == 403 {
            return "The app token was rejected. Open Settings, JARVIS Cloud, paste the worker app token, and tap Save token to Keychain."
        }
        if status == 429 {
            return "Gemini Live is over its free quota. Wait a minute and try again."
        }
        let envelope = try? JSONDecoder().decode(CloudErrorEnvelope.self, from: data)
        let code = envelope?.error.code ?? ""
        let message = envelope?.error.message ?? ""
        if code == "not_configured" || message.contains("GEMINI_API_KEY") {
            return "Gemini is not set up on the JARVIS server."
        }
        if status == 0 {
            return "I can't reach the JARVIS server. Check that the phone is online, then try voice again."
        }
        if (200..<300).contains(status) {
            return "The JARVIS server sent a Live token the app could not read."
        }
        if message.isEmpty {
            return "Gemini Live could not start. Try voice again."
        }
        return String(message.prefix(160))
    }

    /// Turn and barge-in notes. Returns the HTTP status, or 0 when the request never left the phone.
    func postVoiceDebug(events: [[String: String]]) async -> Int {
        guard !events.isEmpty else { return 204 }
        do {
            let body = try JSONSerialization.data(withJSONObject: ["events": events])
            let (_, status) = try await raw(method: "POST", path: "/debug/voice", authorize: true, body: body, query: [])
            return status
        } catch {
            return 0
        }
    }

    /// The one persona the phone line and the app share.
    func brainPersona() async -> BrainPersona? {
        do { return try await sendNoBody(method: "GET", path: "/brain/persona") } catch { return nil }
    }

    /// Texts, calls, and app lines in one history.
    func brainHistory() async -> BrainHistory? {
        do { return try await sendNoBody(method: "GET", path: "/brain/history") } catch { return nil }
    }

    /// Stores the line and answers with the same persona, memory, and tools as the phone line.
    func brainSay(_ text: String) async -> BrainSay? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        do {
            let spoken: BrainSay = try await sendJSON(method: "POST", path: "/brain", body: ["text": String(trimmed.prefix(1000))])
            let reply = spoken.reply.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !reply.isEmpty else { return nil }
            return BrainSay(reply: reply, voiceID: spoken.voiceID)
        } catch {
            return nil
        }
    }

    /// The same write SMS uses, so a spoken app line is on the phone line's memory.
    func brainLine(source: String, role: String, text: String) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        do {
            let _: BrainAck = try await sendJSON(method: "POST", path: "/brain/line", body: [
                "source": source,
                "role": role,
                "text": String(trimmed.prefix(1000)),
            ])
        } catch {}
    }

    /// A reminder both the phone line and the app can read back.
    func brainReminder(text: String, due: String?) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var body: [String: Any] = ["text": String(trimmed.prefix(300))]
        if let due, !due.isEmpty { body["due_at"] = String(due.prefix(40)) }
        do {
            let _: BrainAck = try await sendJSON(method: "POST", path: "/brain/reminders", body: body)
        } catch {}
    }

    func approvals(status: String? = nil) async throws -> [CloudApproval] {
        try await list(\.approvals, path: "/approvals", query: query(status: status, limit: 50))
    }

    func decide(id: String, approve: Bool, reason: String?) async throws -> CloudDecision {
        let path = "/approvals/\(Self.path(id))/\(approve ? "approve" : "reject")"
        if let reason, !reason.isEmpty {
            return try await sendJSON(method: "POST", path: path, body: ["reason": reason])
        }
        return try await sendNoBody(method: "POST", path: path)
    }

    func memory(query: String?) async throws -> [CloudMemory] {
        var items = [URLQueryItem(name: "limit", value: "50")]
        if let query, !query.isEmpty { items.append(URLQueryItem(name: "q", value: query)) }
        return try await list(\.memory, path: "/memory", query: items)
    }

    func createMemory(content: String, key: String?, tags: [String], sourceURLs: [String]) async throws -> CloudMemory {
        var body: [String: Any] = ["content": content, "source_urls": sourceURLs]
        if let key, !key.isEmpty { body["key"] = key }
        if !tags.isEmpty { body["tags"] = tags }
        let envelope: MemoryEnvelope = try await sendJSON(method: "POST", path: "/memory", body: body)
        return envelope.memory
    }

    func deleteMemory(id: String) async throws {
        let _: DeletedEnvelope = try await sendNoBody(method: "DELETE", path: "/memory/\(Self.path(id))")
    }

    func activity() async throws -> [CloudActivity] {
        try await list(\.activity, path: "/activity", query: [URLQueryItem(name: "limit", value: "100")])
    }

    func pipeline(stage: String? = nil) async throws -> [CloudLead] {
        var items = [URLQueryItem(name: "limit", value: "100")]
        if let stage, !stage.isEmpty { items.append(URLQueryItem(name: "stage", value: stage)) }
        return try await list(\.pipeline, path: "/pipeline", query: items)
    }

    func createLead(_ fields: [String: Any]) async throws -> CloudLead {
        let envelope: LeadEnvelope = try await sendJSON(method: "POST", path: "/pipeline", body: fields)
        return envelope.pipeline
    }

    func updateLead(id: String, fields: [String: Any]) async throws -> CloudLead {
        let envelope: LeadEnvelope = try await sendJSON(method: "POST", path: "/pipeline/\(Self.path(id))", body: fields)
        return envelope.pipeline
    }

    private struct TaskEnvelope: Decodable { var task: CloudTask }
    private struct MemoryEnvelope: Decodable { var memory: CloudMemory }
    private struct LeadEnvelope: Decodable { var pipeline: CloudLead }
    private struct DeletedEnvelope: Decodable { var deleted: Bool }

    private func list<Item: Decodable>(_ keyPath: KeyPath<ListEnvelope<Item>, [Item]?>, path: String, query: [URLQueryItem]) async throws -> [Item] {
        let envelope: ListEnvelope<Item> = try await sendNoBody(method: "GET", path: path, query: query)
        return envelope[keyPath: keyPath] ?? []
    }

    private func decode<T: Decodable>(path: String) async throws -> T {
        try await sendNoBody(method: "GET", path: path)
    }

    private func query(status: String?, limit: Int) -> [URLQueryItem] {
        var items = [URLQueryItem(name: "limit", value: String(limit))]
        if let status, !status.isEmpty { items.append(URLQueryItem(name: "status", value: status)) }
        return items
    }

    /// JSON object body. The dictionary is not optional, so a nil literal cannot select this overload.
    private func sendJSON<R: Decodable>(method: String, path: String, query: [URLQueryItem] = [], body: [String: Any]) async throws -> R {
        let data = try JSONSerialization.data(withJSONObject: body)
        return try await sendData(method: method, path: path, query: query, body: data)
    }

    /// No request body. Used by GET and by DELETE, whose JSON reply is still decoded.
    private func sendNoBody<R: Decodable>(method: String, path: String, query: [URLQueryItem] = []) async throws -> R {
        try await sendData(method: method, path: path, query: query, body: nil)
    }

    private func sendData<R: Decodable>(method: String, path: String, query: [URLQueryItem] = [], body: Data?) async throws -> R {
        let (data, status) = try await raw(method: method, path: path, authorize: true, body: body, query: query)
        guard (200..<300).contains(status) else { throw Self.failure(data: data, status: status) }
        do {
            return try JSONDecoder().decode(R.self, from: data)
        } catch {
            throw CloudFailure.http(status, "The reply could not be read.")
        }
    }

    private func raw(method: String, path: String, authorize: Bool, body: Data?, query: [URLQueryItem]) async throws -> (Data, Int) {
        guard var components = URLComponents(url: base, resolvingAgainstBaseURL: false) else { throw CloudFailure.badURL }
        let suffix = path.hasPrefix("/") ? String(path.dropFirst()) : path
        var root = components.path
        if root == "/" { root = "" }
        if !root.isEmpty && !root.hasSuffix("/") && !suffix.isEmpty { root += "/" }
        components.path = root + suffix
        if components.path.isEmpty { components.path = "/" + suffix }
        if !query.isEmpty { components.queryItems = query }
        guard let url = components.url else { throw CloudFailure.badURL }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 45
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if authorize {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw CloudFailure.http(-1, error.localizedDescription)
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        return (data, status)
    }

    private static func failure(data: Data, status: Int) -> CloudFailure {
        if let envelope = try? JSONDecoder().decode(CloudErrorEnvelope.self, from: data) {
            return .http(status, envelope.error.message)
        }
        let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return .http(status, text.isEmpty ? "no details" : String(text.prefix(200)))
    }

    func personaAgents() async throws -> [CloudPersona] {
        let envelope: PersonaListEnvelope = try await sendNoBody(method: "GET", path: "/agents")
        return envelope.agents
    }

    func savePersona(_ agent: CloudPersona, creating: Bool) async throws -> CloudPersona {
        let body: [String: Any] = [
            "id": agent.id,
            "name": agent.name,
            "role": agent.role,
            "instructions": agent.instructions,
            "avatar": agent.avatar,
            "color_hex": agent.colorHex,
            "memory": agent.memory,
            "tools": agent.tools,
            "voice_id": agent.voiceID,
            "voice_name": agent.voiceName,
        ]
        let path = creating ? "/agents" : "/agents/\(Self.path(agent.id))"
        let envelope: PersonaEnvelope = try await sendJSON(method: "POST", path: path, body: body)
        return envelope.agent
    }

    func deletePersona(id: String) async throws {
        let _: DeletedEnvelope = try await sendNoBody(method: "DELETE", path: "/agents/\(Self.path(id))")
    }

    func enqueuePersona(id: String, agentID: String, goal: String) async throws -> CloudPersonaTask {
        let envelope: PersonaTaskEnvelope = try await sendJSON(
            method: "POST", path: "/agent-tasks",
            body: ["id": id, "agent_id": agentID, "goal": goal])
        return envelope.task
    }

    func personaTasks() async throws -> [CloudPersonaTask] {
        let envelope: PersonaTaskListEnvelope = try await sendNoBody(method: "GET", path: "/agent-tasks")
        return envelope.tasks
    }

    func settlePersona(id: String, approve: Bool) async throws {
        let action = approve ? "approve" : "decline"
        let _: PersonaTaskEnvelope = try await sendNoBody(method: "POST", path: "/agent-tasks/\(Self.path(id))/\(action)")
    }

    func personaMessages(agentID: String) async throws -> [CloudGroupLine] {
        let envelope: GroupEnvelope = try await sendNoBody(method: "GET", path: "/agents/\(Self.path(agentID))/messages")
        return envelope.messages
    }

    func addPersonaMessage(agentID: String, author: String, role: String, text: String) async throws {
        let _: AckEnvelope = try await sendJSON(
            method: "POST", path: "/agents/\(Self.path(agentID))/messages",
            body: ["author": author, "role": role, "text": text])
    }

    func groupLines() async throws -> [CloudGroupLine] {
        let envelope: GroupEnvelope = try await sendNoBody(method: "GET", path: "/group")
        return envelope.messages
    }

    func callingConfig() async throws -> CallingConfig {
        try await sendNoBody(method: "GET", path: "/calls/config")
    }

    /// Sends from the Twilio number. The spoken result never includes the destination.
    func sendTwilioSms(to number: String, body: String) async -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: ["to": number, "body": body]) else {
            return "The text was not sent."
        }
        do {
            let (raw, status) = try await raw(method: "POST", path: "/messages/sms", authorize: true, body: data, query: [])
            guard (200..<300).contains(status),
                  let parsed = try? JSONSerialization.jsonObject(with: raw) as? [String: Any] else {
                return "The text was not sent."
            }
            let sid = parsed["sid"] as? String ?? ""
            if parsed["ok"] as? Bool == true, sid.range(of: #"^SM[0-9a-fA-F]{32}$"#, options: .regularExpression) != nil {
                return "The text is sent."
            }
            let error = (parsed["error"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return error.isEmpty ? "The text was not sent." : error
        } catch {
            return "The text was not sent."
        }
    }

    func placeOutboundCall(to number: String, contactName: String, brief: String) async -> CallPlaceResult {
        let body: [String: Any] = ["to": number, "purpose": brief, "contact_name": contactName]
        let data: Data
        do {
            data = try JSONSerialization.data(withJSONObject: body)
        } catch {
            return .failed("The call brief could not be sent.")
        }
        do {
            let (payload, status) = try await raw(method: "POST", path: "/calls/outbound", authorize: true, body: data, query: [])
            if status == 503 { return .notSetUp }
            guard (200..<300).contains(status) else {
                return .failed(JarvisLines.explain(Self.failure(data: payload, status: status)))
            }
            let envelope = try JSONDecoder().decode(CallEnvelope.self, from: payload)
            return .placed(envelope.call)
        } catch let error as CloudFailure {
            if case .http(let code, let message) = error, code == 503 || message.contains("Calling not set up") {
                return .notSetUp
            }
            return .failed(JarvisLines.explain(error))
        } catch {
            return .failed(JarvisLines.explain(error))
        }
    }

    func setAway(_ text: String) async throws -> Bool {
        let body = try JSONSerialization.data(withJSONObject: ["text": text])
        let (payload, status) = try await raw(method: "POST", path: "/calls/away", authorize: true, body: body, query: [])
        guard (200..<300).contains(status) else { return false }
        let parsed = try JSONSerialization.jsonObject(with: payload) as? [String: Any]
        return parsed?["active"] as? Bool ?? false
    }

    func interceptorState() async throws -> InterceptorState {
        try await sendNoBody(method: "GET", path: "/calls/interceptor")
    }

    func setInterceptor(enabled: Bool? = nil, busy: Bool? = nil) async throws -> InterceptorState {
        var body: [String: Any] = [:]
        if let enabled { body["enabled"] = enabled }
        if let busy { body["busy"] = busy }
        return try await sendJSON(method: "POST", path: "/calls/interceptor", body: body)
    }

    func awayStatus() async throws -> (active: Bool, instruction: String) {
        let (payload, status) = try await raw(method: "GET", path: "/calls/away", authorize: true, body: nil, query: [])
        guard (200..<300).contains(status),
              let parsed = try JSONSerialization.jsonObject(with: payload) as? [String: Any] else {
            return (false, "")
        }
        return (parsed["active"] as? Bool ?? false, parsed["instruction"] as? String ?? "")
    }

    func postPresence(activity: String, busy: Bool, lat: Double?, lon: Double?) async {
        var body: [String: Any] = ["activity": activity, "busy": busy]
        if let lat, let lon {
            body["lat"] = lat
            body["lon"] = lon
        }
        guard let data = try? JSONSerialization.data(withJSONObject: body) else { return }
        _ = try? await raw(method: "POST", path: "/calls/presence", authorize: true, body: data, query: [])
    }

    func decideCall(id: String, choice: String) async -> Bool {
        guard let body = try? JSONSerialization.data(withJSONObject: ["choice": choice]) else { return false }
        guard let (payload, status) = try? await raw(method: "POST", path: "/calls/\(Self.path(id))/decide", authorize: true, body: body, query: []) else {
            return false
        }
        return (200..<300).contains(status) && !payload.isEmpty
    }

    func recordingData(id: String) async throws -> Data {
        let (payload, status) = try await raw(method: "GET", path: "/calls/\(Self.path(id))/recording", authorize: true, body: nil, query: [])
        guard (200..<300).contains(status), !payload.isEmpty else { throw CloudFailure.http(status, "No recording yet.") }
        return payload
    }

    func outboundCall(id: String, refresh: Bool = true) async throws -> PhoneCallRecord {
        let query = refresh ? [] : [URLQueryItem(name: "refresh", value: "0")]
        let envelope: CallEnvelope = try await sendNoBody(method: "GET", path: "/calls/\(Self.path(id))", query: query)
        return envelope.call
    }

    func activeInboundCalls() async throws -> [PhoneCallRecord] {
        let envelope: CallListEnvelope = try await sendNoBody(method: "GET", path: "/calls/active")
        return envelope.calls
    }

    func screenCall(id: String, action: String) async -> ScreenResult {
        await postCallAction(path: "/calls/\(Self.path(id))/screen", body: ["action": action])
    }

    func setCallPersonal(id: String, allow: Bool, note: String) async -> ScreenResult {
        await postCallAction(path: "/calls/\(Self.path(id))/personal", body: ["allow": allow, "note": note])
    }

    func registerCallDevice(token: String) async -> ScreenResult {
        await postCallAction(path: "/calls/device", body: ["token": token])
    }

    func replaceCallPermissions(_ rules: [[String: Any]]) async -> ScreenResult {
        await postCallAction(path: "/calls/permissions", body: ["rules": rules])
    }

    func callQuestions() async throws -> [CallQuestion] {
        let envelope: QuestionEnvelope = try await sendNoBody(method: "GET", path: "/calls/questions")
        return envelope.questions
    }

    func answerCallQuestion(callId: String, questionId: String, text: String) async -> ScreenResult {
        await postCallAction(path: "/calls/\(Self.path(callId))/answer", body: ["question_id": questionId, "text": text])
    }

    func ownerCallSettings() async throws -> OwnerCallSettings {
        try await sendNoBody(method: "GET", path: "/calls/settings")
    }

    func saveOwnerCallSettings(_ settings: OwnerCallSettings) async -> ScreenResult {
        await postCallAction(path: "/calls/settings", body: [
            "mobile": settings.mobile,
            "quiet_start": settings.quietStart,
            "quiet_end": settings.quietEnd,
            "max_calls_per_day": settings.maxCallsPerDay,
            "urgent_only": settings.urgentOnly,
            "question_timeout_seconds": settings.questionTimeoutSeconds,
        ])
    }

    func ownerAlerts() async throws -> [OwnerAlert] {
        let envelope: AlertEnvelope = try await sendNoBody(method: "GET", path: "/calls/alerts")
        return envelope.alerts
    }

    func unreadCallMessages() async throws -> [CallMessage] {
        struct Envelope: Decodable { var messages: [CallMessage] }
        let envelope: Envelope = try await sendNoBody(
            method: "GET",
            path: "/calls/messages",
            query: [URLQueryItem(name: "unread", value: "1")]
        )
        return envelope.messages
    }

    func recentCallMessages() async throws -> [CallMessage] {
        struct Envelope: Decodable { var messages: [CallMessage] }
        let envelope: Envelope = try await sendNoBody(method: "GET", path: "/calls/messages")
        return envelope.messages
    }

    func callMessage(id: String) async throws -> CallMessage {
        struct Envelope: Decodable { var message: CallMessage }
        let envelope: Envelope = try await sendNoBody(method: "GET", path: "/calls/messages/\(Self.path(id))")
        return envelope.message
    }

    func markCallMessageRead(id: String) async -> Bool {
        struct Ack: Decodable { var ok: Bool }
        do {
            let ack: Ack = try await sendNoBody(method: "POST", path: "/calls/messages/\(Self.path(id))/read")
            return ack.ok
        } catch {
            return false
        }
    }

    func pairingTicket(refresh: Bool) async throws -> PairingTicket {
        if refresh {
            return try await sendJSON(method: "POST", path: "/calls/pair", body: [String: Any]())
        }
        return try await sendNoBody(method: "GET", path: "/calls/pair")
    }

    func callHunts() async throws -> [CallHunt] {
        let envelope: HuntListEnvelope = try await sendNoBody(method: "GET", path: "/calls/hunts")
        return envelope.hunts
    }

    func chooseHunt(huntID: String, quoteID: String) async -> String? {
        await shopMessage(method: "POST", path: "/calls/hunts/\(Self.path(huntID))/choose", body: ["quote_id": quoteID])
    }

    func createShop(goal: String, providers: [[String: String]]) async throws -> String {
        return try await createShopDraft(goal: goal, providers: providers).message
    }

    /// A draft list. An empty id means no businesses were found and nothing can be rung.
    func createShopDraft(goal: String, providers: [[String: String]]) async throws -> (id: String, message: String) {
        let ack: ShopAck = try await sendJSON(
            method: "POST",
            path: "/calls/hunts",
            body: ["goal": goal, "providers": providers]
        )
        return (ack.huntId ?? "", ack.message ?? "The list is on your phone, Sir.")
    }

    func replaceShop(huntID: String, providers: [[String: String]]) async throws -> String {
        let ack: ShopAck = try await sendJSON(
            method: "POST",
            path: "/calls/hunts/\(Self.path(huntID))/providers",
            body: ["providers": providers]
        )
        return ack.message ?? "The list is updated, Sir."
    }

    func startShop(huntID: String) async throws -> String {
        let ack: ShopAck = try await sendJSON(
            method: "POST",
            path: "/calls/hunts/\(Self.path(huntID))/start",
            body: [String: Any]()
        )
        return ack.message ?? "Calling the first one now, Sir."
    }

    private func shopMessage(method: String, path: String, body: [String: Any]) async -> String? {
        do {
            let ack: ShopAck = try await sendJSON(method: method, path: path, body: body)
            return ack.message
        } catch {
            return nil
        }
    }

    func postBusy(_ blocks: [[String: Any]]) async {
        guard let data = try? JSONSerialization.data(withJSONObject: ["blocks": blocks]) else { return }
        _ = try? await raw(method: "POST", path: "/calendar/busy", authorize: true, body: data, query: [])
    }

    private func postCallAction(path: String, body: [String: Any]) async -> ScreenResult {
        let data: Data
        do {
            data = try JSONSerialization.data(withJSONObject: body)
        } catch {
            return .failed("That request could not be sent.")
        }
        do {
            let (payload, status) = try await raw(method: "POST", path: path, authorize: true, body: data, query: [])
            if status == 503 {
                let message = JarvisLines.explain(Self.failure(data: payload, status: status))
                return .notSetUp(message)
            }
            guard (200..<300).contains(status) else {
                return .failed(JarvisLines.explain(Self.failure(data: payload, status: status)))
            }
            let audio = (try? JSONDecoder().decode(ScreenAck.self, from: payload))?.audio ?? ""
            return .done(audio)
        } catch {
            return .failed(JarvisLines.explain(error))
        }
    }

    func createMission(goal: String) async throws -> CloudMission {
        let envelope: MissionEnvelope = try await sendJSON(method: "POST", path: "/missions", body: ["goal": goal])
        return envelope.mission
    }

    func missions() async throws -> [CloudMission] {
        let envelope: MissionListEnvelope = try await sendNoBody(method: "GET", path: "/missions")
        return envelope.missions
    }

    func routines() async throws -> [CloudRoutine] {
        let envelope: RoutineListEnvelope = try await sendNoBody(method: "GET", path: "/routines")
        return envelope.routines
    }

    func setRoutine(id: String, enabled: Bool) async throws {
        let _: AckEnvelope = try await sendJSON(
            method: "POST", path: "/routines/\(Self.path(id))", body: ["enabled": enabled])
    }

    func postGroupLine(author: String, text: String) async throws {
        let _: AckEnvelope = try await sendJSON(method: "POST", path: "/group", body: ["author": author, "text": text])
    }

    private struct CallEnvelope: Decodable { var call: PhoneCallRecord }
    private struct CallListEnvelope: Decodable { var calls: [PhoneCallRecord] }
    private struct QuestionEnvelope: Decodable { var questions: [CallQuestion] }
    private struct AlertEnvelope: Decodable { var alerts: [OwnerAlert] }
    private struct ScreenAck: Decodable { var audio: String? }
    private struct PersonaListEnvelope: Decodable { var agents: [CloudPersona] }
    private struct PersonaEnvelope: Decodable { var agent: CloudPersona }
    private struct PersonaTaskEnvelope: Decodable { var task: CloudPersonaTask }
    private struct PersonaTaskListEnvelope: Decodable { var tasks: [CloudPersonaTask] }
    private struct GroupEnvelope: Decodable { var messages: [CloudGroupLine] }
    private struct AckEnvelope: Decodable { var ok: Bool? }
    private struct MissionEnvelope: Decodable { var mission: CloudMission }
    private struct MissionListEnvelope: Decodable { var missions: [CloudMission] }
    private struct RoutineListEnvelope: Decodable { var routines: [CloudRoutine] }

    private static func path(_ id: String) -> String {
        id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? id
    }
}

struct CloudPersona: Decodable, Sendable {
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

    enum CodingKeys: String, CodingKey {
        case id, name, role, instructions, avatar, memory, builtin, tools
        case colorHex = "color_hex"
        case voiceID = "voice_id"
        case voiceName = "voice_name"
    }

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

struct CloudMission: Decodable, Sendable {
    var id: String
    var goal: String
    var status: String
    var report: String?
}

struct CloudRoutine: Decodable, Sendable {
    var id: String
    var name: String
    var cron: String
    var enabled: Bool
}

struct CloudPersonaTask: Decodable, Sendable {
    var id: String
    var agentId: String
    var goal: String
    var status: String
    var result: String?
    var approvalSummary: String?

    enum CodingKeys: String, CodingKey {
        case id, goal, status, result
        case agentId = "agent_id"
        case approvalSummary = "approval_summary"
    }
}

struct InterceptorState: Decodable, Sendable {
    var enabled: Bool
    var busy: Bool
}

struct CallingConfig: Decodable, Sendable {
    var configured: Bool
    var message: String
    var missing: [String]
    var fromNumber: String?
    var forwarding: CallingForwarding?
    var screening: ScreeningFlags?
    var assistantWebhook: Bool?
    var texts: String?

    enum CodingKeys: String, CodingKey {
        case configured, message, missing, forwarding, screening, texts
        case fromNumber = "from_number"
        case assistantWebhook = "assistant_webhook"
    }
}

struct CallingForwarding: Decodable, Sendable {
    var unconditional: String
    var noAnswer: String
    var busy: String
    var unreachable: String
    var cancel: String

    enum CodingKeys: String, CodingKey {
        case unconditional, busy, unreachable, cancel
        case noAnswer = "no_answer"
    }
}

struct ScreeningFlags: Decodable, Sendable {
    var mobileSet: Bool
    var push: Bool
    var voip: Bool

    enum CodingKeys: String, CodingKey {
        case push, voip
        case mobileSet = "mobile_set"
    }
}

struct PhoneCallLine: Decodable, Equatable, Sendable {
    var role: String
    var text: String
}

struct PhoneCallRecord: Decodable, Sendable {
    var id: String
    var contactName: String
    var to: String
    var brief: String
    var status: String
    var transcript: [PhoneCallLine]
    var summary: String?
    var error: String?
    var createdAt: String
    var updatedAt: String
    var direction: String?
    var callerName: String?
    var reason: String?
    var personalAllowed: Bool?
    var personalRequested: Bool?
    var decision: String?
    var stage: String?
    var callbackNeeded: Bool?
    var recording: Bool?
    var delegation: CallDelegation?

    var isFinished: Bool { status == "completed" || status == "failed" || status == "declined" }
    var isInbound: Bool { direction == "inbound" }

    enum CodingKeys: String, CodingKey {
        case id, to, brief, status, transcript, summary, error, direction, reason, decision
        case contactName = "contact_name"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case callerName = "caller_name"
        case personalAllowed = "personal_allowed"
        case personalRequested = "personal_requested"
        case stage, recording, delegation
        case callbackNeeded = "callback_needed"
    }
}

struct CallDelegation: Decodable, Sendable {
    var id: String
    var status: String
    var summary: String
    var decision: String?
}

struct CallQuestion: Decodable, Identifiable, Equatable, Sendable {
    var id: String
    var callId: String
    var question: String
    var status: String
    var answer: String?

    enum CodingKeys: String, CodingKey {
        case id, question, status, answer
        case callId = "call_id"
    }
}

struct OwnerCallSettings: Codable, Equatable, Sendable {
    var mobile: String
    var quietStart: String
    var quietEnd: String
    var maxCallsPerDay: Int
    var urgentOnly: Bool
    var questionTimeoutSeconds: Int

    enum CodingKeys: String, CodingKey {
        case mobile
        case quietStart = "quiet_start"
        case quietEnd = "quiet_end"
        case maxCallsPerDay = "max_calls_per_day"
        case urgentOnly = "urgent_only"
        case questionTimeoutSeconds = "question_timeout_seconds"
    }
}

struct CallMessage: Decodable, Identifiable, Equatable, Sendable {
    var id: String
    var callId: String
    var callerName: String
    var summary: String
    var spoken: String
    var calledAt: String
    var read: Bool
    var transcript: [PhoneCallLine]
    var recording: Bool

    enum CodingKeys: String, CodingKey {
        case id, summary, spoken, read, transcript, recording
        case callId = "call_id"
        case callerName = "caller_name"
        case calledAt = "called_at"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        callId = try container.decode(String.self, forKey: .callId)
        callerName = try container.decodeIfPresent(String.self, forKey: .callerName) ?? ""
        summary = try container.decodeIfPresent(String.self, forKey: .summary) ?? ""
        spoken = try container.decodeIfPresent(String.self, forKey: .spoken) ?? ""
        calledAt = try container.decodeIfPresent(String.self, forKey: .calledAt) ?? ""
        read = try container.decodeIfPresent(Bool.self, forKey: .read) ?? false
        transcript = try container.decodeIfPresent([PhoneCallLine].self, forKey: .transcript) ?? []
        recording = try container.decodeIfPresent(Bool.self, forKey: .recording) ?? false
    }
}

struct PairingTicket: Decodable, Equatable, Sendable {
    var code: String
    var expiresAt: String
    var number: String
    var paired: Bool

    enum CodingKeys: String, CodingKey {
        case code, number, paired
        case expiresAt = "expires_at"
    }
}

struct CallQuote: Decodable, Identifiable, Equatable, Sendable {
    var id: String
    var business: String
    var phone: String
    var price: String
    var availability: String
    var fees: String
    var terms: String
    var summary: String
    var status: String
    var recommended: Bool
    var transcript: [PhoneCallLine]

    enum CodingKeys: String, CodingKey {
        case id, business, phone, price, availability, fees, terms, summary, status, recommended, transcript
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        business = try container.decodeIfPresent(String.self, forKey: .business) ?? ""
        phone = try container.decodeIfPresent(String.self, forKey: .phone) ?? ""
        price = try container.decodeIfPresent(String.self, forKey: .price) ?? ""
        availability = try container.decodeIfPresent(String.self, forKey: .availability) ?? ""
        fees = try container.decodeIfPresent(String.self, forKey: .fees) ?? ""
        terms = try container.decodeIfPresent(String.self, forKey: .terms) ?? ""
        summary = try container.decodeIfPresent(String.self, forKey: .summary) ?? ""
        status = try container.decodeIfPresent(String.self, forKey: .status) ?? ""
        recommended = try container.decodeIfPresent(Bool.self, forKey: .recommended) ?? false
        transcript = try container.decodeIfPresent([PhoneCallLine].self, forKey: .transcript) ?? []
    }
}

struct CallHunt: Decodable, Identifiable, Equatable, Sendable {
    var id: String
    var goal: String
    var status: String
    var recommendedId: String
    var quotes: [CallQuote]

    enum CodingKeys: String, CodingKey {
        case id, goal, status, quotes
        case recommendedId = "recommended_id"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        goal = try container.decodeIfPresent(String.self, forKey: .goal) ?? ""
        status = try container.decodeIfPresent(String.self, forKey: .status) ?? ""
        recommendedId = try container.decodeIfPresent(String.self, forKey: .recommendedId) ?? ""
        quotes = try container.decodeIfPresent([CallQuote].self, forKey: .quotes) ?? []
    }
}

private struct ShopAck: Decodable {
    var message: String?
    var huntId: String?

    enum CodingKeys: String, CodingKey {
        case message
        case huntId = "hunt_id"
    }
}

private struct HuntListEnvelope: Decodable {
    var hunts: [CallHunt]
}

struct OwnerAlert: Decodable, Identifiable, Equatable, Sendable {
    var id: String
    var kind: String
    var summary: String
    var detail: String
    var channel: String
    var createdAt: String

    enum CodingKeys: String, CodingKey {
        case id, kind, summary, detail, channel
        case createdAt = "created_at"
    }
}

enum ScreenResult: Sendable {
    case done(String)
    case notSetUp(String)
    case failed(String)
}

enum CallPlaceResult: Sendable {
    case placed(PhoneCallRecord)
    case notSetUp
    case failed(String)
}

struct CloudGroupLine: Decodable, Sendable {
    var id: String
    var author: String
    var text: String
    var role: String?
    var createdAt: String?

    enum CodingKeys: String, CodingKey {
        case id, author, text, role
        case createdAt = "created_at"
    }
}

enum JarvisCloudAPI {
    @MainActor
    static func client() throws -> CloudClient {
        guard let base = JarvisCloud.baseURL(AppSettings.shared.cloudBaseURL),
              let token = KeychainStore.get(.jarvisCloud) else {
            throw CloudFailure.notConfigured
        }
        return CloudClient(base: base, token: token)
    }

    @MainActor
    static func health(url raw: String) async throws -> CloudHealth {
        guard let base = JarvisCloud.baseURL(raw) else { throw CloudFailure.badURL }
        return try await CloudClient(base: base, token: "").health()
    }
}
