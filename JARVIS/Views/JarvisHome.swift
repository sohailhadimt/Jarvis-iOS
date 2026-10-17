import Observation
import SwiftUI
import UIKit

extension Notification.Name {
    static let jarvisOpenStandBy = Notification.Name("jarvisOpenStandBy")
}

private enum DrawerRoute: Hashable {
    case conversations
    case conversation(UUID)
    case calendar
    case tasks
    case apps
    case navigate
    case camera
    case search
    case files
    case agents
    case approvals
    case calls
    case memory
    case news
    case settings
}

private struct DrawerItem: Identifiable {
    var route: DrawerRoute
    var title: String
    var subtitle: String
    var icon: String
    var id: String { title }
}

/// Tracks a horizontal drag without resetting when the drawer offset redraws.
private final class DrawerPan {
    var axis = 0
    var origin: CGFloat = 0
}

/// Home screen: navy field, glowing ring, greeting, ask bar, and the side drawer.
struct JarvisShell: View {
    @Environment(AssistantEngine.self) private var engine
    @Environment(\.scenePhase) private var scenePhase
    var openStandBy: () -> Void

    @State private var log = ConversationLog.shared
    @State private var agents = AgentStore.shared
    @State private var route: DrawerRoute?
    @State private var fraction: CGFloat = 0
    @State private var pan = DrawerPan()
    @State private var panning = false
    @State private var editingPins = false
    @State private var draft = ""
    @State private var keyboardOverlap: CGFloat = 0
    @FocusState private var composerFocused: Bool

    private let menu: [DrawerItem] = [
        DrawerItem(route: .conversations, title: "Conversations", subtitle: "Chat history", icon: "bubble.left"),
        DrawerItem(route: .calendar, title: "Calendar", subtitle: "Events & reminders", icon: "calendar"),
        DrawerItem(route: .tasks, title: "Tasks", subtitle: "To-dos & plans", icon: "checklist"),
        DrawerItem(route: .apps, title: "Apps", subtitle: "Open & control", icon: "square.grid.2x2"),
        DrawerItem(route: .navigate, title: "Navigate", subtitle: "Maps & travel", icon: "location"),
        DrawerItem(route: .camera, title: "Camera", subtitle: "Capture & scan", icon: "camera"),
        DrawerItem(route: .search, title: "Search", subtitle: "Web & research", icon: "magnifyingglass"),
        DrawerItem(route: .files, title: "Files", subtitle: "Documents & media", icon: "folder"),
        DrawerItem(route: .agents, title: "Agents", subtitle: "Team & missions", icon: "person.3"),
        DrawerItem(route: .approvals, title: "Approvals", subtitle: "Review & confirm", icon: "checkmark.circle"),
        DrawerItem(route: .calls, title: "Calls", subtitle: "Log & screening", icon: "phone"),
        DrawerItem(route: .memory, title: "Memory", subtitle: "Facts & notes", icon: "brain"),
        DrawerItem(route: .news, title: "News", subtitle: "Headlines & briefings", icon: "newspaper"),
        DrawerItem(route: .settings, title: "Settings", subtitle: "Preferences", icon: "gearshape")
    ]

    var body: some View {
        NavigationStack {
            ZStack {
                JarvisBackdrop().ignoresSafeArea()
                GeometryReader { geo in
                    let drawerW = geo.size.width * 0.70
                    ZStack(alignment: .leading) {
                        home(in: geo)
                        Color.black.opacity(0.5 * fraction)
                            .ignoresSafeArea()
                            .allowsHitTesting(!panning && fraction > 0.92)
                            .onTapGesture { setDrawer(open: false) }
                        drawer(width: drawerW)
                            .frame(width: drawerW, height: geo.size.height, alignment: .top)
                            .background(JarvisBackdrop().ignoresSafeArea())
                            .offset(x: fraction * drawerW - drawerW)
                            .shadow(color: .black.opacity(0.45 * fraction), radius: 18, x: 8, y: 0)
                    }
                    .simultaneousGesture(drag(drawerWidth: drawerW))
                    .background(keyboardReader)
                }
            }
            .navigationDestination(item: $route) { destination($0) }
            .toolbar(.hidden, for: .navigationBar)
        }
        .preferredColorScheme(.dark)
        .onAppear { log.absorb(engine.turns) }
        .onChange(of: engine.turns.count) { _, _ in log.absorb(engine.turns) }
        .onChange(of: engine.phase) { _, phase in
            if phase == .idle || phase == .listening { log.absorb(engine.turns) }
        }
        .onReceive(NotificationCenter.default.publisher(for: .jarvisOpenStandBy)) { _ in
            openStandBy()
        }
    }

