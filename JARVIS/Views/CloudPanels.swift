import SwiftUI

private let cloudCyan = Color(red: 0, green: 0.898, blue: 0.949)

private extension View {
    func cloudScreen(title: String) -> some View {
        self
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .scrollContentBackground(.hidden)
            .background(Color.black)
            .toolbar(.visible, for: .navigationBar)
            .tint(cloudCyan)
            .foregroundStyle(cloudCyan)
    }
}

private struct CloudNotice: View {
    var text: String

    var body: some View {
        Text(text)
            .font(.footnote)
            .foregroundStyle(.white.opacity(0.55))
            .fixedSize(horizontal: false, vertical: true)
    }
}

struct CloudMemoryGate: View {
    var body: some View {
        if JarvisCloud.isConfigured {
            CloudMemoryView()
        } else {
            MemorySettingsView()
        }
    }
}

// MARK: - Tasks

struct CloudTasksView: View {
    @State private var status = "all"
    @State private var creating = false

    private var tasks: [CloudTask] {
        let rows = CloudMonitor.shared.tasks
        guard status != "all" else { return rows }
        return rows.filter { $0.status == status }
    }

    var body: some View {
        List {
            if !JarvisCloud.isConfigured {
                Section {
                    CloudNotice(text: "The JARVIS cloud isn't configured. Add the backend URL and app token in Settings, JARVIS Cloud.")
                }
            }
            Section {
                Picker("Status", selection: $status) {
                    Text("All").tag("all")
                    Text("Planning").tag("planning")
                    Text("Running").tag("running")
                    Text("Awaiting approval").tag("awaiting_approval")
                    Text("Completed").tag("completed")
                    Text("Failed").tag("failed")
                }
            }
            Section {
                if tasks.isEmpty {
                    CloudNotice(text: JarvisCloud.isConfigured ? "No tasks are stored." : "Nothing is stored here yet.")
                }
                ForEach(tasks) { task in
                    NavigationLink {
                        CloudTaskDetailView(taskID: task.id)
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(task.goal)
                                .font(.body)
                                .foregroundStyle(.white)
                            Text("\(task.status) · \(CloudTime.display(task.updatedAt))")
                                .font(.caption)
                                .foregroundStyle(cloudCyan.opacity(0.7))
                        }
                    }
                }
            }
            Section("On this iPhone") {
                NavigationLink("Phone reminders and calendar") {
                    TasksView()
                }
            }
        }
        .cloudScreen(title: "Tasks")
        .refreshable { await CloudMonitor.shared.refresh() }
        .task { await CloudMonitor.shared.refresh() }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("New") { creating = true }
                    .disabled(!JarvisCloud.isConfigured)
            }
        }
        .sheet(isPresented: $creating) {
            NavigationStack {
                CloudTaskCreateView()
            }
            .presentationBackground(Color.black)
            .preferredColorScheme(.dark)
        }
    }
}

struct CloudTaskDetailView: View {
    var taskID: String
    @State private var detail: CloudTaskDetail?
    @State private var error: String?

