import AppIntents
import SwiftUI
import WidgetKit

/// Action Button > Controls, and the Control Center gallery.
/// Opens the app straight into listening. Same intent as "Hey Siri, JARVIS".
@available(iOS 18.0, *)
struct JarvisTalkControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: SharedConfig.talkControlKind) {
            ControlWidgetButton(action: TalkToJarvisIntent()) {
                Label("Talk to JARVIS", systemImage: "mic.fill")
            }
        }
        .displayName("Talk to JARVIS")
        .description("Opens JARVIS and starts listening.")
    }
}

/// Action Button > Controls, and the Control Center gallery. Search title is "JARVIS".
/// This toggle keeps a session in the Dynamic Island without bringing the app forward.
@available(iOS 18.0, *)
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