    private func home(in geo: GeometryProxy) -> some View {
        VStack(spacing: 0) {
            topBar
                .padding(.horizontal, 18)
                .padding(.top, 6)
            if keyboardOverlap == 0 {
                Spacer(minLength: 8)
                JarvisRing(level: engine.level, phase: engine.phase,
                           diameter: geo.size.width * 0.65,
                           paused: scenePhase != .active)
                greeting
                    .padding(.top, 18)
                liveCaption
                Spacer(minLength: 8)
            } else {
                Spacer(minLength: 8)
            }
            sessionExtras
            composer
                .padding(.horizontal, 16)
                .padding(.bottom, 12 + keyboardOverlap)
        }
        .frame(width: geo.size.width, height: geo.size.height)
    }

    private var topBar: some View {
        ZStack {
            JarvisWordmark()
            HStack {
                Button {
                    composerFocused = false
                    setDrawer(open: true)
                } label: {
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
        VStack(spacing: 6) {
            TimelineView(.everyMinute) { context in
                Text(JarvisGreeting.line(at: context.date))
                    .font(.system(size: 26, weight: .regular))
                    .foregroundStyle(.white)
            }
            Text("What can I do for you?")
                .font(.system(size: 17, weight: .regular))
                .foregroundStyle(Color(hex: "#A39BB4"))
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private var liveCaption: some View {
        if let error = engine.errorMessage, !error.isEmpty {
            caption(error, color: Color(hex: "#D07070"))
        } else if engine.phase == .listening, !engine.transcript.isEmpty {
            caption(engine.transcript, color: Color(hex: "#A39BB4"))
        } else if engine.phase == .speaking || engine.phase == .thinking, !engine.reply.isEmpty {
            caption(engine.reply, color: Color(hex: "#C9C6D4"))
        }
    }

    private func caption(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.system(size: 15, weight: .regular))
            .foregroundStyle(color)
            .multilineTextAlignment(.center)
            .lineLimit(2)
            .padding(.horizontal, 32)
            .padding(.top, 10)
    }

    @ViewBuilder
    private var sessionExtras: some View {
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
        if engine.attachmentName != nil {
            AttachmentChip()
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.bottom, 6)
        }
        if engine.generatedPreview != nil {
            GeneratedPreview()
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.bottom, 6)
        }
        if agents.jobs.contains(where: { $0.status != .done }) {
            AgentJobStrip()
                .padding(.horizontal, 12)
                .padding(.bottom, 4)
        }
        if !engine.citations.isEmpty {
            SourceLinks(citations: engine.citations)
                .padding(.horizontal, 20)
                .padding(.bottom, 8)
        }
    }

    private var composer: some View {
        HStack(spacing: 10) {
            Image(systemName: "waveform")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(Color(hex: "#4A7FD0"))
                .frame(width: 22)
            TextField("", text: $draft, prompt: Text("Ask Jarvis anything...").foregroundStyle(Color(hex: "#8E929C")))
                .font(.system(size: 16, weight: .regular))
                .foregroundStyle(.white)
                .focused($composerFocused)
                .submitLabel(.send)
                .textInputAutocapitalization(.sentences)
                .onSubmit(sendDraft)
            Button(action: micTapped) {
                ZStack {
                    Circle()
                        .fill(Color.white.opacity(0.04))
                    Circle()
                        .stroke(Color(hex: "#2E8BFF"), lineWidth: 1.5)
                        .shadow(color: Color(hex: "#2E8BFF").opacity(engine.isSessionActive ? 0.95 : 0.75), radius: 6)
                    Image(systemName: "mic.fill")
                        .font(.system(size: 15, weight: .regular))
                        .foregroundStyle(.white)
                }
                .frame(width: 36, height: 36)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(engine.isSessionActive ? "Stop listening" : "Microphone")
        }
        .padding(.leading, 16)
        .padding(.trailing, 6)
        .frame(height: 52)
        .background(Color(hex: "#0B1220").opacity(0.72), in: Capsule())
        .overlay(Capsule().stroke(Color(hex: "#2E8BFF").opacity(0.55), lineWidth: 0.8))
        .shadow(color: Color(hex: "#2E8BFF").opacity(0.28), radius: 8)
    }

    private var keyboardReader: some View {
        GeometryReader { proxy in
            Color.clear
                .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillChangeFrameNotification)) { note in
                    guard let frame = note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect else { return }
                    let overlap = max(0, proxy.frame(in: .global).maxY - frame.minY)
                    let duration = note.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey] as? Double ?? 0.25
                    withAnimation(.easeOut(duration: duration)) {
                        keyboardOverlap = overlap
                    }
                }
        }
    }

