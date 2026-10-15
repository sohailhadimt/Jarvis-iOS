import SwiftUI

struct HomeView: View {
    @Environment(AssistantEngine.self) private var engine
    @Environment(AppSettings.self) private var settings
    var openStandBy: () -> Void
    @State private var pttPressed = false

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.background.ignoresSafeArea()
                VStack(spacing: 16) {
                    Text(engine.phase.label.uppercased())
                        .font(.caption.monospaced().weight(.semibold))
                        .tracking(3)
                        .foregroundStyle(settings.accentColor)

                    OrbView(level: engine.level, phase: engine.phase,
                            primary: settings.primaryColor, accent: settings.accentColor)
                        .frame(maxWidth: .infinity)
                        .frame(height: 300)

                    ScrollView {
                        VStack(alignment: .leading, spacing: 10) {
                            if !engine.transcript.isEmpty {
                                Text(engine.transcript).foregroundStyle(.white.opacity(0.65))
                            }
                            if let status = engine.statusLine {
                                Label(status, systemImage: "gearshape.2").font(.caption).foregroundStyle(settings.accentColor)
                            }
                            if !engine.reply.isEmpty {
                                Text(engine.reply).foregroundStyle(.white).textSelection(.enabled)
                            }
                            if !engine.citations.isEmpty {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("Sources").font(.caption.bold()).foregroundStyle(settings.accentColor)
                                    ForEach(engine.citations) { c in
                                        if let url = URL(string: c.url) {
                                            Link(c.title, destination: url).font(.caption).lineLimit(1)
                                        }
                                    }
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 160)

                    if let summary = engine.pendingSummary {
                        ConfirmBar(summary: summary,
                                   onConfirm: { engine.confirmPendingAction() },
                                   onCancel: { engine.cancelPendingAction() })
                    }

                    if let error = engine.errorMessage {
                        Text(error).font(.footnote).foregroundStyle(.orange).multilineTextAlignment(.center)
                    }

                    controls
                }
                .padding()
            }
            .navigationTitle("J.A.R.V.I.S.")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(action: openStandBy) { Image(systemName: "moon.stars") }
                        .accessibilityLabel("StandBy view")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink { SettingsView() } label: { Image(systemName: "gearshape") }
                }
            }
            .tint(settings.accentColor)
        }
    }

    private var controls: some View {
        HStack(spacing: 28) {
            Button {
                Task { await engine.toggleSession() }
            } label: {
                Label(engine.isSessionActive ? "End" : "Converse",
                      systemImage: engine.isSessionActive ? "stop.fill" : "infinity")
                    .frame(minWidth: 110)
            }
            .buttonStyle(.bordered)
            .tint(engine.isSessionActive ? .red : settings.accentColor)

            Circle()
                .fill(pttPressed ? settings.primaryColor : settings.primaryColor.opacity(0.25))
                .overlay(Image(systemName: "mic.fill").font(.title).foregroundStyle(.white))
                .overlay(Circle().stroke(settings.accentColor, lineWidth: 2))
                .frame(width: 84, height: 84)
                .scaleEffect(pttPressed ? 1.1 : 1)
                .animation(.spring(duration: 0.25), value: pttPressed)
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { _ in
                            if !pttPressed {
                                pttPressed = true
                                engine.pushToTalkBegan()
                            }
                        }
                        .onEnded { _ in
                            pttPressed = false
                            engine.pushToTalkEnded()
                        }
                )
                .accessibilityLabel("Hold to talk")
                .accessibilityAddTraits(.isButton)
        }
        .padding(.bottom, 8)
    }
}

/// Confirm-before-acting bar for calls, messages, deletes and agent tasks.
struct ConfirmBar: View {
    let summary: String
    let onConfirm: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(spacing: 8) {
            Text(summary).font(.subheadline).multilineTextAlignment(.center)
            HStack {
                Button("Cancel", role: .cancel, action: onCancel).buttonStyle(.bordered)
                Button("Confirm", action: onConfirm).buttonStyle(.borderedProminent)
            }
        }
        .padding(12)
        .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 14))
    }
}
