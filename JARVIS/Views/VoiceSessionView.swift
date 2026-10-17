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
            if engine.pendingCallBrief != nil {
                CallBriefBar()
                    .padding(.horizontal, 16)
                    .padding(.bottom, 8)
            }
            if engine.pendingSummary != nil {
                ApprovalCard()
                    .padding(.horizontal, 16)
                    .padding(.bottom, 8)
            }
            if engine.hasContactChoices {
                CallPicker()
                    .padding(.horizontal, 16)
                    .padding(.bottom, 8)
            }
            AgentJobStrip()
                .padding(.horizontal, 12)
                .padding(.bottom, 8)
            AttachmentChip()
                .padding(.horizontal, 16)
                .padding(.bottom, 6)
            GeneratedPreview()
                .padding(.horizontal, 16)
                .padding(.bottom, 6)
            composer
                .padding(.horizontal, 12)
                .padding(.bottom, 8)
        }
        .background(scheme == .dark ? Color.black : Color.white)
        .onAppear {
            syncOrb(active: engine.isSessionActive, animated: false)
            VisionCamera.shared.release(owner: .voice)
        }
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
            AttachControl()
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
        let typed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        let text = typed.isEmpty && engine.attachmentName != nil ? "What is in this file?" : typed
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
                    if !engine.citations.isEmpty {
                        SourceLinks(citations: engine.citations)
                            .id("sources")
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
            }
            .onChange(of: engine.turns.count) { _, _ in scroll(proxy) }
            .onChange(of: engine.reply) { _, _ in scroll(proxy) }
            .onChange(of: engine.citations.count) { _, _ in scroll(proxy) }
        }
    }

    private var streaming: Bool {
        guard !engine.reply.isEmpty, engine.phase == .thinking || engine.phase == .speaking else { return false }
        return engine.turns.last?.text != engine.reply
    }

    private func bubble(_ turn: VoiceTurn) -> some View {
        let mine = turn.role == "user"
        return VStack(alignment: mine ? .trailing : .leading, spacing: 2) {
            if !mine, !turn.reasoning.isEmpty {
                ReasoningNote(text: turn.reasoning)
            }
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
            if !engine.citations.isEmpty {
                proxy.scrollTo("sources", anchor: .bottom)
            } else if streaming {
                proxy.scrollTo("stream", anchor: .bottom)
            } else if let id = engine.turns.last?.id {
                proxy.scrollTo(id, anchor: .bottom)
            } else {
                proxy.scrollTo("live", anchor: .bottom)
            }
        }
    }
}

struct ReasoningNote: View {
    var text: String

    var body: some View {
        DisclosureGroup {
            Text(text)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            Text(Self.summary(text))
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    private static func summary(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "Reasoning" }
        let line = trimmed.split(separator: "\n").first.map(String.init) ?? trimmed
        if line.count <= 72 { return line }
        return String(line.prefix(72))
    }
}

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
        let title = citation.title
        let destination = URL(string: citation.url)
        return Group {
            if let destination {
                Link(title, destination: destination)
                    .font(.footnote)
            }
        }
    }
}

/// Default voice screen. Black field, sky orb, and a compact cyan HUD under the orb.
struct FullScreenVoiceView: View {
    @Environment(AssistantEngine.self) private var engine
    @Environment(AppSettings.self) private var settings
    var orbSpace: Namespace.ID
    var onMenu: () -> Void
    var onSettings: () -> Void

    @State private var voice = VoiceSession.shared
    @State private var camera = VisionCamera.shared
    @State private var draft = ""

    var body: some View {
        GeometryReader { geo in
            voiceScreen(geo: geo)
        }
        .ignoresSafeArea()
        .background(Color.black)
        .onChange(of: engine.dictationText) { _, text in
            if engine.isDictating || !text.isEmpty { draft = text }
        }
    }

    /// Lets stay in this function. The geometry closure only calls it.
    private func voiceScreen(geo: GeometryProxy) -> some View {
        let width: CGFloat = geo.size.width
        let height: CGFloat = geo.size.height
        let widthCap: CGFloat = width * 0.62
        let heightCap: CGFloat = height * 0.42
        let diameter: CGFloat = min(widthCap, heightCap)
        let ring: CGFloat = diameter + 28.0
        let topPad: CGFloat = geo.safeAreaInsets.top + 12.0
        let bottomInset: CGFloat = max(geo.safeAreaInsets.bottom, 8.0)
        let bottomPad: CGFloat = bottomInset + 8.0
        return ZStack {
            Color.black
            VStack(spacing: 14) {
                Spacer(minLength: 0)
                cameraStrip
                orbStack(diameter: diameter, ring: ring)
                Text(engine.voiceState.label.uppercased())
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .tracking(2.4)
                    .foregroundStyle(settings.accentColor)
                if voice.captionsOn, !caption.isEmpty {
                    Text(hudLine(caption))
                        .font(.system(size: 15, weight: .regular, design: .monospaced))
                        .foregroundStyle(Color(white: 0.78))
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                        .frame(maxWidth: 280)
                }
                controlCluster
                askBar
                    .frame(maxWidth: 280)
                detailStack
                Spacer(minLength: 0)
            }
            .padding(.top, topPad)
            .padding(.bottom, bottomPad)
            .padding(.horizontal, 24)
        }
    }

    private func orbStack(diameter: CGFloat, ring: CGFloat) -> some View {
        ZStack {
            ReactorHUD(diameter: ring, accent: settings.accentColor)
            SkyCloudOrbView(level: engine.level, state: engine.voiceState, closing: voice.exiting,
                            tint: settings.orbTintColor, tintAmount: settings.orbTintAmount,
                            crispEdge: true)
                .frame(width: diameter, height: diameter)
                .matchedGeometryEffect(id: "voice-orb", in: orbSpace)
                .onTapGesture { voice.showTranscript.toggle() }
        }
        .frame(width: ring, height: ring)
    }

