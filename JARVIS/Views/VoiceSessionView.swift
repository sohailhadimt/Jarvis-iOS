import SwiftUI

/// In-chat voice is the default. Separate mode is a full-screen cloud with the same controls.
struct VoiceSessionView: View {
    @Environment(AssistantEngine.self) private var engine
    @Environment(AppSettings.self) private var settings
    @State private var captionsOn = false
    @State private var didChooseCaptions = false

    private var separate: Bool { settings.voiceSeparateMode }

    var body: some View {
        GeometryReader { geo in
            let bottom = geo.safeAreaInsets.bottom
            ZStack {
                VoiceLook.ink.ignoresSafeArea()
                if separate {
                    fullScreen(bottom: bottom, width: geo.size.width)
                } else {
                    inChat(bottom: bottom)
                }
            }
        }
        .onAppear {
            guard !didChooseCaptions else { return }
            captionsOn = !settings.voiceSeparateMode
            didChooseCaptions = true
        }
    }

    private func fullScreen(bottom: CGFloat, width: CGFloat) -> some View {
        VStack(spacing: 18) {
            Spacer(minLength: 0)
            OrbView(level: engine.level, phase: engine.phase,
                    primary: settings.primaryColor, accent: settings.accentColor,
                    sessionActive: engine.isSessionActive,
                    executing: engine.cloudExecuting || engine.phase == .thinking,
                    hasError: engine.errorMessage != nil,
                    reply: engine.reply)
                .frame(width: width * 0.78, height: width * 0.78)
            if captionsOn {
                captionBlock
                    .frame(maxWidth: 320)
            }
            Spacer(minLength: 0)
            if engine.pendingSummary != nil {
                approvalCard
                    .padding(.horizontal, 22)
            }
            controls
                .padding(.bottom, max(bottom, 12))
        }
    }

    private func inChat(bottom: CGFloat) -> some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        if captionsOn {
                            ForEach(engine.turns) { turn in
                                bubble(turn)
                                    .id(turn.id)
                            }
                            if engine.phase == .listening, !engine.transcript.isEmpty {
                                Text(engine.transcript)
                                    .font(.body.weight(.light))
                                    .foregroundStyle(.white.opacity(0.45))
                                    .frame(maxWidth: .infinity, alignment: .trailing)
                                    .id("live")
                            }
                        }
                    }
                    .padding(.horizontal, 18)
                    .padding(.top, 12)
                    .padding(.bottom, 8)
                }
                .onChange(of: engine.turns.count) { _, _ in
                    scroll(proxy)
                }
                .onChange(of: engine.transcript) { _, _ in
                    scroll(proxy)
                }
            }
            if captionsOn, let live = liveCaption {
                Text(live)
                    .font(.footnote.weight(.light))
                    .foregroundStyle(.white.opacity(0.55))
                    .lineLimit(2)
                    .padding(.horizontal, 24)
                    .padding(.bottom, 6)
            }
            if engine.pendingSummary != nil {
                approvalCard
                    .padding(.horizontal, 16)
                    .padding(.bottom, 8)
            }
            OrbView(level: engine.level, phase: engine.phase,
                    primary: settings.primaryColor, accent: settings.accentColor,
                    sessionActive: true,
                    executing: engine.cloudExecuting || engine.phase == .thinking,
                    hasError: engine.errorMessage != nil)
                .frame(width: 92, height: 92)
                .padding(.bottom, 8)
            controls
                .padding(.bottom, max(bottom, 10))
        }
    }

    private var liveCaption: String? {
        if engine.phase == .speaking, !engine.reply.isEmpty { return engine.reply }
        if !engine.transcript.isEmpty { return engine.transcript }
        return nil
    }

    private var captionBlock: some View {
        Text(liveCaption ?? phaseCaption)
            .font(.body.weight(.light))
            .foregroundStyle(.white.opacity(0.82))
            .multilineTextAlignment(.center)
            .lineLimit(4)
    }

    private var phaseCaption: String {
        if engine.microphoneMuted { return "Muted" }
        return engine.phase.label
    }

    private func bubble(_ turn: VoiceTurn) -> some View {
        let mine = turn.role == "user"
        return HStack {
            if mine { Spacer(minLength: 48) }
            Text(turn.text)
                .font(.body.weight(.light))
                .foregroundStyle(.white.opacity(mine ? 0.92 : 1))
                .padding(.horizontal, mine ? 14 : 0)
                .padding(.vertical, mine ? 10 : 0)
                .background {
                    if mine {
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .fill(Color.white.opacity(0.12))
                    }
                }
            if !mine { Spacer(minLength: 36) }
        }
    }

    private var approvalCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(engine.pendingSummary ?? "")
                .font(.subheadline.weight(.regular))
                .foregroundStyle(.white)
                .fixedSize(horizontal: false, vertical: true)
            Text("Tap Approve to go ahead. A spoken yes does not confirm it.")
                .font(.caption)
                .foregroundStyle(.white.opacity(0.55))
            HStack(spacing: 10) {
                Button("Decline") { engine.cancelPendingAction() }
                    .buttonStyle(.bordered)
                Button("Approve") { engine.confirmPendingAction() }
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(VoiceLook.blue.opacity(0.18))
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(VoiceLook.lavender.opacity(0.45), lineWidth: 0.7)
        }
    }

    private var controls: some View {
        HStack {
            roundControl(systemImage: captionsOn ? "captions.bubble.fill" : "captions.bubble",
                         label: "Captions", size: 52) {
                captionsOn.toggle()
            }
            Spacer()
            roundControl(systemImage: "xmark", label: "End", size: 68, prominent: true) {
                Task { await engine.endSession(reason: "voice-end") }
            }
            Spacer()
            roundControl(systemImage: engine.microphoneMuted ? "mic.slash.fill" : "mic.fill",
                         label: engine.microphoneMuted ? "Unmute" : "Mute", size: 52) {
                engine.toggleMute()
            }
        }
        .padding(.horizontal, 28)
        .tint(VoiceLook.mist)
    }

    private func roundControl(systemImage: String, label: String, size: CGFloat,
                              prominent: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: prominent ? 22 : 18, weight: .medium))
                .foregroundStyle(VoiceLook.mist)
                .frame(width: size, height: size)
                .background {
                    Circle().fill(Color.white.opacity(prominent ? 0.16 : 0.08))
                }
                .overlay {
                    Circle().stroke(Color.white.opacity(0.18), lineWidth: 0.6)
                }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    private func scroll(_ proxy: ScrollViewProxy) {
        if engine.phase == .listening, !engine.transcript.isEmpty {
            withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo("live", anchor: .bottom) }
        } else if let last = engine.turns.last?.id {
            withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(last, anchor: .bottom) }
        }
    }
}
