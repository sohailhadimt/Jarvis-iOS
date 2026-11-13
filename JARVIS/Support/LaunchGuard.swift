import Foundation

/// Remembers whether the last session reached the background. A kill mid-session is not shown as a raw crash.
enum LaunchGuard {
    private static let key = "jarvis.cleanExit"

    /// True when the previous session never reached the background. The first launch counts as clean.
    static func consumeRecovery() -> Bool {
        let clean = UserDefaults.standard.object(forKey: key) as? Bool ?? true
        UserDefaults.standard.set(false, forKey: key)
        return !clean
    }

    static func markClean() {
        UserDefaults.standard.set(true, forKey: key)
    }
}
