import SwiftUI

/// One inbound call, spoken by JARVIS and kept under Calls.
struct CallMessageStrip: View {
    @Environment(AssistantEngine.self) private var engine

    var body: some View {
        VStack(spacing: 8) {
            ForEach(engine.callMessages) { message in
                CallMessageCard(message: message)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.spring(duration: 0.42, bounce: 0.05), value: engine.callMessages.map(\.id))
    }
}

struct CallMessageCard: View {
    var message: CallMessage

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("MESSAGE")
                .font(.system(size: 11, weight: .semibold))
                .tracking(1.4)
                .foregroundStyle(Color(hex: "#2E8BFF"))
            Text(message.callerName.isEmpty ? "Someone" : message.callerName)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(.white)
            Text(message.spoken)
                .font(.system(size: 15))
                .foregroundStyle(Color(hex: "#C9C6D4"))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(hex: "#0B1220").opacity(0.92), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(Color(hex: "#2E8BFF").opacity(0.45), lineWidth: 0.8))
    }
}
