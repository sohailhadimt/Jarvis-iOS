import SwiftUI

/// Live call cards on the home screen: dialing, on the call, and the ended summary.
struct CallTaskStrip: View {
    @Environment(AssistantEngine.self) private var engine
    @State private var hidden: Set<String> = []

    private var cards: [StoredCall] {
        engine.deskCalls.filter { !hidden.contains($0.id) }
    }

    var body: some View {
        VStack(spacing: 8) {
            ForEach(cards) { call in
                CallTaskCard(call: call) {
                    withAnimation(.spring(duration: 0.42, bounce: 0.05)) {
                        hidden.insert(call.id)
                    }
                }
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.spring(duration: 0.42, bounce: 0.05), value: cards.map(\.id))
    }
}

private struct CallTaskCard: View {
    var call: StoredCall
    var dismiss: () -> Void

    private var stage: CallDeskStage { CallDeskStage.of(call) }
    private var accent: Color {
        stage == .ended && call.callbackNeeded == true ? Color(hex: "#FF5A2A") : Color(hex: "#2E8BFF")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(label)
                    .font(.system(size: 11, weight: .semibold))
                    .tracking(1.4)
                    .foregroundStyle(accent)
                Spacer()
                if stage == .ended {
                    Button(action: dismiss) {
                        Image(systemName: "xmark")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Color(hex: "#8E8A99"))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Dismiss call")
                }
            }
            Text(call.displayName)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(.white)
            Text(call.number)
                .font(.system(size: 12, weight: .regular, design: .monospaced))
                .foregroundStyle(Color(hex: "#8E8A99"))
            Text(line)
                .font(.system(size: 15))
                .foregroundStyle(Color(hex: "#C9C6D4"))
                .fixedSize(horizontal: false, vertical: true)
            if stage == .ended, call.callbackNeeded == true {
                Text("Call back needed")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color(hex: "#FF5A2A"))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color(hex: "#FF5A2A").opacity(0.14), in: Capsule())
            }
            if stage == .ended {
                actions
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(hex: "#0B1220").opacity(0.92), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(accent.opacity(0.45), lineWidth: 0.8))
    }

    private var label: String {
        switch stage {
        case .dialing: "DIALING"
        case .live: "ON THE CALL"
        case .ended: "ENDED"
        }
    }

    private var line: String {
        switch stage {
        case .dialing:
            "Ringing now, Sir..."
        case .live:
            "On the call now, I'll report back, Sir."
        case .ended:
            if let summary = call.delegationSummary, !summary.isEmpty { return summary }
            if !call.summary.isEmpty { return call.summary }
            return "The call has ended, Sir."
        }
    }

    @ViewBuilder
    private var actions: some View {
        HStack(spacing: 8) {
            if call.delegationStatus == "awaiting_decision" {
                deskButton("Take it") { engine.decideDesk(call.id, choice: "yes") }
                deskButton("Leave it") { engine.decideDesk(call.id, choice: "no") }
            } else if call.callbackNeeded == true {
                deskButton("Call back") { engine.decideDesk(call.id, choice: "yes") }
            }
            if call.hasRecording == true {
                deskButton("Play") { engine.playRecording(call.id) }
            }
        }
    }

    private func deskButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(title) {
            JarvisHaptics.tap()
            action()
        }
        .font(.system(size: 13, weight: .medium))
        .foregroundStyle(.white)
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(Color.white.opacity(0.06), in: Capsule())
        .buttonStyle(.plain)
    }
}