    var body: some View {
        List {
            if let error {
                Section { CloudNotice(text: error) }
            }
            if let detail {
                Section("Task") {
                    Text(detail.task.goal).foregroundStyle(.white)
                    Text(detail.task.status)
                    if let schedule = detail.task.schedule, !schedule.isEmpty {
                        Text("Schedule \(schedule)")
                    }
                    if let summary = detail.task.resultSummary, !summary.isEmpty {
                        Text(summary).foregroundStyle(.white.opacity(0.85))
                        CloudNotice(text: "The result summary is the specialist's text. Stored findings are the claims that have sources.")
                    }
                    if let taskError = detail.task.error, !taskError.isEmpty {
                        CloudNotice(text: taskError)
                    }
                }
                Section("Subtasks") {
                    if detail.subtasks.isEmpty {
                        CloudNotice(text: "No subtasks are stored.")
                    }
                    ForEach(detail.subtasks) { sub in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(sub.title).foregroundStyle(.white)
                            Text("\(sub.agent) · \(sub.status) · \(sub.actionLevel)")
                                .font(.caption)
                            if !sub.instruction.isEmpty {
                                Text(sub.instruction).font(.footnote).foregroundStyle(.white.opacity(0.75))
                            }
                            if let summary = sub.resultSummary, !summary.isEmpty {
                                Text(summary).font(.footnote)
                            }
                            if let subError = sub.error, !subError.isEmpty {
                                CloudNotice(text: subError)
                            }
                        }
                    }
                }
                Section("Progress") {
                    if detail.progress.isEmpty {
                        CloudNotice(text: "No progress is stored.")
                    }
                    ForEach(detail.progress) { row in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(row.message).foregroundStyle(.white)
                            Text("\(row.level) · \(CloudTime.display(row.createdAt))")
                                .font(.caption)
                        }
                    }
                }
                Section("Findings") {
                    if detail.findings.isEmpty {
                        CloudNotice(text: "No findings are stored.")
                    }
                    ForEach(detail.findings) { finding in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(finding.claim).foregroundStyle(.white)
                            if let excerpt = finding.excerpt, !excerpt.isEmpty {
                                Text(excerpt).font(.footnote).foregroundStyle(.white.opacity(0.7))
                            }
                            ForEach(Array(finding.sourceUrls.enumerated()), id: \.offset) { _, raw in
                                if let url = URL(string: raw) {
                                    Link(raw, destination: url).font(.caption)
                                } else {
                                    Text(raw).font(.caption)
                                }
                            }
                        }
                    }
                }
                Section("Drafts") {
                    CloudNotice(text: "A document is a stored draft. It has not been sent or published.")
                    if detail.documents.isEmpty {
                        CloudNotice(text: "No drafts are stored.")
                    }
                    ForEach(detail.documents) { document in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(document.title).foregroundStyle(.white)
                            Text(document.kind).font(.caption)
                            Text(document.body).font(.footnote).foregroundStyle(.white.opacity(0.8)).textSelection(.enabled)
                            ForEach(Array(document.sourceUrls.enumerated()), id: \.offset) { _, raw in
                                if let url = URL(string: raw) {
                                    Link(raw, destination: url).font(.caption)
                                }
                            }
                        }
                    }
                }
            }
        }
        .cloudScreen(title: "Task")
        .refreshable { await load() }
        .task { await load() }
    }

    private func load() async {
        do {
            detail = try await JarvisCloudAPI.client().task(id: taskID)
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }
}

