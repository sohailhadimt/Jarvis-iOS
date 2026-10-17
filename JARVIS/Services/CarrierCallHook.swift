import Foundation

/// Plain "call X" stays on tel://. This hook stays off.
/// "call X and tell them Y" is a separate brief: JARVIS asks for a yes, then the worker dials.
/// Messages and email still open for the user to tap Send.
enum CarrierCallHook {
    static let enabled = false

    static func place(to number: String) -> String {
        let digits = number
        if digits.isEmpty { return "Carrier calls are not connected." }
        return "Carrier calls are not connected."
    }
}