    private func drag(drawerWidth: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 16, coordinateSpace: .global)
            .onChanged { value in
                guard drawerWidth > 1 else { return }
                let dx = value.translation.width
                let dy = value.translation.height
                if pan.axis == 0 {
                    if abs(dx) < 10 && abs(dy) < 10 { return }
                    pan.axis = abs(dx) > abs(dy) * 1.15 ? 1 : 2
                    if pan.axis == 1 {
                        pan.origin = fraction
                        panning = true
                        composerFocused = false
                    }
                }
                guard pan.axis == 1 else { return }
                let next = pan.origin + dx / drawerWidth
                var transaction = Transaction()
                transaction.disablesAnimations = true
                withTransaction(transaction) {
                    fraction = min(max(next, 0), 1)
                }
            }
            .onEnded { value in
                defer {
                    pan.axis = 0
                    panning = false
                }
                guard pan.axis == 1, drawerWidth > 1 else { return }
                let flick = value.predictedEndTranslation.width - value.translation.width
                let projected = pan.origin + value.predictedEndTranslation.width / drawerWidth
                let open: Bool
                if flick > 70 { open = true }
                else if flick < -70 { open = false }
                else { open = projected > 0.4 }
                setDrawer(open: open)
            }
    }

    private func setDrawer(open: Bool) {
        withAnimation(.spring(response: 0.36, dampingFraction: 0.88)) {
            fraction = open ? 1 : 0
        }
    }

    private func sendDraft() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        draft = ""
        composerFocused = false
        engine.ask(text)
    }

    private func micTapped() {
        composerFocused = false
        if engine.isSessionActive {
            Task { await engine.endSession(reason: "mic-button") }
        } else {
            Task { await engine.startSession(continuous: true) }
        }
    }

    private func present(_ route: DrawerRoute) {
        setDrawer(open: false)
        self.route = route
    }

    private func drawer(width: CGFloat) -> some View {
        List {
            Section {
                drawerHeader
                    .drawerRow()
                menuRow(title: "Home", subtitle: "Main screen", icon: "house", selected: true) {
                    route = nil
                    setDrawer(open: false)
                }
                .drawerRow()
                ForEach(menu) { item in
                    menuRow(title: item.title, subtitle: item.subtitle, icon: item.icon, selected: false) {
                        present(item.route)
                    }
                    .drawerRow()
                }
            }
            Section {
                drawerDivider
                HStack {
                    Text("PINNED")
                        .font(.system(size: 11, weight: .semibold))
                        .tracking(1.6)
                        .foregroundStyle(Color.white.opacity(0.45))
                    Spacer()
                    Button(editingPins ? "Done" : "Edit") {
                        editingPins.toggle()
                    }
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Color(hex: "#4A7FD0"))
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 18)
                .padding(.top, 8)
                .padding(.bottom, 4)
                .drawerRow()
                if log.pinned.isEmpty {
                    Text(editingPins ? "Pin a conversation below." : "No pinned conversations.")
                        .font(.system(size: 13))
                        .foregroundStyle(Color(hex: "#8E8A99"))
                        .padding(.horizontal, 18)
                        .padding(.bottom, 6)
                        .drawerRow()
                }
                ForEach(log.pinned) { convo in
                    pinnedCard(convo)
                        .drawerRow()
                }
                .onMove { offsets, destination in
                    log.movePinned(from: offsets, to: destination)
                }
            }
            Section {
                drawerDivider
                Text("RECENTS")
                    .font(.system(size: 11, weight: .semibold))
                    .tracking(1.6)
                    .foregroundStyle(Color.white.opacity(0.45))
                    .padding(.horizontal, 18)
                    .padding(.top, 8)
                    .padding(.bottom, 4)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .drawerRow()
                if log.recents.isEmpty {
                    Text("No conversations yet.")
                        .font(.system(size: 13))
                        .foregroundStyle(Color(hex: "#8E8A99"))
                        .padding(.horizontal, 18)
                        .padding(.bottom, 8)
                        .drawerRow()
                }
                ForEach(log.recents) { convo in
                    recentRow(convo)
                        .drawerRow()
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .scrollIndicators(.hidden)
        .environment(\.defaultMinListRowHeight, 8)
        .environment(\.editMode, .constant(editingPins ? .active : .inactive))
        .frame(width: width)
    }

    private var drawerDivider: some View {
        Rectangle()
            .fill(Color.white.opacity(0.10))
            .frame(height: 0.5)
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 4)
            .drawerRow()
    }

    private var drawerHeader: some View {
        HStack(alignment: .center, spacing: 12) {
            JarvisWordmark(alignment: .leading)
            Spacer(minLength: 8)
            Button {
                setDrawer(open: false)
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
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 10)
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
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(selected ? Color(hex: "#2E8BFF").opacity(0.12) : Color.clear)
            .overlay(alignment: .leading) {
                if selected {
                    Rectangle()
                        .fill(Color(hex: "#2E8BFF"))
                        .frame(width: 3)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func pinnedCard(_ convo: StoredConversation) -> some View {
        HStack(spacing: 10) {
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
        .padding(.horizontal, 14)
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onTapGesture { if !editingPins { present(.conversation(convo.id)) } }
        .contextMenu { conversationMenu(convo) }
    }

    private func recentRow(_ convo: StoredConversation) -> some View {
        HStack(spacing: 10) {
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
        .padding(.horizontal, 18)
        .padding(.vertical, 11)
        .contentShape(Rectangle())
        .onTapGesture { if !editingPins { present(.conversation(convo.id)) } }
        .contextMenu { conversationMenu(convo) }
    }

    private func conversationLabel(_ convo: StoredConversation) -> some View {
        HStack(spacing: 10) {
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

    @ViewBuilder
    private func destination(_ route: DrawerRoute) -> some View {
        switch route {
        case .conversations:
            ConversationIndex()
        case .conversation(let id):
            ConversationPage(id: id)
        case .calendar:
            CalendarHub()
        case .tasks:
            CloudTasksView()
        case .apps:
            IntegrationsSettingsView()
        case .navigate:
            NavigateHub()
        case .camera:
            VisionStudioView()
        case .search:
            SearchHub()
        case .files:
            FilesHub()
        case .agents:
            AgentsView()
        case .approvals:
            CloudApprovalsView()
        case .calls:
            CallLogView()
        case .memory:
            CloudMemoryGate()
        case .news:
            NewsPulseView()
        case .settings:
            SettingsView()
        }
    }
}

private extension View {
    func drawerRow() -> some View {
        listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
    }
}

// MARK: - Backdrop, wordmark, ring

struct JarvisBackdrop: View {
    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color(hex: "#05080F"), Color(hex: "#000000")],
                startPoint: .top,
                endPoint: .bottom
            )
            RadialGradient(
                stops: [
                    .init(color: .clear, location: 0.42),
                    .init(color: Color.black.opacity(0.28), location: 0.78),
                    .init(color: Color.black.opacity(0.62), location: 1)
                ],
                center: .center,
                startRadius: 40,
                endRadius: 640
            )
        }
    }
}

private struct JarvisWordmark: View {
    var alignment: HorizontalAlignment = .center
    private let titleSize: CGFloat = 20
    private let subtitleSize: CGFloat = 9

    var body: some View {
        VStack(alignment: alignment, spacing: 3) {
            Text("JARVIS")
                .font(.system(size: titleSize, weight: .thin))
                .tracking(titleSize * 0.6)
                .foregroundStyle(.white)
                .padding(.trailing, -(titleSize * 0.6))
                .accessibilityLabel("JARVIS")
            Text("ALWAYS WITH YOU")
                .font(.system(size: subtitleSize, weight: .medium))
                .tracking(subtitleSize * 0.28)
                .foregroundStyle(Color(hex: "#4A7FD0"))
        }
        .accessibilityElement(children: .combine)
    }
}

private struct HamburgerMark: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            bar(18)
            bar(11)
            bar(18)
        }
        .foregroundStyle(Color(hex: "#B7C3D3"))
    }

    private func bar(_ width: CGFloat) -> some View {
        Capsule().frame(width: width, height: 1.15)
    }
}

private enum JarvisGreeting {
    static func line(at date: Date, name: String = "Sohail") -> String {
        let hour = Calendar.current.component(.hour, from: date)
        let part: String
        if hour < 12 {
            part = "morning"
        } else if hour < 17 {
            part = "afternoon"
        } else {
            part = "evening"
        }
        return "Good \(part), \(name)."
    }
}

/// Eased 60fps follow of playback level, mic level, or a slow idle breath.
private final class RingMotion {
    var value = 0.22
    var stamp: TimeInterval = 0

    func sample(level: Double, phase: JarvisPhase, now: TimeInterval) -> Double {
        let dt = stamp == 0 ? 1.0 / 60.0 : min(0.05, max(0.001, now - stamp))
        stamp = now
        let clamped = min(1, max(0, level))
        let target: Double
        let tau: Double
        switch phase {
        case .speaking:
            target = 0.34 + clamped * 0.66
            tau = 0.055
        case .listening:
            target = 0.18 + clamped * 0.28
            tau = 0.14
        case .thinking:
            target = 0.28 + 0.05 * (0.5 + 0.5 * sin(now * 2.2))
            tau = 0.18
        case .idle:
            target = 0.18 + 0.07 * (0.5 + 0.5 * sin(now * 0.85))
            tau = 0.45
        }
        let alpha = 1 - exp(-dt / tau)
        value += (target - value) * alpha
        value = min(1.15, max(0, value))
        return value
    }
}

private struct JarvisRing: View {
    var level: Double
    var phase: JarvisPhase
    var diameter: CGFloat
    var paused: Bool
    @State private var motion = RingMotion()

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60.0, paused: paused)) { context in
            let pulse = motion.sample(level: level, phase: phase, now: context.date.timeIntervalSinceReferenceDate)
            VStack(spacing: 0) {
                ring(pulse)
                floor(pulse)
                    .padding(.top, 8)
            }
        }
        .accessibilityLabel("JARVIS")
    }

    private func ring(_ pulse: Double) -> some View {
        let rim = 2.5 + pulse * 1.8
        let bloom = Color(hex: "#2E8BFF")
        return ZStack {
            Circle()
                .stroke(bloom.opacity(0.55), lineWidth: 16 + pulse * 22)
                .blur(radius: 16 + pulse * 14)
            Circle()
                .stroke(bloom.opacity(0.9), lineWidth: 7 + pulse * 12)
                .blur(radius: 7 + pulse * 10)
            Circle()
                .fill(
                    RadialGradient(
                        colors: [Color(hex: "#070C16"), Color(hex: "#05080F"), Color(hex: "#02040A")],
                        center: .center,
                        startRadius: diameter * 0.05,
                        endRadius: diameter * 0.48
                    )
                )
                .padding(rim * 0.5 + 1.5)
            Circle()
                .stroke(Color.white.opacity(0.20), lineWidth: 1)
                .padding(diameter * 0.065)
            Circle()
                .stroke(
                    LinearGradient(
                        colors: [Color.white, Color(red: 0.78, green: 0.90, blue: 1)],
                        startPoint: .top,
                        endPoint: .bottom
                    ),
                    lineWidth: rim
                )
            Ellipse()
                .fill(Color.white)
                .frame(width: diameter * 0.20, height: 8 + pulse * 6)
                .blur(radius: 5)
                .opacity(0.8 + min(pulse, 0.2))
                .offset(y: diameter * 0.5 - rim)
            Ellipse()
                .fill(Color.white.opacity(0.85))
                .frame(width: diameter * 0.32, height: 16)
                .blur(radius: 10)
                .opacity(0.35 + pulse * 0.4)
                .offset(y: diameter * 0.5 - 2)
        }
        .frame(width: diameter, height: diameter)
    }

    private func floor(_ pulse: Double) -> some View {
        let bloom = Color(hex: "#2E8BFF")
        return ZStack {
            Capsule()
                .fill(
                    LinearGradient(
                        colors: [.clear, bloom.opacity(0.45 + pulse * 0.35), .clear],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
                .frame(width: diameter * 0.92, height: 14 + pulse * 10)
                .blur(radius: 8 + pulse * 6)
            Capsule()
                .fill(
                    LinearGradient(
                        colors: [
                            .clear,
                            bloom.opacity(0.35),
                            Color.white.opacity(0.92),
                            bloom.opacity(0.35),
                            .clear
                        ],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
                .frame(width: diameter * 0.62, height: 1.6)
        }
        .frame(width: diameter, height: 22)
    }
}

// MARK: - Drawer destinations

private struct ConversationIndex: View {
    @State private var log = ConversationLog.shared

    var body: some View {
        ZStack {
            JarvisBackdrop().ignoresSafeArea()
            List {
                if log.items.isEmpty {
                    Text("Conversations you have with JARVIS show up here.")
                        .font(.system(size: 15))
                        .foregroundStyle(Color(hex: "#8E8A99"))
                        .listRowBackground(Color.clear)
                }
                ForEach(log.sorted) { convo in
                    NavigationLink {
                        ConversationPage(id: convo.id)
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: convo.symbol)
                                .font(.system(size: 15, weight: .light))
                                .frame(width: 22)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(convo.title)
                                    .font(.system(size: 16))
                                    .lineLimit(1)
                                Text(ConversationLog.timeLabel(convo.updatedAt))
                                    .font(.system(size: 12))
                                    .foregroundStyle(Color(hex: "#8E8A99"))
                            }
                        }
                    }
                    .listRowBackground(Color.white.opacity(0.04))
                }
                .onDelete { offsets in
                    let ids = offsets.map { log.sorted[$0].id }
                    for id in ids { log.remove(id) }
                }
            }
            .scrollContentBackground(.hidden)
        }
        .navigationTitle("Conversations")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
    }
}

