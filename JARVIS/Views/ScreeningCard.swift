import SwiftUI

/// A question from the live call, answered by typing or by the next thing Sohail says.
struct QuestionCard: View {
    @Environment(AssistantEngine.self) private var engine
    @State private var draft = ""

    var body: some View {
        if let question = engine.pendingQuestion {
            VStack(alignment: .leading, spacing: 8) {
                Text("They asked")
                    .font(.caption.weight(.semibold))
                Text(question.question)
                    .font(.subheadline)
                TextField("What should I tell them?", text: $draft)
                    .textFieldStyle(.roundedBorder)
                Button("Send answer") {
                    engine.answerPendingQuestion(draft)
                    draft = ""
                }
                .buttonStyle(.borderedProminent)
                .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Text("You can also just say the answer.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
        }
    }
}

struct OwnerAlertCard: View {
    @Environment(AssistantEngine.self) private var engine

    var body: some View {
        if let alert = engine.ownerAlert {
            VStack(alignment: .leading, spacing: 6) {
                Text(alert.channel == "call" ? "JARVIS rang you" : "JARVIS needs you")
                    .font(.caption.weight(.semibold))
                Text(alert.summary)
                    .font(.subheadline)
                if !alert.detail.isEmpty {
                    Text(alert.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
        }
    }
}

/// Live inbound call: transcript, the four choices, and a personal-details prompt.
struct ScreeningCard: View {
    @Environment(AssistantEngine.self) private var engine
    @Environment(AppSettings.self) private var settings

    var body: some View {
        if let call = engine.inboundCall {
            VStack(alignment: .leading, spacing: 10) {
                Text(title(call))
                    .font(.headline)
                Text(call.to)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                if let reason = call.reason, !reason.isEmpty {
                    Text(reason)
                        .font(.subheadline)
                }
                Text(status(call))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if call.personalRequested == true && call.personalAllowed != true {
                    Text("They asked for something personal. Share it for this call only?")
                        .font(.subheadline)
                    HStack {
                        Button("Don't share") { engine.allowInboundPersonal(false) }
                            .buttonStyle(.bordered)
                        Button("Allow") { engine.allowInboundPersonal(true) }
                            .buttonStyle(.borderedProminent)
                    }
                }
                transcript(call)
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                    choice("Put me through", "connect")
                    choice("Let JARVIS handle it", "handle")
                    choice("Take a message", "message")
                    choice("Decline", "decline")
                }
                HStack {
                    Button("Listen") { engine.decideInbound("listen") }
                        .buttonStyle(.bordered)
                    Button("Take over") { engine.decideInbound("takeover") }
                        .buttonStyle(.borderedProminent)
                }
                Text("Listen shows the words here. Take over rings your mobile and JARVIS leaves the call.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
            .tint(settings.primaryColor)
        }
    }

    private func title(_ call: PhoneCallRecord) -> String {
        if let name = call.callerName, !name.isEmpty { return name }
        return "Incoming call"
    }

    private func status(_ call: PhoneCallRecord) -> String {
        switch call.status {
        case "screening": "JARVIS is asking who they are."
        case "listening": "You are listening to the transcript."
        case "handling": "JARVIS is handling the call."
        case "message": "JARVIS is taking a message."
        case "connecting": "Connecting you."
        default: call.status
        }
    }

    private func transcript(_ call: PhoneCallRecord) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if call.transcript.isEmpty {
                Text("Waiting for the first words.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            ForEach(Array(call.transcript.suffix(6).enumerated()), id: \.offset) { _, line in
                Text(line.role == "them" ? "Them: \(line.text)" : "JARVIS: \(line.text)")
                    .font(.caption)
                    .foregroundStyle(.primary)
            }
        }
    }

    private func choice(_ label: String, _ action: String) -> some View {
        Button(label) { engine.decideInbound(action) }
            .buttonStyle(.bordered)
            .font(.caption)
    }
}
