import SwiftUI
import UIKit

struct HomeScreen: View {
    @Environment(\.scenePhase) private var scenePhase
    var ringPaused: Bool
    var onMenu: () -> Void
    @State private var keyboardVisible = false
    @State private var keyboardReveal: Task<Void, Never>?

    var body: some View {
        VStack(spacing: 0) {
            topBar
                .padding(.horizontal, 20)
                .padding(.top, 8)
            stage
            SessionExtras()
            AskBar()
                .padding(.horizontal, 20)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .background(keyboardReader)
    }

    /// The ring stays in the hierarchy. Height snaps once; it does not track the keyboard curve.
    private var stage: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 8)
            Color.clear
                .aspectRatio(1.15, contentMode: .fit)
                .overlay {
                    GeometryReader { geo in
                        let side = geo.size.width * 0.65
                        JarvisRingHost(paused: ringPaused || scenePhase != .active || keyboardVisible)
                            .frame(width: side + 56, height: side + 56)
                            .position(x: geo.size.width / 2, y: geo.size.height / 2)
                    }
                }
            greeting
                .padding(.top, 16)
            LiveCaption()
            Spacer(minLength: 8)
        }
        .frame(maxHeight: keyboardVisible ? 0 : .infinity)
        .clipped()
        .opacity(keyboardVisible ? 0 : 1)
        .allowsHitTesting(!keyboardVisible)
        .accessibilityHidden(keyboardVisible)
        .animation(nil, value: keyboardVisible)
    }

    private var topBar: some View {
        ZStack {
            JarvisWordmark()
            HStack {
                Button(action: {
                    UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                    onMenu()
                }) {
                    HamburgerMark()
                        .frame(width: 44, height: 44, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Menu")
                Spacer()
            }
        }
        .frame(height: 52)
    }

    private var greeting: some View {
        VStack(spacing: 8) {
            TimelineView(.everyMinute) { context in
                Text(JarvisGreeting.line(at: context.date))
                    .font(.system(size: 26, weight: .regular))
                    .foregroundStyle(.white)
            }
            RingStateLabel()
            Text("What can I do for you?")
                .font(.system(size: 17, weight: .regular))
                .foregroundStyle(Color(hex: "#A39BB4"))
            GlanceLine()
            OfflineStrip()
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
    }

    private var keyboardReader: some View {
        Color.clear
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillChangeFrameNotification)) { note in
                guard let frame = note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect else { return }
                let duration = note.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey] as? Double ?? 0.25
                let visible = Self.keyboardCoversScreen(frame)
                keyboardReveal?.cancel()
                if visible {
                    var transaction = Transaction()
                    transaction.disablesAnimations = true
                    withTransaction(transaction) { keyboardVisible = true }
                } else if keyboardVisible {
                    let wait = duration
                    keyboardReveal = Task {
                        try? await Task.sleep(for: .seconds(wait))
                        guard !Task.isCancelled else { return }
                        var transaction = Transaction()
                        transaction.disablesAnimations = true
                        withTransaction(transaction) { keyboardVisible = false }
                    }
                }
            }
    }

    /// The keyboard frame is in window coordinates. The home view shrinks with the safe area, so its own bottom edge is not a stable measure.
    @MainActor
    private static func keyboardCoversScreen(_ frame: CGRect) -> Bool {
        let height = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first { $0.isKeyWindow }?
            .bounds.height ?? 0
        guard height > 1 else { return false }
        return frame.minY < height - 1
    }
}

/// Weather and the next event. Isolated so a refresh does not rebuild the ring.
private struct RingStateLabel: View {
    @Environment(AssistantEngine.self) private var engine

    var body: some View {
        if let label = engine.ringLabel {
            Text(label)
                .font(.system(size: 11, weight: .semibold))
                .tracking(1.6)
                .foregroundStyle(engine.interceptor ? Color(hex: "#FF5A2A") : Color(hex: "#4A7FD0"))
                .padding(.top, 2)
                .transition(.opacity)
                .animation(.easeInOut(duration: 0.25), value: label)
        }
    }
}

private struct GlanceLine: View {
    @Environment(AppSettings.self) private var settings
    @State private var glance = DayGlance.shared

    var body: some View {
        Group {
            if settings.glanceEnabled, !glance.line.isEmpty {
                Text(glance.line)
                    .font(.system(size: 13, weight: .regular))
                    .foregroundStyle(Color(hex: "#6E86A8"))
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .padding(.horizontal, 28)
                    .padding(.top, 4)
            }
        }
        .task { await glance.refresh() }
    }
}

private struct OfflineStrip: View {
    @State private var net = Reachability.shared

