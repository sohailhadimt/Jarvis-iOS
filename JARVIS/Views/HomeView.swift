import SwiftUI

struct HomeView: View {
    var openStandBy: () -> Void

    var body: some View {
        JarvisShell(openStandBy: openStandBy)
    }
}

// MARK: - Pieces

struct GlassPanel: ViewModifier {
    var tint: Color
    var radius: CGFloat = 22

    func body(content: Content) -> some View {
        content
            .background {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(.ultraThinMaterial)
                    .overlay(Color.black.opacity(0.55))
                    .overlay(
                        RoundedRectangle(cornerRadius: radius, style: .continuous)
                            .stroke(tint.opacity(0.62), lineWidth: 1)
                    )
                    .shadow(color: tint.opacity(0.25), radius: 10)
            }
    }
}

extension View {
    func glassPanel(tint: Color, radius: CGFloat = 22) -> some View {
        modifier(GlassPanel(tint: tint, radius: radius))
    }
}

/// Confirm-before-acting bar for calls, messages, deletes and agent tasks.
struct ConfirmBar: View {
    @Environment(AppSettings.self) private var settings
    let summary: String
    let onConfirm: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(spacing: 8) {
            Text(summary)
                .font(.system(size: 13, weight: .light))
                .multilineTextAlignment(.center)
                .foregroundStyle(.white)
            HStack {
                Button("Cancel", role: .cancel, action: onCancel).buttonStyle(.bordered)
                Button("Confirm", action: onConfirm).buttonStyle(.borderedProminent)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity)
        .glassPanel(tint: settings.primaryColor, radius: 16)
    }
}

struct NewsPulseView: View {
    @Environment(AssistantEngine.self) private var engine
    @Environment(AppSettings.self) private var settings
    @State private var briefing: NewsBriefing?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Button {
                    engine.ask("What's happening?")
                } label: {
                    Text("What's happening?")
                        .font(.system(size: 15, weight: .medium, design: .monospaced))
                        .foregroundStyle(settings.accentColor)
                        .frame(maxWidth: .infinity)
                        .frame(height: 44)
                        .overlay(Capsule().stroke(settings.accentColor.opacity(0.7), lineWidth: 1))
                }
                .buttonStyle(.plain)
                if let status = engine.statusLine, !status.isEmpty {
                    Text(status)
                        .font(.caption)
                        .foregroundStyle(settings.accentColor)
                }
                if let briefing {
                    Text(briefing.createdAt.formatted(date: .abbreviated, time: .shortened))
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.55))
                    Text(briefing.text)
                        .font(.body)
                        .foregroundStyle(.white)
                        .textSelection(.enabled)
                    if !briefing.citations.isEmpty {
                        Text("Sources")
                            .font(.caption.weight(.semibold))
                            .tracking(1.2)
                            .foregroundStyle(settings.primaryColor)
                        ForEach(briefing.citations) { citation in
                            newsLink(citation)
                        }
                    }
                } else {
                    Text("Ask what's happening for a short briefing from the live web.")
                        .font(.body)
                        .foregroundStyle(.white.opacity(0.7))
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color.black)
        .navigationTitle("News")
        .toolbar(.visible, for: .navigationBar)
        .onAppear { briefing = NewsPulseStore.load() }
        .onChange(of: engine.newsTick) { _, _ in
            briefing = NewsPulseStore.load()
        }
    }

    private func newsLink(_ citation: Citation) -> some View {
        let destination = URL(string: citation.url)
        return Group {
            if let destination {
                Link(citation.title, destination: destination)
                    .font(.footnote)
            }
        }
    }
}

struct TasksView: View {
    @Environment(AssistantEngine.self) private var engine
    @Environment(AppSettings.self) private var settings
    @State private var draft = ""

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            Form {
                Section {
                    TextField("Remind me, or ask what's on today", text: $draft)
                    Button("Send to JARVIS") {
                        engine.ask(draft)
                        draft = ""
                    }
                    .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                } header: {
                    Text("Ask")
                } footer: {
                    Text("JARVIS can read your calendar and reminders, and can send a task to your agent after you confirm.")
                }

                Section("Reminders & calendar") {
                    Button("What's on my calendar today?") {
                        engine.ask("What's on my calendar today?")
                    }
                    Button("What reminders do I have?") {
                        engine.ask("List my reminders.")
                    }
                }

                Section("Task agent") {
                    NavigationLink("Webhook, routing and shortcuts") {
                        IntegrationsSettingsView()
                    }
                }

                if engine.pendingCallBrief != nil {
                    Section("Call") {
                        CallBriefBar()
                    }
                }
                if let summary = engine.pendingSummary {
                    Section("Confirm") {
                        ConfirmBar(summary: summary,
                                   onConfirm: { engine.confirmPendingAction() },
                                   onCancel: { engine.cancelPendingAction() })
                    }
                }
                if !engine.reply.isEmpty || engine.phase != .idle {
                    Section(engine.phase.label) {
                        if !engine.reply.isEmpty {
                            Text(engine.reply).font(.footnote).textSelection(.enabled)
                        } else {
                            Text(engine.phase.label).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .scrollContentBackground(.hidden)
        }
        .navigationTitle("Tasks")
        .toolbar(.visible, for: .navigationBar)
        .tint(settings.primaryColor)
    }
}

