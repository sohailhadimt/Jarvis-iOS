import Foundation

/// Cold launch plays once. A return from the background plays again only after five minutes away.
enum StartupSchedule {
    static let resumeGap: TimeInterval = 5 * 60

    private static var backgroundedAt: Date?
    private static var launched = false

    static func noteBackground(_ date: Date = .now) {
        backgroundedAt = date
    }

    /// True for the first claim in this process, and again when the background gap is longer than five minutes.
    static func claim(now: Date = .now) -> Bool {
        if let left = backgroundedAt {
            backgroundedAt = nil
            let away = now.timeIntervalSince(left)
            if !launched {
                launched = true
                return true
            }
            return away > resumeGap
        }
        if launched { return false }
        launched = true
        return true
    }
}
