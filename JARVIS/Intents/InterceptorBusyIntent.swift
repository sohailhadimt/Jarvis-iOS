import AppIntents
import Foundation

/// Focus filter. Turning the Focus on marks JARVIS busy so forwarded calls are answered.
/// No App Shortcut phrase: a duplicate phrase drops the whole JarvisShortcuts list.
struct InterceptorBusyFilter: SetFocusFilterIntent {
    static var title: LocalizedStringResource { "JARVIS Busy mode" }
    static var description: IntentDescription {
        IntentDescription("While this Focus is on, JARVIS answers calls forwarded from your mobile.")
    }
    static var openAppWhenRun: Bool = false

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "Busy mode", subtitle: "Answer forwarded calls")
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        await InterceptorSync.focusDidTurnOn()
        return .result()
    }
}

/// Shortcuts action. Discoverable, and deliberately not an App Shortcut phrase.
struct SetJarvisBusyIntent: AppIntent {
    static var title: LocalizedStringResource { "Set JARVIS busy mode" }
    static var description: IntentDescription {
        IntentDescription("Turns JARVIS busy mode on or off. A Focus filter can do the same.")
    }
    static var openAppWhenRun: Bool = false

    @Parameter(title: "Busy")
    var busy: Bool

    init() {
        busy = false
    }

    init(busy: Bool) {
        self.busy = busy
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        await InterceptorSync.setBusy(busy, fromFocus: false)
        return .result()
    }
}

/// Keeps the worker's busy flag aligned with the Focus filter.
/// The filter's perform runs when the Focus turns on. iOS does not call it again when the Focus ends,
/// so the next time the app is active we read the filter and clear busy if that Focus had set it.
@MainActor
enum InterceptorSync {
    static let focusKey = "jarvis.busyFromFocus"

    static func focusDidTurnOn() async {
        await setBusy(true, fromFocus: true)
    }

    @discardableResult
    static func setBusy(_ busy: Bool, fromFocus: Bool) async -> Bool {
        if fromFocus {
            UserDefaults.standard.set(busy, forKey: focusKey)
        } else if !busy {
            UserDefaults.standard.set(false, forKey: focusKey)
        }
        AssistantEngine.shared.setBusyMode(busy)
        guard let client = try? JarvisCloudAPI.client() else { return false }
        do {
            _ = try await client.setInterceptor(busy: busy)
            return true
        } catch {
            return false
        }
    }

    static func reconcile() async {
        if (try? await InterceptorBusyFilter.current) != nil {
            await setBusy(true, fromFocus: true)
            return
        }
        if UserDefaults.standard.bool(forKey: focusKey) {
            await setBusy(false, fromFocus: false)
        }
    }
}