private struct ConversationPage: View {
    var id: UUID
    @State private var log = ConversationLog.shared

    private var conversation: StoredConversation? {
        log.items.first { $0.id == id }
    }

    var body: some View {
        ZStack {
            JarvisBackdrop().ignoresSafeArea()
            if let conversation {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(conversation.turns) { turn in
                            Text(turn.text)
                                .font(.system(size: 16))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 10)
                                .background(
                                    turn.role == "user" ? Color.white.opacity(0.08) : Color(hex: "#2E8BFF").opacity(0.12),
                                    in: RoundedRectangle(cornerRadius: 16, style: .continuous)
                                )
                                .frame(maxWidth: .infinity, alignment: turn.role == "user" ? .trailing : .leading)
                        }
                    }
                    .padding(16)
                }
            } else {
                Text("This conversation is no longer saved on this iPhone.")
                    .font(.system(size: 15))
                    .foregroundStyle(Color(hex: "#8E8A99"))
                    .padding(24)
            }
        }
        .navigationTitle(conversation?.title ?? "Conversation")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .toolbar {
            if let conversation {
                Button(conversation.pinned ? "Unpin" : "Pin") {
                    log.setPinned(conversation.id, !conversation.pinned)
                }
                .foregroundStyle(Color(hex: "#4A7FD0"))
            }
        }
    }
}

