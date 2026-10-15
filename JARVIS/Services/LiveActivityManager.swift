import ActivityKit
import Foundation

@MainActor
final class LiveActivityManager {
    static let shared = LiveActivityManager()
    private var activity: Activity<JarvisActivityAttributes>?
    private var lastState: JarvisActivityAttributes.ContentState?

    func start(state: JarvisActivityAttributes.ContentState) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        // Clean up anything left over from a previous run.
        for old in Activity<JarvisActivityAttributes>.activities where old.id != activity?.id {
            Task { await old.end(nil, dismissalPolicy: .immediate) }
        }
        guard activity == nil else { return }
        do {
            activity = try Activity.request(
                attributes: JarvisActivityAttributes(sessionName: "JARVIS"),
                content: ActivityContent(state: state, staleDate: nil),
                pushType: nil)
            lastState = state
        } catch {
            print("Live Activity failed: \(error)")
        }
    }

    func update(_ state: JarvisActivityAttributes.ContentState) async {
        guard let activity, state != lastState else { return }
        lastState = state
        await activity.update(ActivityContent(state: state, staleDate: nil))
    }

    func end(finalState: JarvisActivityAttributes.ContentState) async {
        let current = activity
        activity = nil
        lastState = nil
        if let current {
            await current.end(ActivityContent(state: finalState, staleDate: nil), dismissalPolicy: .immediate)
        }
        for old in Activity<JarvisActivityAttributes>.activities {
            await old.end(nil, dismissalPolicy: .immediate)
        }
    }
}
