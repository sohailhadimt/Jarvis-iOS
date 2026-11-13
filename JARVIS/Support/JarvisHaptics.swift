import UIKit

/// Short taps for buttons and the drawer. Never call this from a display-link frame.
@MainActor
enum JarvisHaptics {
    private static let soft = UIImpactFeedbackGenerator(style: .soft)
    private static let firm = UIImpactFeedbackGenerator(style: .rigid)

    static func tap() {
        guard AppSettings.shared.hapticsEnabled else { return }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    static func success() {
        guard AppSettings.shared.hapticsEnabled else { return }
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }

    static func prepareStartup() {
        guard AppSettings.shared.hapticsEnabled else { return }
        soft.prepare()
        firm.prepare()
    }

    /// Quiet ticks while the boot lines appear. Call from the start-up clock, not a display link.
    static func tick() {
        guard AppSettings.shared.hapticsEnabled else { return }
        soft.impactOccurred(intensity: 0.4)
    }

    static func strike() {
        guard AppSettings.shared.hapticsEnabled else { return }
        firm.impactOccurred(intensity: 0.95)
    }
}
