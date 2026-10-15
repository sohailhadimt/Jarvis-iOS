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
            AgentJobStrip()
                .padding(.horizontal, 12)
                .padding(.bottom, 8)
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

/// Default voice screen. Black field, sky orb, hamburger, sliders, and the ask capsule.
struct FullScreenVoiceView: View {
    @Environment(AssistantEngine.self) private var engine
    @Environment(AppSettings.self) private var settings
    var orbSpace: Namespace.ID
    var onMenu: () -> Void
    var onSettings: () -> Void

    @State private var voice = VoiceSession.shared
    @State private var draft = ""

    private let chrome = Color(red: 28.0 / 255, green: 28.0 / 255, blue: 30.0 / 255)
    private let arc = Color(red: 75.0 / 255, green: 168.0 / 255, blue: 238.0 / 255)

    var body: some View {
        GeometryReader { geo in
            let diameter = geo.size.width * 0.53
            let orbY = geo.size.height * 0.56
            ZStack {
                Color.black
                SkyCloudOrbView(level: engine.level, state: engine.voiceState, closing: voice.exiting,
                                tint: settings.orbTintColor, tintAmount: settings.orbTintAmount,
                                crispEdge: true)
                    .frame(width: diameter, height: diameter)
                    .matchedGeometryEffect(id: "voice-orb", in: orbSpace)
                    .position(x: geo.size.width / 2, y: orbY)
                    .onTapGesture { voice.showTranscript.toggle() }
                if voice.captionsOn, !caption.isEmpty {
                    Text(caption)
                        .font(.system(size: 16, weight: .regular))
                        .foregroundStyle(Color(white: 0.78))
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                        .frame(maxWidth: 300)
                        .position(x: geo.size.width / 2, y: orbY + diameter / 2 + 28)
                }
                VStack(spacing: 12) {
                    topBar
                    Spacer(minLength: 0)
                        .allowsHitTesting(false)
                    if voice.showTranscript {
                        transcript
                            .frame(maxHeight: 150)
                    }
                    if let status = engine.statusLine {
                        Text(status)
                            .font(.footnote.weight(.medium))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(chrome, in: Capsule())
                    }
                    if let error = engine.errorMessage, !error.isEmpty {
                        Text(error)
                            .font(.footnote)
                            .foregroundStyle(.white.opacity(0.7))
                            .multilineTextAlignment(.center)
                            .lineLimit(2)
                    }
                    if engine.pendingSummary != nil {
                        ApprovalCard()
                    }
                    AgentJobStrip()
                    bottomBar
                }
                .padding(.top, geo.safeAreaInsets.top + 8)
                .padding(.bottom, max(geo.safeAreaInsets.bottom, 8) + 8)
                .padding(.horizontal, 14)
            }
        }
        .ignoresSafeArea()
        .background(Color.black)
        .onChange(of: engine.dictationText) { _, text in
            if engine.isDictating || !text.isEmpty { draft = text }
        }
    }

    private var topBar: some View {
        HStack {
            glassButton(action: onMenu) { hamburger }
                .accessibilityLabel("Menu")
            Spacer()
            glassButton(action: onSettings) { sliders }
                .accessibilityLabel("Voice settings")
        }
    }

    private var bottomBar: some View {
        HStack(spacing: 10) {
            HStack(spacing: 8) {
                Button(action: onMenu) {
                    Image(systemName: "plus")
                        .font(.system(size: 20, weight: .medium))
                        .foregroundStyle(.white)
                        .frame(width: 32, height: 32)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("More")
                TextField("", text: $draft, prompt: Text("Ask JARVIS…").foregroundStyle(Color(white: 0.55)))
                    .font(.system(size: 17))
                    .foregroundStyle(.white)
                    .submitLabel(.send)
                    .onSubmit(sendDraft)
                Button(action: startVoice) {
                    voiceArc
                        .frame(width: 20, height: 20)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Voice")
            }
            .padding(.leading, 12)
            .padding(.trailing, 14)
            .frame(height: 60)
            .background(chrome, in: Capsule())

            solidButton(fill: chrome, foreground: .white, system: "mic.slash", action: mute)
                .accessibilityLabel("Mute")
            solidButton(fill: .white, foreground: .black, system: "xmark", action: end)
                .accessibilityLabel("End")
        }
    }

    private var hamburger: some View {
        VStack(alignment: .leading, spacing: 5) {
            Capsule().fill(.white).frame(width: 16, height: 1.6)
            Capsule().fill(.white).frame(width: 10, height: 1.6)
        }
    }

    private var sliders: some View {
        VStack(spacing: 6) {
            sliderLine(knob: 0.72)
            sliderLine(knob: 0.30)
        }
        .frame(width: 18)
    }

    private func sliderLine(knob: CGFloat) -> some View {
        GeometryReader { geo in
            Capsule()
                .fill(.white)
                .frame(height: 1.5)
                .position(x: geo.size.width / 2, y: geo.size.height / 2)
            Circle()
                .fill(.white)
                .frame(width: 5.5, height: 5.5)
                .position(x: geo.size.width * knob, y: geo.size.height / 2)
        }
        .frame(height: 6)
    }

    private var voiceArc: some View {
        ZStack {
            Circle()
                .trim(from: 0.08, to: 0.42)
                .stroke(arc, style: StrokeStyle(lineWidth: 2, lineCap: .round))
            Circle()
                .trim(from: 0.58, to: 0.92)
                .stroke(arc, style: StrokeStyle(lineWidth: 2, lineCap: .round))
        }
        .rotationEffect(.degrees(-18))
    }

    private func glassButton<Label: View>(action: @escaping () -> Void, @ViewBuilder label: () -> Label) -> some View {
        Button(action: action) {
            label()
                .frame(width: 56, height: 56)
                .background {
                    Circle().fill(.ultraThinMaterial)
                    Circle().fill(chrome.opacity(0.78))
                }
                .overlay(Circle().stroke(Color.white.opacity(0.08), lineWidth: 0.5))
        }
        .buttonStyle(.plain)
    }

    private func solidButton(fill: Color, foreground: Color, system: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: system)
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(foreground)
                .frame(width: 60, height: 60)
                .background(fill, in: Circle())
        }
        .buttonStyle(.plain)
    }

    private var caption: String {
        let source = engine.phase == .listening || engine.phase == .idle ? engine.transcript : engine.reply
        return source.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var transcript: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 10) {
                ForEach(engine.turns) { turn in
                    Text(turn.text)
                        .font(.callout)
                        .foregroundStyle(.white.opacity(0.9))
                        .frame(maxWidth: .infinity, alignment: turn.role == "user" ? .trailing : .leading)
                }
            }
        }
    }

    private func sendDraft() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        draft = ""
        engine.ask(text)
    }

    private func startVoice() {
        guard !engine.isSessionActive else { return }
        Task { await engine.startSession(continuous: true) }
    }

    private func mute() {
        if engine.isSessionActive {
            engine.toggleMute()
        } else {
            startVoice()
        }
    }

    private func end() {
        guard engine.isSessionActive else { return }
        Task { await engine.endSession(reason: "end-button") }
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
                SkyCloudOrbView(level: engine.level, state: engine.voiceState,
                                tint: settings.orbTintColor, tintAmount: settings.orbTintAmount)
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