struct CloudTaskCreateView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var goal = ""
    @State private var schedule = ""
    @State private var error: String?
    @State private var busy = false

    var body: some View {
        Form {
            Section {
                TextField("Goal", text: $goal, axis: .vertical)
                    .lineLimit(3...8)
                TextField("UTC cron, optional", text: $schedule)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            } footer: {
                Text("Leave the schedule empty to run once. A schedule is five UTC fields. The task still runs once now, then on that cron.")
            }
            if let error {
                Section { CloudNotice(text: error) }
            }
            Section {
                Button(busy ? "Creating…" : "Create task") { submit() }
                    .disabled(busy || goal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .cloudScreen(title: "New task")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Close") { dismiss() }
            }
        }
    }

    private func submit() {
        busy = true
        error = nil
        let goal = goal.trimmingCharacters(in: .whitespacesAndNewlines)
        let schedule = schedule.trimmingCharacters(in: .whitespacesAndNewlines)
        Task {
            defer { busy = false }
            do {
                _ = try await JarvisCloudAPI.client().createTask(goal: goal, schedule: schedule.isEmpty ? nil : schedule)
                await CloudMonitor.shared.refresh()
                dismiss()
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}

// MARK: - Approvals

struct CloudApprovalsView: View {
    @Environment(AssistantEngine.self) private var engine
    @State private var status = "pending"
    @State private var error: String?

    private var rows: [CloudApproval] {
        CloudMonitor.shared.approvals.filter { status == "all" || $0.status == status }
    }

    var body: some View {
        List {
            if engine.pendingCallBrief != nil {
                Section("Call") {
                    CallBriefBar()
                }
            }
            if let summary = engine.pendingSummary {
                Section("On this iPhone") {
                    ConfirmBar(summary: summary,
                               onConfirm: { engine.confirmPendingAction() },
                               onCancel: { engine.cancelPendingAction() })
                }
            }
            if !JarvisCloud.isConfigured {
                Section {
                    CloudNotice(text: "The JARVIS cloud isn't configured. Add the backend URL and app token in Settings, JARVIS Cloud.")
                }
            }
            Section {
                Picker("Status", selection: $status) {
                    Text("Pending").tag("pending")
                    Text("Approved").tag("approved")
                    Text("Rejected").tag("rejected")
                    Text("All").tag("all")
                }
            } footer: {
                Text("Approving records the decision. Nothing is emailed, published or paid.")
            }
            if let error {
                Section { CloudNotice(text: error) }
            }
            Section {
                if rows.isEmpty {
                    CloudNotice(text: "No approvals are stored for this filter.")
                }
                ForEach(rows) { approval in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(approval.summary).foregroundStyle(.white)
                        Text("\(approval.status) · \(approval.level) · \(CloudTime.display(approval.createdAt))")
                            .font(.caption)
                        if let reason = approval.reason, !reason.isEmpty {
                            Text(reason).font(.footnote)
                        }
                        if approval.status == "pending" {
                            HStack {
                                Button("Reject") { decide(approval, approve: false) }
                                    .buttonStyle(.bordered)
                                Button("Approve") { decide(approval, approve: true) }
                                    .buttonStyle(.borderedProminent)
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .cloudScreen(title: "Approvals")
        .refreshable { await CloudMonitor.shared.refresh() }
        .task { await CloudMonitor.shared.refresh() }
    }

    private func decide(_ approval: CloudApproval, approve: Bool) {
        error = nil
        Task {
            do {
                let decision = try await JarvisCloudAPI.client().decide(id: approval.id, approve: approve, reason: nil)
                await CloudMonitor.shared.refresh()
                error = decision.externalActionTaken
                    ? "Recorded. An external action was taken."
                    : "Recorded. Nothing was sent."
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}

// MARK: - Memory

struct CloudMemoryView: View {
    @State private var query = ""
    @State private var rows: [CloudMemory] = []
    @State private var error: String?
    @State private var adding = false

    var body: some View {
        List {
            Section {
                TextField("Search", text: $query)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .onSubmit { Task { await load() } }
                Button("Search") { Task { await load() } }
            }
            if let error {
                Section { CloudNotice(text: error) }
            }
            Section {
                if rows.isEmpty {
                    CloudNotice(text: "No cloud memory is stored.")
                }
                ForEach(rows) { row in
                    VStack(alignment: .leading, spacing: 4) {
                        if let key = row.key, !key.isEmpty {
                            Text(key).font(.caption)
                        }
                        Text(row.content).foregroundStyle(.white)
                        if !row.tags.isEmpty {
                            Text(row.tags.joined(separator: ", ")).font(.caption)
                        }
                    }
                }
                .onDelete { offsets in
                    let ids = offsets.map { rows[$0].id }
                    Task { await remove(ids) }
                }
            }
        }
        .cloudScreen(title: "Memory")
        .refreshable { await load() }
        .task { await load() }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Add") { adding = true }
            }
        }
        .sheet(isPresented: $adding) {
            NavigationStack { CloudMemoryEditor { Task { await load() } } }
                .presentationBackground(Color.black)
                .preferredColorScheme(.dark)
        }
    }

    private func load() async {
        do {
            let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
            rows = try await JarvisCloudAPI.client().memory(query: trimmed.isEmpty ? nil : trimmed)
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func remove(_ ids: [String]) async {
        do {
            let client = try JarvisCloudAPI.client()
            for id in ids {
                try await client.deleteMemory(id: id)
            }
            await CloudMonitor.shared.refresh()
            await load()
        } catch {
            self.error = error.localizedDescription
        }
    }
}

struct CloudMemoryEditor: View {
    var onSaved: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var content = ""
    @State private var key = ""
    @State private var tags = ""
    @State private var error: String?
    @State private var busy = false

    var body: some View {
        Form {
            TextField("Content", text: $content, axis: .vertical)
                .lineLimit(3...8)
            TextField("Key, optional", text: $key)
            TextField("Tags, comma separated", text: $tags)
            if let error { CloudNotice(text: error) }
            Button(busy ? "Saving…" : "Save") { save() }
                .disabled(busy || content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .cloudScreen(title: "Add memory")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Close") { dismiss() }
            }
        }
    }

    private func save() {
        busy = true
        error = nil
        let content = content.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = key.trimmingCharacters(in: .whitespacesAndNewlines)
        let tags = tags.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        Task {
            defer { busy = false }
            do {
                _ = try await JarvisCloudAPI.client().createMemory(
                    content: content,
                    key: key.isEmpty ? nil : key,
                    tags: tags,
                    sourceURLs: [])
                await CloudMonitor.shared.refresh()
                onSaved()
                dismiss()
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}

// MARK: - Activity

struct CloudActivityView: View {
    var body: some View {
        List {
            if !JarvisCloud.isConfigured {
                Section {
                    CloudNotice(text: "The JARVIS cloud isn't configured. Add the backend URL and app token in Settings, JARVIS Cloud.")
                }
            }
            Section {
                if CloudMonitor.shared.activity.isEmpty {
                    CloudNotice(text: "No activity is stored.")
                }
                ForEach(CloudMonitor.shared.activity) { row in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(row.action).foregroundStyle(.white)
                        Text("\(row.actor) · \(CloudTime.display(row.createdAt))")
                            .font(.caption)
                        if let taskID = row.taskId, !taskID.isEmpty {
                            Text(taskID).font(.caption2).foregroundStyle(.white.opacity(0.55))
                        }
                    }
                }
            }
        }
        .cloudScreen(title: "Activity")
        .refreshable { await CloudMonitor.shared.refresh() }
        .task { await CloudMonitor.shared.refresh() }
    }
}

// MARK: - Business

struct CloudBusinessView: View {
    var body: some View {
        List {
            if !JarvisCloud.isConfigured {
                Section {
                    CloudNotice(text: "The JARVIS cloud isn't configured. Add the backend URL and app token in Settings, JARVIS Cloud.")
                }
            }
            Section("Monthly revenue") {
                Text(revenueLine)
                    .foregroundStyle(.white)
                    .font(.footnote)
                CloudNotice(text: "Null revenue is unknown. It is not counted as zero. Only won and active client rows are included.")
            }
            ForEach(CloudStage.order, id: \.self) { stage in
                let rows = CloudMonitor.shared.pipeline.filter { $0.stage == stage }
                if !rows.isEmpty {
                    Section("\(CloudStage.label(stage)) · \(rows.count)") {
                        ForEach(rows) { lead in
                            NavigationLink {
                                CloudLeadEditor(existing: lead)
                            } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(lead.company).foregroundStyle(.white)
                                    Text(leadLine(lead)).font(.caption)
                                }
                            }
                        }
                    }
                }
            }
            if CloudMonitor.shared.pipeline.isEmpty {
                Section {
                    CloudNotice(text: "The pipeline has no rows stored.")
                }
            }
        }
        .cloudScreen(title: "Business")
        .refreshable { await CloudMonitor.shared.refresh() }
        .task { await CloudMonitor.shared.refresh() }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                NavigationLink("Add") { CloudLeadEditor(existing: nil) }
                    .disabled(!JarvisCloud.isConfigured)
            }
        }
    }

    private var revenueLine: String {
        let counted: Set<String> = ["won", "active_client"]
        var known = 0.0
        var withFigure = 0
        var missing = 0
        for row in CloudMonitor.shared.pipeline where counted.contains(row.stage) {
            if let mrr = row.mrr {
                known += mrr
                withFigure += 1
            } else {
                missing += 1
            }
        }
        return "Known MRR £\(String(format: "%.2f", known)) from won and active clients. \(withFigure) rows have a figure. \(missing) have no figure."
    }

    private func leadLine(_ lead: CloudLead) -> String {
        var bits = [CloudStage.label(lead.stage)]
        if let mrr = lead.mrr {
            bits.append("£\(String(format: "%.2f", mrr))/month")
        } else {
            bits.append("revenue unknown")
        }
        if let name = lead.contactName, !name.isEmpty { bits.append(name) }
        return bits.joined(separator: " · ")
    }
}

struct CloudLeadEditor: View {
    var existing: CloudLead?
    @Environment(\.dismiss) private var dismiss
    @State private var company: String
    @State private var contactName: String
    @State private var contactEmail: String
    @State private var website: String
    @State private var stage: String
    @State private var mrrText: String
    @State private var notes: String
    @State private var sources: String
    @State private var error: String?
    @State private var busy = false

    init(existing: CloudLead?) {
        self.existing = existing
        _company = State(initialValue: existing?.company ?? "")
        _contactName = State(initialValue: existing?.contactName ?? "")
        _contactEmail = State(initialValue: existing?.contactEmail ?? "")
        _website = State(initialValue: existing?.website ?? "")
        _stage = State(initialValue: existing?.stage ?? "prospect")
        _notes = State(initialValue: existing?.notes ?? "")
        _sources = State(initialValue: existing?.sourceUrls.joined(separator: "\n") ?? "")
        if let mrr = existing?.mrr {
            _mrrText = State(initialValue: mrr.rounded() == mrr ? String(Int(mrr)) : String(mrr))
        } else {
            _mrrText = State(initialValue: "")
        }
    }

    var body: some View {
        Form {
            Section {
                TextField("Company", text: $company)
                TextField("Contact name", text: $contactName)
                TextField("Contact email", text: $contactEmail)
                    .textInputAutocapitalization(.never)
                    .keyboardType(.emailAddress)
                TextField("Website", text: $website)
                    .textInputAutocapitalization(.never)
                    .keyboardType(.URL)
                Picker("Stage", selection: $stage) {
                    ForEach(CloudStage.order, id: \.self) { item in
                        Text(CloudStage.label(item)).tag(item)
                    }
                }
                TextField("Monthly revenue, pounds", text: $mrrText)
                    .keyboardType(.decimalPad)
                TextField("Notes", text: $notes, axis: .vertical)
                    .lineLimit(2...6)
                TextField("Source URLs, one per line", text: $sources, axis: .vertical)
                    .lineLimit(3...8)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            } footer: {
                Text("A company and at least one public http or https source are required. Leave monthly revenue empty when it is unknown. Empty is not zero.")
            }
            if let error {
                Section { CloudNotice(text: error) }
            }
            Section {
                Button(busy ? "Saving…" : "Save") { save() }
                    .disabled(busy)
            }
        }
        .cloudScreen(title: existing == nil ? "New lead" : "Lead")
    }

    private func save() {
        error = nil
        let company = company.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !company.isEmpty else {
            error = "A company is required."
            return
        }
        let urls = sources.split(whereSeparator: \.isNewline).map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }.filter { !$0.isEmpty }
        guard !urls.isEmpty, urls.allSatisfy(Self.isHTTP) else {
            error = "Add at least one http or https source URL."
            return
        }
        let site = website.trimmingCharacters(in: .whitespacesAndNewlines)
        if !site.isEmpty && !Self.isHTTP(site) {
            error = "The website needs to be an http or https URL."
            return
        }
        var fields: [String: Any] = [
            "company": company,
            "stage": stage,
            "source_urls": urls,
        ]
        let mrrTrimmed = mrrText.trimmingCharacters(in: .whitespacesAndNewlines)
        if mrrTrimmed.isEmpty {
            fields["mrr"] = NSNull()
        } else if let value = Double(mrrTrimmed.replacingOccurrences(of: ",", with: "")), value >= 0 {
            fields["mrr"] = value
        } else {
            error = "Monthly revenue must be a number in pounds, or left empty if it is unknown."
            return
        }
        let name = contactName.trimmingCharacters(in: .whitespacesAndNewlines)
        let email = contactEmail.trimmingCharacters(in: .whitespacesAndNewlines)
        let note = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        if !name.isEmpty { fields["contact_name"] = name }
        if !email.isEmpty { fields["contact_email"] = email }
        if !site.isEmpty { fields["website"] = site }
        if !note.isEmpty { fields["notes"] = note }
        busy = true
        let existingID = existing?.id
        Task {
            defer { busy = false }
            do {
                let client = try JarvisCloudAPI.client()
                if let existingID {
                    _ = try await client.updateLead(id: existingID, fields: fields)
                } else {
                    _ = try await client.createLead(fields)
                }
                await CloudMonitor.shared.refresh()
                dismiss()
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    private static func isHTTP(_ raw: String) -> Bool {
        guard let url = URL(string: raw), let scheme = url.scheme?.lowercased() else { return false }
        return scheme == "http" || scheme == "https"
    }
}

// MARK: - Briefing

struct CloudBriefingView: View {
    @State private var briefing: CloudBriefing?
    @State private var error: String?

    var body: some View {
        List {
            if !JarvisCloud.isConfigured {
                Section {
                    CloudNotice(text: "The JARVIS cloud isn't configured. Add the backend URL and app token in Settings, JARVIS Cloud.")
                }
            }
            if let error {
                Section { CloudNotice(text: error) }
            }
            if let briefing {
                Section {
                    Text(briefing.separation)
                        .font(.footnote)
                        .foregroundStyle(.white.opacity(0.7))
                    Text("Generated \(CloudTime.display(briefing.generatedAt))")
                        .font(.caption)
                }
                Section("Facts") {
                    factBlock("Completed", briefing.facts.completedTasks.map(\.goal), empty: "No completed tasks are stored in the window.")
                    factBlock("Failed", briefing.facts.failedTasks.map { task in
                        task.error.map { "\(task.goal). \($0)" } ?? task.goal
                    }, empty: "No failed tasks are stored in the window.")
                    factBlock("Approvals waiting", briefing.facts.pendingApprovals.map(\.summary), empty: "No approvals are waiting.")
                    factBlock("Findings", briefing.facts.results.findings.map { finding in
                        finding.sourceUrls.isEmpty ? finding.claim : "\(finding.claim) \(finding.sourceUrls.joined(separator: ", "))"
                    }, empty: "No findings were stored in that window.")
                    if briefing.facts.results.documents.isEmpty {
                        CloudNotice(text: "No drafts were stored in that window.")
                    } else {
                        ForEach(briefing.facts.results.documents) { document in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(document.title).foregroundStyle(.white)
                                Text(document.kind).font(.caption)
                            }
                        }
                        CloudNotice(text: "These are stored drafts. They have not been sent or published.")
                    }
                    Text(pipelineText(briefing.facts.pipeline))
                        .font(.footnote)
                        .foregroundStyle(.white)
                }
                Section("Recommendations") {
                    if briefing.recommendations.isEmpty {
                        CloudNotice(text: "No recommendations were returned.")
                    }
                    ForEach(briefing.recommendations) { item in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(item.text).foregroundStyle(.white)
                            if !item.basedOn.isEmpty {
                                Text(item.basedOn.joined(separator: ", "))
                                    .font(.caption2)
                                    .foregroundStyle(.white.opacity(0.45))
                            }
                        }
                    }
                    CloudNotice(text: "A recommendation is a suggestion drawn from the stored rows. It is not an extra fact.")
                }
            }
        }
        .cloudScreen(title: "Briefing")
        .refreshable { await load() }
        .task { await load() }
    }

    private func factBlock(_ title: String, _ lines: [String], empty: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption.weight(.semibold))
            if lines.isEmpty {
                CloudNotice(text: empty)
            } else {
                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                    Text(line).foregroundStyle(.white)
                }
            }
        }
        .padding(.vertical, 4)
    }

    private func pipelineText(_ pipeline: CloudBriefing.Pipeline) -> String {
        let bits = CloudStage.order.compactMap { stage -> String? in
            let count = pipeline.byStage[stage] ?? 0
            guard count > 0 else { return nil }
            return "\(CloudStage.label(stage)): \(count)"
        }
        let stages = bits.isEmpty ? "The pipeline has no rows." : bits.joined(separator: ", ")
        let mrr = pipeline.mrr
        return "\(stages). Known monthly revenue \(mrr.currency) \(String(format: "%.2f", mrr.knownTotal)). \(mrr.rowsWithMrr) rows have a figure. \(mrr.rowsMissingMrr) have no figure. \(mrr.note)"
    }

    private func load() async {
        guard JarvisCloud.isConfigured else { return }
        do {
            briefing = try await JarvisCloudAPI.client().briefing()
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }
}