    var body: some View {
        if !net.online {
            Text("Offline. I'll keep messages until the line returns.")
                .font(.system(size: 13, weight: .regular))
                .foregroundStyle(Color(hex: "#A39BB4"))
                .padding(.top, 6)
        }
    }
}

/// Transcript and failures. Isolated so a live line does not rebuild the ring.
private struct LiveCaption: View {
    @Environment(AssistantEngine.self) private var engine
    @Environment(AppSettings.self) private var settings

    var body: some View {
        if engine.isSessionActive, engine.phase == .listening {
            if engine.microphoneMuted {
                caption("The microphone is muted, sir.", color: Color(hex: "#A39BB4"))
            } else if let error = engine.errorMessage, !error.isEmpty, engine.transcript.isEmpty {
                caption(JarvisLines.explain(error), color: Color(hex: "#C9C6D4"))
            } else if !engine.transcript.isEmpty {
                caption(engine.transcript, color: Color(hex: "#A39BB4"))
            } else {
                caption(JarvisLines.listening, color: Color(hex: "#7EB6FF"))
            }
        } else if engine.phase == .thinking, engine.reply.isEmpty, engine.statusLine == "JARVIS is thinking…" {
            ThinkingLine(text: "JARVIS is thinking…")
        } else if !engine.reply.isEmpty {
            caption(engine.reply, color: Color(hex: "#C9C6D4"))
        } else if let error = engine.errorMessage, !error.isEmpty {
            caption(JarvisLines.explain(error), color: Color(hex: "#C9C6D4"))
        } else if settings.captionsDefault, engine.phase == .listening, !engine.transcript.isEmpty {
            caption(engine.transcript, color: Color(hex: "#A39BB4"))
        }
    }

    private func caption(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.system(size: 15, weight: .regular))
            .foregroundStyle(color)
            .multilineTextAlignment(.center)
            .lineLimit(4)
            .padding(.horizontal, 32)
            .padding(.top, 12)
    }
}

/// A slow breath under the ring while the assistant reply is on its way.
private struct ThinkingLine: View {
    var text: String

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
            let wave = 0.5 + 0.5 * sin(context.date.timeIntervalSinceReferenceDate * 1.6)
            Text(text)
                .font(.system(size: 15, weight: .regular))
                .foregroundStyle(Color(hex: "#7EB6FF").opacity(0.55 + 0.45 * wave))
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .padding(.horizontal, 32)
                .padding(.top, 12)
        }
        .transition(.opacity)
    }
}

/// Cards that only exist while a call, file, or approval is waiting.
private struct SessionExtras: View {
    @Environment(AssistantEngine.self) private var engine
    @State private var agents = AgentStore.shared

    var body: some View {
        if !engine.deskCalls.isEmpty {
            CallTaskStrip()
                .padding(.horizontal, 20)
                .padding(.bottom, 8)
        }
        if !engine.callMessages.isEmpty {
            CallMessageStrip()
                .padding(.horizontal, 20)
                .padding(.bottom, 8)
        }
        if engine.grokConnected == false {
            Text("The Grok assistant isn't connected. I'll answer from here.")
                .font(.system(size: 13))
                .foregroundStyle(Color(hex: "#C9C6D4"))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 20)
                .padding(.bottom, 8)
        }
        if !engine.pairLinked, !engine.pairCode.isEmpty {
            PairingCard()
                .padding(.horizontal, 20)
                .padding(.bottom, 8)
        }
        if !engine.hunts.isEmpty {
            HuntStrip()
                .padding(.horizontal, 20)
                .padding(.bottom, 8)
        }
        if engine.pendingCallBrief != nil {
            CallBriefBar()
                .padding(.horizontal, 20)
                .padding(.bottom, 8)
        }
        if engine.pendingSummary != nil {
            ApprovalCard()
                .padding(.horizontal, 20)
                .padding(.bottom, 8)
        }
        if engine.hasContactChoices {
            CallPicker()
                .padding(.horizontal, 20)
                .padding(.bottom, 8)
        }
        if engine.attachmentName != nil {
            AttachmentChip()
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 20)
                .padding(.bottom, 8)
        }
        if engine.generatedPreview != nil {
            GeneratedPreview()
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.bottom, 8)
        }
        if agents.jobs.contains(where: { $0.status != .done }) {
            AgentJobStrip()
                .padding(.horizontal, 12)
                .padding(.bottom, 8)
        }
        if !engine.citations.isEmpty {
            SourceLinks(citations: engine.citations)
                .padding(.horizontal, 20)
                .padding(.bottom, 8)
        }
    }
}