private struct CalendarHub: View {
    @Environment(AssistantEngine.self) private var engine
    @Environment(\.dismiss) private var dismiss
    @State private var draft = ""

    var body: some View {
        ZStack {
            JarvisBackdrop().ignoresSafeArea()
            VStack(alignment: .leading, spacing: 14) {
                Text("Events & reminders")
                    .font(.system(size: 15))
                    .foregroundStyle(Color(hex: "#8E8A99"))
                askField
                hubButton("What's on my calendar today?") {
                    ask("What's on my calendar today?")
                }
                hubButton("What reminders do I have?") {
                    ask("List my reminders.")
                }
                Spacer()
            }
            .padding(20)
        }
        .navigationTitle("Calendar")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
    }

    private var askField: some View {
        HStack {
            TextField("Ask about your day", text: $draft)
                .textFieldStyle(.plain)
                .foregroundStyle(.white)
                .onSubmit { ask(draft) }
            Button("Ask") { ask(draft) }
                .foregroundStyle(Color(hex: "#4A7FD0"))
                .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .padding(12)
        .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func hubButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 16))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
                .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private func ask(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        engine.ask(trimmed)
        dismiss()
    }
}

private struct NavigateHub: View {
    @Environment(AssistantEngine.self) private var engine
    @Environment(\.dismiss) private var dismiss
    @State private var place = ""
    @State private var note = ""

