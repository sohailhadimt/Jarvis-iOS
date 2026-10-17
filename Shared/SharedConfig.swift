import Foundation

/// Values shared between the app and the widget extension (via the App Group).
enum SharedConfig {
    static let appGroup = "group.com.sohail.jarvis"
    static let standByWidgetKind = "JarvisStandByWidget"
    /// Control Center / Action Button toggle. The app and the widget extension must use the same kind.
    static let controlKind = "com.sohail.jarvis.control"
    /// Control Center / Action Button button that opens JARVIS into listening.
    static let talkControlKind = "com.sohail.jarvis.talk"

    /// Falls back to standard defaults if the App Group isn't provisioned (data then won't reach the widget).
    static var defaults: UserDefaults { UserDefaults(suiteName: appGroup) ?? .standard }

    enum Key {
        static let lastTranscript = "shared.lastTranscript"
        static let lastReply = "shared.lastReply"
        static let primaryHex = "shared.primaryHex"
        static let accentHex = "shared.accentHex"
        static let orbTintHex = "shared.orbTintHex"
        static let orbTintAmount = "shared.orbTintAmount"
        /// True while a hands-free session is running. The control reads this to draw on/off.
        static let sessionActive = "shared.sessionActive"
    }
}
