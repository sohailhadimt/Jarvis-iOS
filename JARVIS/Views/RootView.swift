import SwiftUI
import UIKit

/// Switches to the full-screen StandBy view when the phone is charging and in landscape.
struct RootView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(AssistantEngine.self) private var engine
    @Environment(\.scenePhase) private var scenePhase
    @State private var isCharging = false
    @State private var forceStandBy = false

    var body: some View {
        GeometryReader { geo in
            let landscape = geo.size.width > geo.size.height
            Group {
                if forceStandBy || (settings.autoStandBy && isCharging && landscape) {
                    StandByView(onExit: { forceStandBy = false })
                } else {
                    HomeView(openStandBy: { forceStandBy = true })
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .ignoresSafeArea(.keyboard)
        .onAppear {
            UIDevice.current.isBatteryMonitoringEnabled = true
            refreshBattery()
            // Referencing the provider keeps it in the binary and refreshes the Action Button list.
            JarvisShortcuts.updateAppShortcutParameters()
            engine.setForeground(scenePhase == .active)
            CloudMonitor.shared.setVisible(scenePhase == .active)
            startListeningIfRequested()
        }
        .onChange(of: scenePhase) { _, phase in
            // Becoming active or background must not end a control session. The audio engine
            // and Live Activity are what keep listening alive after the Action Button returns.
            engine.setForeground(phase == .active)
            CloudMonitor.shared.setVisible(phase == .active)
            if phase == .active { startListeningIfRequested() }
        }
        .onReceive(NotificationCenter.default.publisher(for: JarvisStartListening.notification)) { _ in
            startListeningIfRequested()
        }
        .sheet(item: Binding(get: { engine.messageDraft }, set: { engine.messageDraft = $0 })) { draft in
            MessageComposer(draft: draft) { engine.messageDraft = nil }
                .ignoresSafeArea()
        }
        .onReceive(NotificationCenter.default.publisher(for: UIDevice.batteryStateDidChangeNotification)) { _ in
            refreshBattery()
        }
        .onOpenURL { url in
            switch url.host() {
            case "standby": forceStandBy = true
            case "shortcut-done", "shortcut-cancel", "shortcut-error": engine.shortcutReturned(url.host() ?? "")
            default: break
            }
        }
    }

    private func refreshBattery() {
        let state = UIDevice.current.batteryState
        isCharging = state == .charging || state == .full
    }

    private func startListeningIfRequested() {
        guard JarvisStartListening.consume() else { return }
        Task { await engine.startSession(continuous: true) }
    }
}
