import SwiftUI

/// In-chat voice: transcript, a 60pt orb above the composer, and the voice controls.
struct ChatView: View {
    @Environment(AssistantEngine.self) private var engine
    @Environment(AppSettings.self) private var settings
    var orbSpace: Namespace.ID
    var onPlus: () -> Void
    var onClose: () -> Void

    @State private var voice = VoiceSession.shared
    @State private var draft = ""
    @State private var orbScale: CGFloat = 0.3
    @State private var orbOpacity: Double = 0
    @State private var showOrb = false
    @Environment(\.colorScheme) private var scheme

    private var voiceOn: Bool { engine.isSessionActive && !voice.exiting }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button(action: onClose) {
                    Image(systemName: "chevron.down")
                        .font(.body.weight(.semibold))
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.plain)
                Spacer()
                if engine.phase != .idle {
                    Text(engine.voiceState.label)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Color.clear.frame(width: 44, height: 44)
            }
            MessageList()
            if showOrb {
                VoiceOrbSlot(side: 60)
                    .scaleEffect(orbScale)
                    .opacity(orbOpacity)
                    .matchedGeometryEffect(id: "voice-orb", in: orbSpace)
                    .padding(.bottom, 8)
            }
            if let status = engine.statusLine, engine.phase == .thinking || engine.cloudExecuting {
                statusChip(status)
                    .padding(.bottom, 8)
            }
            if engine.pendingSummary != nil {
                ApprovalCard()
                    .padding(.horizontal, 16)
                    .padding(.bottom, 8)
            }
            composer
                .padding(.horizontal, 12)
                .padding(.bottom, 8)
        }
        .background(scheme == .dark ? Color.black : Color.white)
        .onAppear { syncOrb(active: engine.isSessionActive, animated: false) }
        .onChange(of: engine.isSessionActive) { _, active in
            syncOrb(active: active, animated: true)
        }
        .onChange(of: engine.dictationText) { _, text in
            if engine.isDictating || !text.isEmpty { draft = text }
        }
    }

    private var composer: some View {
        HStack(spacing: 8) {
            circleButton(system: "plus", fill: Color.primary.opacity(0.08), foreground: .primary, action: onPlus)
            TextField(voiceOn ? "Ask JARVIS" : "Message", text: $draft, axis: .vertical)
                .lineLimit(1...4)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(Color.primary.opacity(0.06), in: Capsule())
                .onSubmit(sendDraft)
            if voiceOn {
                circleButton(
                    system: "mic.slash",
                    fill: Color(white: 0.78),
                    foreground: .black,
                    action: { engine.toggleMute() }
                )
                circleButton(
                    system: "xmark",
                    fill: scheme == .dark ? .white : .black,
                    foreground: scheme == .dark ? .black : .white,
                    action: { Task { await engine.endSession(reason: "end-button") } }
                )
            } else {
                circleButton(
                    system: engine.isDictating ? "mic.fill" : "mic",
                    fill: Color.primary.opacity(0.08),
                    foreground: .primary,
                    action: { engine.toggleDictation() }
                )
                circleButton(
                    system: "waveform",
                    fill: Color.primary.opacity(0.08),
                    foreground: .primary,
                    action: { Task { await engine.startSession(continuous: true) } }
                )
            }
        }
        .animation(.easeInOut(duration: 0.25), value: voiceOn)
    }

    private func circleButton(system: String, fill: Color, foreground: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: system)
                .font(.body.weight(.semibold))
                .foregroundStyle(foreground)
                .frame(width: 44, height: 44)
                .background(fill, in: Circle())
        }
        .buttonStyle(.plain)
    }

    private func statusChip(_ text: String) -> some View {
        Text(text)
            .font(.footnote.weight(.medium))
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(.ultraThinMaterial, in: Capsule())
    }

    private func sendDraft() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        draft = ""
        engine.ask(text)
    }

    private func syncOrb(active: Bool, animated: Bool) {
        if active && !settings.voiceSeparateMode {
            showOrb = true
            orbOpacity = 1
            if animated {
                orbScale = 0.3
                withAnimation(.spring(response: 0.45, dampingFraction: 0.75)) {
                    orbScale = 1
                }
            } else {
                orbScale = 1
            }
        } else if showOrb {
            let fade = {
                orbScale = 0.2
                orbOpacity = 0
            }
            if animated {
                withAnimation(.easeIn(duration: 0.25), fade)
            } else {
                fade()
            }
            Task {
                try? await Task.sleep(for: .milliseconds(250))
                if !engine.isSessionActive { showOrb = false }
            }
        }
    }
}