    var body: some View {
        ZStack {
            JarvisBackdrop().ignoresSafeArea()
            VStack(alignment: .leading, spacing: 14) {
                Text("Maps & travel")
                    .font(.system(size: 15))
                    .foregroundStyle(Color(hex: "#8E8A99"))
                TextField("Where to?", text: $place)
                    .textFieldStyle(.plain)
                    .foregroundStyle(.white)
                    .padding(12)
                    .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                Button("Open in Maps") { openMaps() }
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(Color(hex: "#4A7FD0"))
                Button("Ask JARVIS for directions") {
                    let trimmed = place.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty else { return }
                    engine.ask("Give me directions to \(trimmed).")
                    dismiss()
                }
                .font(.system(size: 16))
                .foregroundStyle(.white)
                if !note.isEmpty {
                    Text(note)
                        .font(.system(size: 13))
                        .foregroundStyle(Color(hex: "#D07070"))
                }
                Spacer()
            }
            .padding(20)
        }
        .navigationTitle("Navigate")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
    }

    private func openMaps() {
        let trimmed = place.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            note = "Enter a place first."
            return
        }
        let encoded = trimmed.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? trimmed
        guard let url = URL(string: "maps://?q=\(encoded)") else {
            note = "That place could not be opened in Maps."
            return
        }
        note = ""
        UIApplication.shared.open(url)
    }
}

