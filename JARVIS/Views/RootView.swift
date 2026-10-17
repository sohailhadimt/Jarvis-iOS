import SwiftUI
import UIKit

/// Switches to the full-screen StandBy view when the phone is charging and in landscape.
struct RootView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(AssistantEngine.self) private var engine
    @Environment(\.scenePhase) private var scenePhase
    @State private var isCharging = false
    @State private var forceStandBy = false
    @State private var offerVoiceMatch = false
    @State private var showBoot = false
    @State private var unlocked = !UserDefaults.standard.bool(forKey: "privacyLock")
    @State private var recoveryNote: String?

    var body: some View {
        GeometryReader { geo in
            let landscape = geo.size.width > geo.size.height
            ZStack {
                Group {
                    if forceStandBy || (settings.autoStandBy && isCharging && landscape) {
                        StandByView(onExit: { forceStandBy = false })
                    } else {
                        HomeView(openStandBy: { forceStandBy = true })
                    }
                }
                .frame(width: geo.size.width, height: geo.size.height)
                if showBoot {
                    BootOverlay { showBoot = false }
                }
                if settings.privacyLock, !unlocked {
                    PrivacyCover { Task { unlocked = await PrivacyGate.unlock() } }
                }
                if let recoveryNote {
                    VStack {
                        Spacer()
                        Text(recoveryNote)
                            .font(.system(size: 14))
                            .foregroundStyle(Color(hex: "#C9C6D4"))
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 28)
                            .padding(.bottom, 88)
                    }
                    .allowsHitTesting(false)
                }
            }
        }
        .background(Color(hex: "#05080F").ignoresSafeArea())
        .preferredColorScheme(.dark)
        .ignoresSafeArea(.keyboard)
        .onAppear {
            UIDevice.current.isBatteryMonitoringEnabled = true
            refreshBattery()
            Reachability.shared.start()
            BriefingClock.schedule()
            if LaunchGuard.consumeRecovery() {
                recoveryNote = "I didn't shut down cleanly. I'm ready now."
                Task {
                    try? await Task.sleep(for: .seconds(4))
                    recoveryNote = nil
                }
            }
            let listeningNow = JarvisStartListening.isPending
            if settings.onboarded, !settings.startWithVoice, !listeningNow, !BootGate.shown, !BriefingClock.due() {
                BootGate.shown = true
                showBoot = true
            }
            // Referencing the provider keeps it in the binary and refreshes the Action Button list.
            JarvisShortcuts.updateAppShortcutParameters()
            engine.setForeground(scenePhase == .active)
            CloudMonitor.shared.setVisible(scenePhase == .active)
            startListeningIfRequested()
            AgentStore.shared.startCloudSync()
            if settings.onboarded, settings.startWithVoice, !engine.isSessionActive {
                Task { await engine.startSession(continuous: true) }
            }
            engine.startScreenWatch()
            if settings.onboarded, !settings.voiceMatchPrompted && !VoiceProfileStore.hasProfile {
                offerVoiceMatch = true
            }
            if settings.onboarded, settings.privacyLock, !unlocked {
                Task { unlocked = await PrivacyGate.unlock() }
            }
            deliverBriefingIfDue()
        }
        .fullScreenCover(isPresented: Binding(
            get: { !settings.onboarded },
            set: { if !$0 { settings.onboarded = true } }
        )) {
            FirstRunView {
                settings.onboarded = true
            }
        }
        .sheet(isPresented: $offerVoiceMatch, onDismiss: {
            settings.voiceMatchPrompted = true
        }) {
            VoiceEnrollmentView(allowsSkip: true) {
                settings.voiceMatchEnabled = true
                settings.voiceMatchPrompted = true
                offerVoiceMatch = false
                engine.applyVoicePolicy()
            }
        }
        .onChange(of: scenePhase) { _, phase in
            // Becoming active or background must not end a control session. The audio engine
            // and Live Activity are what keep listening alive after the Action Button returns.
            engine.setForeground(phase == .active)
            CloudMonitor.shared.setVisible(phase == .active)
            if phase == .background {
                LaunchGuard.markClean()
                if settings.privacyLock { unlocked = false }
            }
            if phase == .active {
                startListeningIfRequested()
                if settings.privacyLock, !unlocked {
                    Task { unlocked = await PrivacyGate.unlock() }
                }
                deliverBriefingIfDue()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .jarvisDeliverBriefing)) { _ in
            deliverBriefingIfDue(force: true)
        }
        .onReceive(NotificationCenter.default.publisher(for: JarvisStartListening.notification)) { _ in
            startListeningIfRequested()
        }
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 8) {
                if engine.ownerAlert != nil {
                    OwnerAlertCard()
                }
                if engine.pendingQuestion != nil {
                    QuestionCard()
                }
                if engine.inboundCall != nil {
                    ScreeningCard()
                }
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 8)
        }
        .sheet(item: Binding(get: { engine.messageDraft }, set: { engine.messageDraft = $0 })) { draft in
            MessageComposer(draft: draft) { engine.messageDraft = nil }
                .ignoresSafeArea()
        }
        .sheet(item: Binding(get: { engine.mailDraft }, set: { engine.mailDraft = $0 })) { draft in
            MailComposer(draft: draft) { engine.mailDraft = nil }
                .ignoresSafeArea()
        }
        .onReceive(NotificationCenter.default.publisher(for: UIDevice.batteryStateDidChangeNotification)) { _ in
            refreshBattery()
        }
        .onOpenURL { url in
            switch url.host() {
            case "standby": forceStandBy = true
            case "listen":
                forceStandBy = false
                JarvisStartListening.request()
                startListeningIfRequested()
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

    private func deliverBriefingIfDue(force: Bool = false) {
        guard settings.onboarded, unlocked || !settings.privacyLock else { return }
        guard force || BriefingClock.due() else { return }
        guard engine.phase == .idle, engine.inboundCall == nil else { return }
        BriefingClock.markDelivered()
        engine.ask("What's been happening")
    }
}

/// Once per process. Returning from the background does not play the boot sequence again.
enum BootGate {
    static var shown = false
}
