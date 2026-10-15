import ActivityKit
import Foundation

/// Live Activity updates run in nonisolated helpers. `Activity` is not Sendable, so a
/// main-actor-isolated value must not be passed into `update` / `end` or into a `Task`.
@MainActor
final class LiveActivityManager {
    static let shared = LiveActivityManager()
    private var activityID: String?
    private var lastState: JarvisActivityAttributes.ContentState?

    func start(state: JarvisActivityAttributes.ContentState) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        // Snapshot ids first. The dismissal task must not see the activity this call is about to request.
        let keepID = activityID
        let staleIDs = Self.activityIDs(except: keepID)
        if !staleIDs.isEmpty {
            Task { await Self.dismiss(ids: staleIDs, finalState: nil) }
        }
        guard activityID == nil else { return }
        do {
            activityID = try Self.requestActivity(state: state)
            lastState = state
        } catch {
            print("Live Activity failed: \(error)")
        }
    }

    func update(_ state: JarvisActivityAttributes.ContentState) async {
        guard let activityID, state != lastState else { return }
        lastState = state
        await Self.pushUpdate(id: activityID, state: state)
    }

    func end(finalState: JarvisActivityAttributes.ContentState) async {
        let endingID = activityID
        activityID = nil
        lastState = nil
        await Self.dismiss(ids: Self.activityIDs(except: nil), finalFor: endingID, finalState: finalState)
    }

    private nonisolated static func activityIDs(except keepID: String?) -> [String] {
        Activity<JarvisActivityAttributes>.activities.map(\.id).filter { $0 != keepID }
    }

    private nonisolated static func requestActivity(state: JarvisActivityAttributes.ContentState) throws -> String {
        let activity = try Activity.request(
            attributes: JarvisActivityAttributes(sessionName: "JARVIS"),
            content: ActivityContent(state: state, staleDate: nil),
            pushType: nil)
        return activity.id
    }

    private nonisolated static func pushUpdate(id: String, state: JarvisActivityAttributes.ContentState) async {
        guard let activity = Activity<JarvisActivityAttributes>.activities.first(where: { $0.id == id }) else { return }
        await activity.update(ActivityContent(state: state, staleDate: nil))
    }

    private nonisolated static func dismiss(ids: [String],
                                            finalFor endingID: String? = nil,
                                            finalState: JarvisActivityAttributes.ContentState? = nil) async {
        let ending = Set(ids)
        for activity in Activity<JarvisActivityAttributes>.activities where ending.contains(activity.id) {
            if activity.id == endingID, let finalState {
                await activity.end(ActivityContent(state: finalState, staleDate: nil), dismissalPolicy: .immediate)
            } else {
                await activity.end(nil, dismissalPolicy: .immediate)
            }
        }
    }
}