private struct SearchHub: View {
    @Environment(AssistantEngine.self) private var engine
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    var body: some View {
        ZStack {
            JarvisBackdrop().ignoresSafeArea()
            VStack(alignment: .leading, spacing: 14) {
                Text("Web & research")
                    .font(.system(size: 15))
                    .foregroundStyle(Color(hex: "#8E8A99"))
                TextField("Search", text: $query)
                    .textFieldStyle(.plain)
                    .foregroundStyle(.white)
                    .submitLabel(.search)
                    .onSubmit(run)
                    .padding(12)
                    .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                Button("Ask JARVIS") { run() }
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(Color(hex: "#4A7FD0"))
                    .disabled(query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Spacer()
            }
            .padding(20)
        }
        .navigationTitle("Search")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
    }

    private func run() {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        engine.ask("Search the web for \(trimmed).")
        dismiss()
    }
}

private struct FilesHub: View {
    @Environment(AssistantEngine.self) private var engine
    @State private var cards: [ResearchCard] = []

    var body: some View {
        ZStack {
            JarvisBackdrop().ignoresSafeArea()
            if cards.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "folder")
                        .font(.system(size: 28, weight: .light))
                        .foregroundStyle(Color(hex: "#8E8A99"))
                    Text("No documents yet")
                        .font(.system(size: 17))
                        .foregroundStyle(.white)
                    Text("Research JARVIS saves shows up here.")
                        .font(.system(size: 14))
                        .foregroundStyle(Color(hex: "#8E8A99"))
                }
            } else {
                List {
                    ForEach(cards) { card in
                        NavigationLink {
                            ScrollView {
                                Text(card.body)
                                    .font(.system(size: 16))
                                    .foregroundStyle(.white)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(16)
                            }
                            .background(JarvisBackdrop().ignoresSafeArea())
                            .navigationTitle(card.title)
                            .navigationBarTitleDisplayMode(.inline)
                        } label: {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(card.title)
                                    .font(.system(size: 16))
                                    .foregroundStyle(.white)
                                    .lineLimit(1)
                                Text(ConversationLog.timeLabel(card.createdAt))
                                    .font(.system(size: 12))
                                    .foregroundStyle(Color(hex: "#8E8A99"))
                            }
                        }
                        .listRowBackground(Color.white.opacity(0.04))
                    }
                    .onDelete { offsets in
                        let ids = offsets.map { cards[$0].id }
                        for id in ids { ResearchStore.delete(id: id) }
                        reload()
                    }
                }
                .scrollContentBackground(.hidden)
            }
        }
        .navigationTitle("Files")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .onAppear(perform: reload)
        .onChange(of: engine.researchTick) { _, _ in reload() }
    }

    private func reload() {
        cards = ResearchStore.cards()
    }
}