    private var controlCluster: some View {
        HStack(spacing: 8) {
            hudButton(system: "line.3.horizontal", label: "Menu", action: onMenu)
            hudButton(system: "slider.horizontal.3", label: "Voice settings", action: onSettings)
            hudButton(system: camera.isLive ? "video.fill" : "video", label: "Camera", active: camera.isLive, action: toggleCamera)
            hudButton(system: engine.microphoneMuted ? "mic.slash" : "mic", label: "Mute", action: mute)
            hudButton(system: "xmark", label: "End", action: end)
        }
    }

    @ViewBuilder
    private var cameraStrip: some View {
        if camera.isLive || camera.heldPreview != nil {
            cameraControls
        }
    }

    private var cameraControls: some View {
        let previewWidth: CGFloat = 96
        let previewHeight: CGFloat = 128
        return HStack(spacing: 10) {
            ZStack(alignment: .topTrailing) {
                livePreview(width: previewWidth, height: previewHeight)
                if camera.heldPreview != nil {
                    Button(action: { camera.discardHeld() }) {
                        Image(systemName: "xmark")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 22, height: 22)
                            .background(Circle().fill(Color.black.opacity(0.65)))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Discard photo")
                    .padding(4)
                }
            }
            VStack(spacing: 8) {
                if camera.isLive {
                    hudButton(system: "camera", label: "Snap photo", action: { camera.holdStill() })
                }
                hudButton(system: "eye", label: "Ask what you see", action: askSight)
            }
        }
    }

    private func livePreview(width: CGFloat, height: CGFloat) -> some View {
        ZStack {
            if camera.isLive {
                CameraPreview(session: camera.previewSession)
            } else {
                Color.black
            }
            if let still = camera.heldPreview {
                Image(uiImage: still)
                    .resizable()
                    .scaledToFill()
            }
        }
        .frame(width: width, height: height)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(settings.accentColor.opacity(0.75), lineWidth: 1))
    }

    private func hudButton(system: String, label: String, active: Bool = false, action: @escaping () -> Void) -> some View {
        let fill = active ? settings.accentColor.opacity(0.22) : Color.black
        return Button(action: action) {
            Image(systemName: system)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(settings.accentColor)
                .frame(width: 44, height: 44)
                .background(Circle().fill(fill))
                .overlay(Circle().stroke(settings.accentColor.opacity(0.75), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    private var askBar: some View {
        HStack(spacing: 8) {
            AttachControl()
            TextField("", text: $draft, prompt: Text("Ask JARVIS…").foregroundStyle(settings.accentColor.opacity(0.55)))
                .font(.system(size: 15, weight: .regular, design: .monospaced))
                .foregroundStyle(.white)
                .submitLabel(.send)
                .onSubmit(sendDraft)
            Button(action: startVoice) {
                Image(systemName: "waveform")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(settings.accentColor)
                    .frame(width: 32, height: 32)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Voice")
        }
        .padding(.leading, 16)
        .padding(.trailing, 8)
        .frame(height: 44)
        .background(Color.black, in: Capsule())
        .overlay(Capsule().stroke(settings.accentColor.opacity(0.55), lineWidth: 1))
    }

    private var detailStack: some View {
        VStack(spacing: 10) {
            if engine.hasContactChoices {
                CallPicker()
            }
            AttachmentChip()
            GeneratedPreview()
            if let status = engine.statusLine, !status.isEmpty {
                hudText(status)
            } else if let note = camera.note, !note.isEmpty {
                hudText(note)
            }
            if let error = engine.errorMessage, !error.isEmpty {
                hudText(error)
            }
            if voice.showTranscript {
                transcript
                    .frame(maxWidth: 320, maxHeight: 120)
            }
            if engine.pendingCallBrief != nil {
                CallBriefBar()
                    .frame(maxWidth: 320)
            }
            if engine.pendingSummary != nil {
                ApprovalCard()
                    .frame(maxWidth: 320)
            }
            AgentJobStrip()
                .frame(maxWidth: 320)
        }
    }

    private func hudText(_ raw: String) -> some View {
        Text(hudLine(raw))
            .font(.system(size: 12, weight: .medium, design: .monospaced))
            .foregroundStyle(settings.accentColor.opacity(0.9))
            .multilineTextAlignment(.center)
            .lineLimit(2)
            .frame(maxWidth: 280)
    }

    private func hudLine(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.contains("{") || trimmed.contains("[") || trimmed.contains("\"error\"") {
            return "JARVIS is busy, retrying…"
        }
        return String(trimmed.prefix(80))
    }

    private var caption: String {
        let source = engine.phase == .listening || engine.phase == .idle ? engine.transcript : engine.reply
        return source.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var transcript: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 10) {
                ForEach(engine.turns) { turn in
                    VStack(alignment: turn.role == "user" ? .trailing : .leading, spacing: 4) {
                        if turn.role != "user", !turn.reasoning.isEmpty {
                            ReasoningNote(text: turn.reasoning)
                        }
                        Text(turn.text)
                            .font(.callout)
                            .foregroundStyle(.white.opacity(0.9))
                    }
                    .frame(maxWidth: .infinity, alignment: turn.role == "user" ? .trailing : .leading)
                }
                if !engine.citations.isEmpty {
                    SourceLinks(citations: engine.citations)
                }
            }
        }
    }

    private func toggleCamera() {
        Task { await camera.toggleFromVoice() }
    }

    private func askSight() {
        engine.ask("What do you see?")
    }

    private func sendDraft() {
        let typed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        let text = typed.isEmpty && engine.attachmentName != nil ? "What is in this file?" : typed
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
