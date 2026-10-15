import AppIntents
import SwiftUI
import WidgetKit

/// Action Button > Controls, and the Control Center gallery. Search title is "JARVIS".
struct JarvisControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: SharedConfig.controlKind) {
            ControlWidgetToggle(
                "JARVIS",
                isOn: JarvisControlState.isOn,
                action: SetJarvisSessionIntent()
            ) { isOn in
                Label("JARVIS", systemImage: isOn ? "waveform.circle.fill" : "waveform")
            }
        }
        .displayName("JARVIS")
        .description("Start or end JARVIS in the Dynamic Island.")
    }
}

private enum JarvisControlState {
    static var isOn: Bool {
        SharedConfig.defaults.bool(forKey: SharedConfig.Key.sessionActive)
    }
}