private struct AskBar: View {
    @Environment(AssistantEngine.self) private var engine
    @State private var draft = ""
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "waveform")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(Color(hex: "#4A7FD0"))
                .frame(width: 22)
            TextField("", text: $draft, prompt: Text("Ask Jarvis anything...").foregroundStyle(Color(hex: "#8E929C")))
                .font(.system(size: 16, weight: .regular))
                .foregroundStyle(.white)
                .focused($focused)
                .submitLabel(.send)
                .textInputAutocapitalization(.sentences)
                .onSubmit(send)
            Button(action: micTapped) {
                ZStack {
                    Circle().fill(engine.isSessionActive ? Color(hex: "#2E8BFF").opacity(0.92) : Color.white.opacity(0.04))
                    Circle()
                        .stroke(Color(hex: "#2E8BFF"), lineWidth: 1.5)
                        .shadow(color: Color(hex: "#2E8BFF").opacity(engine.isSessionActive ? 0.95 : 0.75), radius: 6)
                    Image(systemName: engine.isSessionActive ? "waveform" : "mic.fill")
                        .font(.system(size: 15, weight: .regular))
                        .foregroundStyle(.white)
                }
                .frame(width: 36, height: 36)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(engine.isSessionActive ? "Stop listening" : "Microphone")
            .accessibilityValue(engine.phase == .listening ? "Listening" : "")
        }
        .padding(.leading, 16)
        .padding(.trailing, 8)
        .frame(height: 52)
        .background(Color(hex: "#0B1220").opacity(0.72), in: Capsule())
        .overlay(Capsule().stroke(Color(hex: "#2E8BFF").opacity(0.55), lineWidth: 0.8))
        .shadow(color: Color(hex: "#2E8BFF").opacity(0.28), radius: 8)
        .padding(.bottom, 12)
    }

    private func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        draft = ""
        focused = false
        JarvisHaptics.tap()
        engine.ask(text, agent: true)
    }

    private func micTapped() {
        JarvisHaptics.tap()
        focused = false
        if engine.isSessionActive {
            Task { await engine.endSession(reason: "mic-button") }
        } else {
            Task { await engine.startSession(continuous: true) }
        }
    }
}

struct DrawerScrim: View {
    var model: DrawerModel

    var body: some View {
        Color.black.opacity(0.5 * model.fraction)
            .ignoresSafeArea()
            .allowsHitTesting(!model.panning && model.fraction > 0.92)
            .onTapGesture { model.setOpen(false) }
    }
}

struct DrawerSlide: View {
    var model: DrawerModel
    var width: CGFloat
    var menu: DrawerMenu

    var body: some View {
        menu
            .equatable()
            .frame(width: width, alignment: .top)
            .background(JarvisBackdrop().ignoresSafeArea())
            .compositingGroup()
            .shadow(color: .black.opacity(0.4), radius: 16, x: 6, y: 0)
            .offset(x: model.fraction * width - width)
    }
}

struct DrawerMenu: View, Equatable {
    var model: DrawerModel
    var items: [DrawerItem]
    @State private var log = ConversationLog.shared
    @State private var editingPins = false

    static func == (lhs: DrawerMenu, rhs: DrawerMenu) -> Bool {
        lhs.model === rhs.model && lhs.items.count == rhs.items.count
    }

