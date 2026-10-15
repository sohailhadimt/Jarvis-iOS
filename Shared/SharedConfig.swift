import Foundation

/// Values shared between the app and the widget extension (via the App Group).
enum SharedConfig {
    static let appGroup = "group.com.sohail.jarvis"
    static let standByWidgetKind = "JarvisStandByWidget"

    /// Falls back to standard defaults if the App Group isn't provisioned (data then won't reach the widget).
    static var defaults: UserDefaults { UserDefaults(suiteName: appGroup) ?? .standard }

    enum Key {
        static let lastTranscript = "shared.lastTranscript"
        static let lastReply = "shared.lastReply"
        static let primaryHex = "shared.primaryHex"
        static let accentHex = "shared.accentHex"
    }
}
