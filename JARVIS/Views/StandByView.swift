import SwiftUI
import UIKit

/// Full-screen bedside mode. Same particle orb as home, larger, with tap-to-talk.
struct StandByView: View {
    @Environment(AssistantEngine.self) private var engine
    @Environment(AppSettings.self) private var settings
    var onExit: () -> Void

    private var tint: Color { settings.primaryColor }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            RadialGradient(colors: [tint.opacity(0.14), .clear],
                           center: .center, startRadius: 20, endRadius: 340)
                .ignoresSafeArea()
                .allowsHitTesting(false)

            OrbView(level: engine.level, phase: engine.phase,
                    primary: tint, accent: settings.accentColor,
                    sessionActive: engine.isSessionActive,
                    executing: engine.cloudExecuting || (engine.phase == .thinking && engine.statusLine != nil),
                    reply: engine.reply)
                .padding(8)
                .contentShape(Rectangle())
                .onTapGesture { engine.tapToTalk() }
        }
        .overlay(alignment: .top) {
            HStack {
                Button(action: onExit) {
                    Image(systemName: "xmark")
                        .font(.system(size: 16, weight: .light))
                        .frame(width: 40, height: 40)
                        .overlay(Circle().stroke(tint.opacity(0.45), lineWidth: 1))
                }
                .accessibilityLabel("Leave StandBy")
                Spacer()
                Text(Date.now, style: .time)
                    .font(.system(size: 22, weight: .thin, design: .rounded))
                    .tracking(2)
                    .foregroundStyle(tint.opacity(0.9))
                Spacer()
                Button {
                    Task { await engine.toggleSession() }
                } label: {
                    Image(systemName: engine.isSessionActive ? "stop.circle" : "infinity.circle")
                        .font(.system(size: 22, weight: .light))
                        .frame(width: 40, height: 40)
                }
                .accessibilityLabel(engine.isSessionActive ? "End session" : "Start hands-free session")
            }
            .foregroundStyle(tint)
            .padding()
        }
        .overlay(alignment: .bottom) {
            VStack(spacing: 8) {
                if engine.hasContactChoices {
                    CallPicker()
                }
                if engine.pendingCallBrief != nil {
                    CallBriefBar()
                }
                if let summary = engine.pendingSummary {
                    ConfirmBar(summary: summary,
                               onConfirm: { engine.confirmPendingAction() },
                               onCancel: { engine.cancelPendingAction() })
                }
                VStack(spacing: 6) {
                    Text(captionTitle)
                        .font(.system(size: 13, weight: .medium))
                        .tracking(2)
                        .foregroundStyle(tint)
                    Text(captionBody)
                        .font(.system(size: 16, weight: .light))
                        .foregroundStyle(.white.opacity(0.8))
                        .multilineTextAlignment(.center)
                        .lineLimit(3)
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 14)
                .frame(maxWidth: .infinity)
                .glassPanel(tint: tint, radius: 20)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 18)
        }
        .tint(tint)
        .statusBarHidden()
        .persistentSystemOverlays(.hidden)
        .onAppear { UIApplication.shared.isIdleTimerDisabled = true }
        .onDisappear { UIApplication.shared.isIdleTimerDisabled = false }
    }

    private var captionTitle: String {
        switch engine.phase {
        case .listening: "LISTENING"
        case .thinking: "THINKING"
        case .speaking: "RESPONDING"
        case .idle: "STANDING BY"
        }
    }

    private var captionBody: String {
        if engine.phase == .listening, !engine.transcript.isEmpty { return engine.transcript }
        if !engine.reply.isEmpty, engine.phase != .listening { return engine.reply }
        return "Tap the orb to talk."
    }
}
