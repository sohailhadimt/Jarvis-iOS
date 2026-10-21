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
            Text(message.callerName.isEmpty ? "an unknown caller" : message.callerName)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(.white)
            if !message.calledAt.isEmpty {
                Text(CloudTime.display(message.calledAt))
                    .font(.system(size: 12))
                    .foregroundStyle(Color(hex: "#8E8A9A"))
            }
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

/// Caller, time, the full butler summary, the transcript, and the recording when one exists.
struct CallMessageDetail: View {
    @Environment(AssistantEngine.self) private var engine
    @Environment(\.dismiss) private var dismiss
    var message: CallMessage

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text(message.callerName.isEmpty ? "an unknown caller" : message.callerName)
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(.white)
                    if !message.calledAt.isEmpty {
                        Text(CloudTime.display(message.calledAt))
                            .font(.system(size: 14))
                            .foregroundStyle(Color(hex: "#8E8A9A"))
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        label("Summary")
                        Text(fullSummary)
                            .font(.system(size: 16))
                            .foregroundStyle(Color(hex: "#C9C6D4"))
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                    }
                    if !message.transcript.isEmpty {
                        VStack(alignment: .leading, spacing: 10) {
                            label("Transcript")
                            ForEach(Array(message.transcript.enumerated()), id: \.offset) { _, line in
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(line.role == "them" ? "Caller" : "JARVIS")
                                        .font(.system(size: 11, weight: .semibold))
                                        .tracking(1.1)
                                        .foregroundStyle(Color(hex: "#2E8BFF"))
                                    Text(line.text)
                                        .font(.system(size: 15))
                                        .foregroundStyle(.white)
                                        .fixedSize(horizontal: false, vertical: true)
                                        .textSelection(.enabled)
                                }
                            }
                        }
                    }
                    if message.recording {
                        Button {
                            engine.playRecording(message.callId)
                        } label: {
                            Text("Play recording")
                                .font(.system(size: 15, weight: .semibold))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 12)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(Color(hex: "#2E8BFF"))
                    }
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(Color(hex: "#05080F").ignoresSafeArea())
            .navigationTitle("Call")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    private var fullSummary: String {
        let spoken = message.spoken.trimmingCharacters(in: .whitespacesAndNewlines)
        let summary = message.summary.trimmingCharacters(in: .whitespacesAndNewlines)
        if spoken.isEmpty { return summary }
        if summary.isEmpty || summary == spoken { return spoken }
        if spoken.contains(summary) { return spoken }
        return "\(spoken)\n\n\(summary)"
    }

    private func label(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.system(size: 11, weight: .semibold))
            .tracking(1.4)
            .foregroundStyle(Color(hex: "#2E8BFF"))
    }
}