struct MessageList: View {
    @Environment(AssistantEngine.self) private var engine

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    ForEach(engine.turns) { turn in
                        bubble(turn)
                            .id(turn.id)
                    }
                    if engine.phase == .listening, !engine.transcript.isEmpty {
                        Text(engine.transcript)
                            .font(.body)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .trailing)
                            .id("live")
                    }
                    if streaming {
                        bubble(VoiceTurn(role: "assistant", text: engine.reply))
                            .id("stream")
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
            }
            .onChange(of: engine.turns.count) { _, _ in scroll(proxy) }
            .onChange(of: engine.reply) { _, _ in scroll(proxy) }
        }
    }

    private var streaming: Bool {
        guard !engine.reply.isEmpty, engine.phase == .thinking || engine.phase == .speaking else { return false }
        return engine.turns.last?.text != engine.reply
    }

    private func bubble(_ turn: VoiceTurn) -> some View {
        let mine = turn.role == "user"
        return VStack(alignment: mine ? .trailing : .leading, spacing: 2) {
            Text(turn.text)
                .font(.body)
                .foregroundStyle(mine ? Color.primary : Color.primary.opacity(0.9))
            if turn.truncated {
                Text("Interrupted")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(mine ? Color.primary.opacity(0.08) : Color.clear, in: RoundedRectangle(cornerRadius: 18))
        .frame(maxWidth: .infinity, alignment: mine ? .trailing : .leading)
    }

    private func scroll(_ proxy: ScrollViewProxy) {
        withAnimation(.easeOut(duration: 0.2)) {
            if streaming {
                proxy.scrollTo("stream", anchor: .bottom)
            } else if let id = engine.turns.last?.id {
                proxy.scrollTo(id, anchor: .bottom)
            } else {
                proxy.scrollTo("live", anchor: .bottom)
            }
        }
    }
}

/// Separate mode: 220pt orb, captions, and mute / menu / captions / end.
struct FullScreenVoiceView: View {
    @Environment(AssistantEngine.self) private var engine
    var orbSpace: Namespace.ID

    @State private var voice = VoiceSession.shared
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(spacing: 16) {
            Spacer(minLength: 0)
            VoiceOrbSlot(side: 220)
                .scaleEffect(voice.exiting ? 0.2 : 1)
                .opacity(voice.exiting ? 0 : 1)
                .animation(.easeIn(duration: 0.25), value: voice.exiting)
                .matchedGeometryEffect(id: "voice-orb", in: orbSpace)
                .onTapGesture { voice.showTranscript.toggle() }
            if voice.captionsOn {
                Text(caption)
                    .font(.body)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: 320)
                    .frame(minHeight: 44)
            }
            if voice.showTranscript {
                transcript
                    .frame(maxHeight: 180)
            }
            if let status = engine.statusLine {
                Text(status)
                    .font(.footnote.weight(.medium))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(.ultraThinMaterial, in: Capsule())
            }
            if engine.pendingSummary != nil {
                ApprovalCard()
                    .padding(.horizontal, 22)
            }
            Spacer(minLength: 0)
            HStack(spacing: 28) {
                round(system: engine.microphoneMuted ? "mic.slash" : "mic",
                      fill: Color(white: 0.78), foreground: .black) { engine.toggleMute() }
                Menu {
                    Button("End conversation", role: .destructive) {
                        Task { await engine.endSession(reason: "menu") }
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.body.weight(.semibold))
                        .frame(width: 44, height: 44)
                }
                round(system: "captions.bubble",
                      fill: voice.captionsOn ? Color.primary : Color.primary.opacity(0.12),
                      foreground: voice.captionsOn ? (scheme == .dark ? .black : .white) : .primary) {
                    voice.captionsOn.toggle()
                }
                round(system: "xmark",
                      fill: scheme == .dark ? .white : .black,
                      foreground: scheme == .dark ? .black : .white) {
                    Task { await engine.endSession(reason: "end-button") }
                }
            }
            .padding(.bottom, 12)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(scheme == .dark ? Color.black : Color.white)
    }

    private var caption: String {
        let source = engine.phase == .listening || engine.phase == .idle ? engine.transcript : engine.reply
        let trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return engine.voiceState.label }
        return String(trimmed.suffix(180))
    }

    private var transcript: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 10) {
                ForEach(engine.turns) { turn in
                    Text(turn.text)
                        .font(.callout)
                        .frame(maxWidth: .infinity, alignment: turn.role == "user" ? .trailing : .leading)
                }
            }
            .padding(.horizontal, 24)
        }
    }

    private func round(system: String, fill: Color, foreground: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: system)
                .font(.body.weight(.semibold))
                .foregroundStyle(foreground)
                .frame(width: 44, height: 44)
                .background(fill, in: Circle())
        }
        .buttonStyle(.plain)
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

/// ChatGPT cloud, or the Metal orb when Orb style is JARVIS classic.
private struct VoiceOrbSlot: View {
    @Environment(AssistantEngine.self) private var engine
    @Environment(AppSettings.self) private var settings
    var side: CGFloat

    var body: some View {
        Group {
            if settings.orbStyle == .classic {
                OrbView(level: engine.level, phase: engine.phase,
                        primary: settings.primaryColor, accent: settings.accentColor,
                        sessionActive: engine.isSessionActive,
                        executing: engine.phase == .thinking || engine.cloudExecuting,
                        hasError: engine.errorMessage != nil)
            } else {
                VoiceOrbView(level: engine.level, state: engine.voiceState)
            }
        }
        .frame(width: side, height: side)
    }
}

extension VoiceState {
    var label: String {
        switch self {
        case .off: "Off"
        case .connecting: "Connecting"
        case .listening: "Listening"
        case .userSpeaking: "Listening"
        case .thinking: "Thinking"
        case .aiSpeaking: "Speaking"
        case .muted: "Muted"
        case .error: "Connection problem"
        case .ended: "Ended"
        }
    }
}