// MARK: - Conversation log

struct StoredTurn: Codable, Identifiable, Equatable {
    var id: UUID
    var role: String
    var text: String
}

struct StoredConversation: Codable, Identifiable, Equatable {
    var id: UUID
    var title: String
    var updatedAt: Date
    var pinned: Bool
    var pinOrder: Int
    var symbol: String
    var turns: [StoredTurn]
}

@MainActor
@Observable
final class ConversationLog {
    static let shared = ConversationLog()

    private(set) var items: [StoredConversation] = []
    private var liveID: UUID?
    private var sealedCount: Int?
    private let key = "jarvis.conversations.v1"
    private let recentCap = 40

    var pinned: [StoredConversation] {
        items.filter { $0.pinned }.sorted { $0.pinOrder < $1.pinOrder }
    }

    var recents: [StoredConversation] {
        items.filter { !$0.pinned }.sorted { $0.updatedAt > $1.updatedAt }
    }

    var sorted: [StoredConversation] {
        pinned + recents
    }

    private init() {
        guard let data = UserDefaults.standard.data(forKey: key) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        items = (try? decoder.decode([StoredConversation].self, from: data)) ?? []
    }

    func absorb(_ turns: [VoiceTurn]) {
        let meaningful = turns.filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard let firstUser = meaningful.first(where: { $0.role == "user" }) else { return }
        if liveID == nil, let sealed = sealedCount, sealed == meaningful.count { return }
        sealedCount = nil
        let stored = meaningful.map {
            StoredTurn(id: $0.id, role: $0.role, text: String($0.text.prefix(12_000)))
        }
        let title = Self.makeTitle(firstUser.text)
        let symbol = stored.contains(where: { $0.role != "user" && $0.text.count > 500 }) ? "doc.text" : "bubble.left"
        if let id = liveID, let index = items.firstIndex(where: { $0.id == id }) {
            if items[index].turns == stored && items[index].title == title && items[index].symbol == symbol { return }
            items[index].title = title
            items[index].turns = stored
            items[index].symbol = symbol
            items[index].updatedAt = Date()
        } else {
            let id = UUID()
            liveID = id
            let order = (items.map { $0.pinOrder }.max() ?? -1) + 1
            items.append(StoredConversation(
                id: id,
                title: title,
                updatedAt: Date(),
                pinned: false,
                pinOrder: order,
                symbol: symbol,
                turns: stored
            ))
        }
        trim()
        save()
    }

    func setPinned(_ id: UUID, _ pinned: Bool) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].pinned = pinned
        if pinned {
            items[index].pinOrder = (items.map { $0.pinOrder }.max() ?? -1) + 1
        }
        save()
    }

    func movePinned(from offsets: IndexSet, to destination: Int) {
        var rows = pinned
        rows.move(fromOffsets: offsets, toOffset: destination)
        for (order, row) in rows.enumerated() {
            guard let index = items.firstIndex(where: { $0.id == row.id }) else { continue }
            items[index].pinOrder = order
        }
        save()
    }

    func remove(_ id: UUID) {
        if id == liveID {
            sealedCount = items.first { $0.id == id }?.turns.count
            liveID = nil
        }
        items.removeAll { $0.id == id }
        save()
    }

    static func makeTitle(_ raw: String) -> String {
        let collapsed = raw.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard collapsed.count > 42 else { return collapsed.isEmpty ? "New conversation" : collapsed }
        let end = collapsed.index(collapsed.startIndex, offsetBy: 41)
        return String(collapsed[..<end]).trimmingCharacters(in: .whitespaces) + "…"
    }

    static func timeLabel(_ date: Date) -> String {
        if Calendar.current.isDateInToday(date) {
            return date.formatted(date: .omitted, time: .shortened)
        }
        return date.formatted(.dateTime.month(.abbreviated).day())
    }

    private func trim() {
        let extra = items.filter { !$0.pinned }.sorted { $0.updatedAt > $1.updatedAt }
        guard extra.count > recentCap else { return }
        let drop = Set(extra.dropFirst(recentCap).map { $0.id })
        items.removeAll { drop.contains($0.id) }
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        guard let data = try? encoder.encode(items) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }
}