    var body: some View {
        List {
            Section {
                header.drawerRow()
                menuRow(title: "Home", subtitle: "Main screen", icon: "house", selected: true) {
                    model.onSelect?(nil)
                }
                .drawerRow()
                ForEach(items) { item in
                    menuRow(title: item.title, subtitle: item.subtitle, icon: item.icon, selected: false) {
                        model.onSelect?(item.route)
                    }
                    .drawerRow()
                }
            }
            Section {
                divider
                HStack {
                    Text("PINNED")
                        .font(.system(size: 11, weight: .semibold))
                        .tracking(1.6)
                        .foregroundStyle(Color.white.opacity(0.45))
                    Spacer()
                    Button(editingPins ? "Done" : "Edit") { editingPins.toggle() }
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(Color(hex: "#4A7FD0"))
                        .buttonStyle(.plain)
                }
                .padding(.horizontal, 20)
                .padding(.top, 8)
                .padding(.bottom, 4)
                .drawerRow()
                if log.pinned.isEmpty {
                    Text(editingPins ? "Pin a conversation below." : "No pinned conversations.")
                        .font(.system(size: 13))
                        .foregroundStyle(Color(hex: "#8E8A99"))
                        .padding(.horizontal, 20)
                        .padding(.bottom, 8)
                        .drawerRow()
                }
                ForEach(log.pinned) { convo in
                    pinnedCard(convo).drawerRow()
                }
                .onMove { offsets, destination in
                    log.movePinned(from: offsets, to: destination)
                }
            }
            Section {
                divider
                Text("RECENTS")
                    .font(.system(size: 11, weight: .semibold))
                    .tracking(1.6)
                    .foregroundStyle(Color.white.opacity(0.45))
                    .padding(.horizontal, 20)
                    .padding(.top, 8)
                    .padding(.bottom, 4)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .drawerRow()
                if log.recents.isEmpty {
                    Text("No conversations yet.")
                        .font(.system(size: 13))
                        .foregroundStyle(Color(hex: "#8E8A99"))
                        .padding(.horizontal, 20)
                        .padding(.bottom, 8)
                        .drawerRow()
                }
                ForEach(log.recents) { convo in
                    recentRow(convo).drawerRow()
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .scrollIndicators(.hidden)
        .environment(\.defaultMinListRowHeight, 8)
        .environment(\.editMode, .constant(editingPins ? .active : .inactive))
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            JarvisWordmark(alignment: .leading)
            Spacer(minLength: 8)
            Button {
                model.setOpen(false)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 13, weight: .light))
                    .foregroundStyle(Color.white.opacity(0.92))
                    .frame(width: 32, height: 32)
                    .overlay(Circle().stroke(Color.white.opacity(0.28), lineWidth: 1))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close menu")
        }
        .padding(.horizontal, 20)
        .padding(.top, 8)
        .padding(.bottom, 12)
    }

    private var divider: some View {
        Rectangle()
            .fill(Color.white.opacity(0.10))
            .frame(height: 0.5)
            .padding(.horizontal, 20)
            .padding(.top, 8)
            .padding(.bottom, 4)
            .drawerRow()
    }

    private func menuRow(title: String, subtitle: String, icon: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: icon)
                    .font(.system(size: 18, weight: .light))
                    .foregroundStyle(Color(hex: "#C5D0DE"))
                    .frame(width: 26)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 16, weight: .regular))
                        .foregroundStyle(.white)
                    Text(subtitle)
                        .font(.system(size: 12, weight: .regular))
                        .foregroundStyle(Color(hex: "#8E8A99"))
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(selected ? Color(hex: "#2E8BFF").opacity(0.12) : Color.clear)
            .overlay(alignment: .leading) {
                if selected {
                    Rectangle().fill(Color(hex: "#2E8BFF")).frame(width: 3)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func pinnedCard(_ convo: StoredConversation) -> some View {
        HStack(spacing: 12) {
            conversationLabel(convo)
            if editingPins {
                Button {
                    log.setPinned(convo.id, false)
                } label: {
                    Image(systemName: "pin.slash")
                        .font(.system(size: 13, weight: .light))
                        .foregroundStyle(Color(hex: "#8E8A99"))
                        .frame(width: 32, height: 32)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Unpin")
            } else {
                Image(systemName: "pin")
                    .font(.system(size: 13, weight: .light))
                    .foregroundStyle(Color(hex: "#8E8A99"))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 12)
        .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .padding(.horizontal, 16)
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onTapGesture { if !editingPins { model.onSelect?(.conversation(convo.id)) } }
        .contextMenu { conversationMenu(convo) }
    }

    private func recentRow(_ convo: StoredConversation) -> some View {
        HStack(spacing: 12) {
            conversationLabel(convo)
            if editingPins {
                Button {
                    log.setPinned(convo.id, true)
                } label: {
                    Image(systemName: "pin")
                        .font(.system(size: 13, weight: .light))
                        .foregroundStyle(Color(hex: "#4A7FD0"))
                        .frame(width: 32, height: 32)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Pin")
            } else {
                Text(ConversationLog.timeLabel(convo.updatedAt))
                    .font(.system(size: 12, weight: .regular))
                    .foregroundStyle(Color(hex: "#8E8A99"))
                    .monospacedDigit()
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .contentShape(Rectangle())
        .onTapGesture { if !editingPins { model.onSelect?(.conversation(convo.id)) } }
        .contextMenu { conversationMenu(convo) }
    }

    private func conversationLabel(_ convo: StoredConversation) -> some View {
        HStack(spacing: 12) {
            Image(systemName: convo.symbol)
                .font(.system(size: 15, weight: .light))
                .foregroundStyle(Color(hex: "#C5D0DE"))
                .frame(width: 22)
            Text(convo.title)
                .font(.system(size: 15, weight: .regular))
                .foregroundStyle(.white)
                .lineLimit(1)
            Spacer(minLength: 8)
        }
    }

    @ViewBuilder
    private func conversationMenu(_ convo: StoredConversation) -> some View {
        Button(convo.pinned ? "Unpin" : "Pin") {
            log.setPinned(convo.id, !convo.pinned)
        }
        Button("Delete", role: .destructive) {
            log.remove(convo.id)
        }
    }
}
