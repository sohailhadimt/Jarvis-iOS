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
    static func display(_ iso: String?) -> String {
        guard let iso, !iso.isEmpty else { return "" }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        let date = fractional.date(from: iso) ?? plain.date(from: iso)
        return date?.formatted(date: .abbreviated, time: .shortened) ?? iso
    }
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
        case facts, recommendations, separation
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
                if let error = task.error, !error.isEmpty { line += ". \(error)" }
                return line
            }, count: failed.count))
        }
        let waiting = briefing.facts.pendingApprovals
        if waiting.isEmpty {
            facts.append("No approvals are waiting.")
        } else {
            facts.append("Approvals waiting. " + joined(waiting.map(\.summary), count: waiting.count))
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
                if let error = sub.error, !error.isEmpty { line += ". \(error)" }
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
        if let error = task.error, !error.isEmpty { line += ". \(error)" }
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

struct CloudClient: Sendable {
    var base: URL
    var token: String

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

    private static func path(_ id: String) -> String {
        id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? id
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
