import Foundation
import Observation
import UserNotifications

/// Foreground poll of the JARVIS cloud. The first successful fetch only records what is already stored.
@MainActor
@Observable
final class CloudMonitor {
    static let shared = CloudMonitor()

    private(set) var tasks: [CloudTask] = []
    private(set) var approvals: [CloudApproval] = []
    private(set) var activity: [CloudActivity] = []
    private(set) var pipeline: [CloudLead] = []
    private(set) var memory: [CloudMemory] = []
    private(set) var briefing: CloudBriefing?
    private(set) var lastRefresh: Date?
    private(set) var lastError: String?

    var hasRunningWork: Bool {
        tasks.contains { $0.status == "planning" || $0.status == "running" }
    }

    @ObservationIgnored private var poll: Task<Void, Never>?
    @ObservationIgnored private var refreshing = false
    @ObservationIgnored private var queued = false
    @ObservationIgnored private var seeded = false
    @ObservationIgnored private var seenCompleted: Set<String> = []
    @ObservationIgnored private var seenPending: Set<String> = []

    private init() {}

    /// Starts a refresh now and every 60 seconds while the app is visible and the cloud is configured.
    func setVisible(_ visible: Bool) {
        poll?.cancel()
        poll = nil
        guard visible, JarvisCloud.isConfigured else { return }
        poll = Task { [weak self] in
            guard let self else { return }
            await self.refresh()
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                if Task.isCancelled { break }
                await self.refresh()
            }
        }
    }

    func refresh() async {
        guard JarvisCloud.isConfigured else { return }
        if refreshing {
            queued = true
            return
        }
        refreshing = true
        defer {
            refreshing = false
            if queued {
                queued = false
                Task { await self.refresh() }
            }
        }
        do {
            let client = try JarvisCloudAPI.client()
            let tasks = try await client.tasks()
            let pending = try await client.approvals(status: "pending")
            let recent = try await client.approvals()
            let activity = try await client.activity()
            let pipeline = try await client.pipeline()
            self.tasks = tasks
            self.approvals = Self.merge(pending, recent)
            self.activity = activity
            self.pipeline = pipeline
            lastRefresh = Date()
            lastError = nil
            noteChanges(tasks: tasks, pending: pending)
            if let briefing = try? await client.briefing() {
                self.briefing = briefing
            }
            if let memory = try? await client.memory(query: nil) {
                self.memory = memory
            }
        } catch {
            lastError = JarvisLines.explain(error)
        }
    }

    private static func merge(_ first: [CloudApproval], _ second: [CloudApproval]) -> [CloudApproval] {
        var seen = Set<String>()
        return (first + second).filter { seen.insert($0.id).inserted }
    }

    private func noteChanges(tasks: [CloudTask], pending pendingRows: [CloudApproval]) {
        let completed = Set(tasks.filter { $0.status == "completed" }.map(\.id))
        let pending = Set(pendingRows.map(\.id))
        if !seeded {
            seenCompleted = completed
            seenPending = pending
            seeded = true
            return
        }
        for task in tasks where task.status == "completed" && !seenCompleted.contains(task.id) {
            notify(id: "task-\(task.id)", body: "Task completed: \(task.goal)")
        }
        for approval in approvals where approval.status == "pending" && !seenPending.contains(approval.id) {
            notify(id: "approval-\(approval.id)", body: "Approval waiting: \(approval.summary)")
        }
        seenCompleted = completed
        seenPending = pending
    }

    private func notify(id: String, body: String) {
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            switch settings.authorizationStatus {
            case .notDetermined:
                center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
                    guard granted else { return }
                    Self.deliver(id: id, body: body)
                }
            case .authorized, .provisional, .ephemeral:
                Self.deliver(id: id, body: body)
            case .denied:
                break
            @unknown default:
                break
            }
        }
    }

    nonisolated private static func deliver(id: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = "JARVIS"
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(identifier: id, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}
