import SwiftUI
import UIKit

/// Full-screen black "bedside" mode with a large orb. Tap to talk; the button toggles hands-free.
struct StandByView: View {
    @Environment(AssistantEngine.self) private var engine
    @Environment(AppSettings.self) private var settings
    var onExit: () -> Void

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            OrbView(level: engine.level, phase: engine.phase,
                    primary: settings.primaryColor, accent: settings.accentColor)
                .padding(24)
                .contentShape(Rectangle())
                .onTapGesture { engine.tapToTalk() }

            VStack {
                HStack {
                    Button(action: onExit) { Image(systemName: "xmark") }
                    Spacer()
                    Text(Date.now, style: .time)
                        .font(.system(size: 22, weight: .light, design: .rounded))
                        .foregroundStyle(settings.accentColor.opacity(0.8))
                    Spacer()
                    Button {
                        Task { await engine.toggleSession() }
                    } label: {
                        Image(systemName: engine.isSessionActive ? "stop.circle" : "infinity.circle")
                    }
                }
                .font(.title2)
                .foregroundStyle(.white.opacity(0.6))
                Spacer()
                if let summary = engine.pendingSummary {
                    ConfirmBar(summary: summary,
                               onConfirm: { engine.confirmPendingAction() },
                               onCancel: { engine.cancelPendingAction() })
                }
                Text(engine.phase == .listening ? engine.transcript : engine.reply)
                    .lineLimit(2)
                    .font(.title3)
                    .foregroundStyle(.white.opacity(0.75))
                    .multilineTextAlignment(.center)
            }
            .padding()
        }
        .statusBarHidden()
        .persistentSystemOverlays(.hidden)
        .onAppear { UIApplication.shared.isIdleTimerDisabled = true }
        .onDisappear { UIApplication.shared.isIdleTimerDisabled = false }
    }
}
