import SwiftUI

struct SourceLinks: View {
    let citations: [Citation]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Sources")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            ForEach(citations) { citation in
                sourceLink(citation)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func sourceLink(_ citation: Citation) -> some View {
        let destination = URL(string: citation.url)
        return Group {
            if let destination {
                Link(citation.title, destination: destination)
                    .font(.footnote)
            }
        }
    }
}

/// Shown only when more than one contact matches. One match never reaches this list.
struct CallPicker: View {
    @Environment(AssistantEngine.self) private var engine
    @Environment(AppSettings.self) private var settings

    private var choices: [CallChoice] {
        if !engine.briefChoices.isEmpty { return engine.briefChoices }
        return engine.callChoices
    }

    var body: some View {
        if choices.isEmpty {
            EmptyView()
        } else {
            VStack(spacing: 8) {
                ForEach(choices) { choice in
                    choiceButton(choice)
                }
            }
            .frame(maxWidth: 280)
        }
    }

    private func choiceButton(_ choice: CallChoice) -> some View {
        Button {
            if engine.briefChoices.isEmpty {
                engine.placeCall(choice)
            } else {
                engine.chooseBriefedContact(choice)
            }
        } label: {
            HStack(spacing: 8) {
                Text(choice.name)
                    .font(.system(size: 14, weight: .medium, design: .monospaced))
                    .foregroundStyle(settings.accentColor)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Text(choice.subtitle)
                    .font(.system(size: 11, weight: .regular, design: .monospaced))
                    .foregroundStyle(settings.accentColor.opacity(0.75))
                    .lineLimit(1)
            }
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity)
            .frame(height: 40)
            .background(Color.black, in: Capsule())
            .overlay(Capsule().stroke(settings.accentColor.opacity(0.7), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(engine.briefChoices.isEmpty ? "Call \(choice.name)" : "Choose \(choice.name)")
    }
}

/// Tool confirmation. Buttons only — voice cannot approve.
struct ApprovalCard: View {
    @Environment(AssistantEngine.self) private var engine

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(engine.pendingSummary ?? "Confirm this action")
                .font(.subheadline)
            HStack(spacing: 10) {
                Button("Decline") { engine.cancelPendingAction() }
                    .buttonStyle(.bordered)
                Button("Approve") { engine.confirmPendingAction() }
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
    }
}
