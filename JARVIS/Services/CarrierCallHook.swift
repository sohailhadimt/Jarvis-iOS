import Foundation

/// Later hook for a carrier call such as Twilio. It stays off.
/// Calls on this iPhone still use tel://. Messages and email open for the user to tap Send.
enum CarrierCallHook {
    static let enabled = false

    static func place(to number: String) -> String {
        let digits = number
        if digits.isEmpty { return "Carrier calls are not connected." }
        return "Carrier calls are not connected."
    }
}
