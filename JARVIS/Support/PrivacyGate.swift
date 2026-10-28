import LocalAuthentication

/// Face ID, or the device passcode when Face ID is unavailable. A phone with neither stays unlocked.
enum PrivacyGate {
    static func canUnlock() -> Bool {
        LAContext().canEvaluatePolicy(.deviceOwnerAuthentication, error: nil)
    }

    static func unlock() async -> Bool {
        let context = LAContext()
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: nil) else { return true }
        return await withCheckedContinuation { continuation in
            context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "Unlock JARVIS") { ok, _ in
                continuation.resume(returning: ok)
            }
        }
    }
}
