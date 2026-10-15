import SwiftUI

private enum HomePanel: String, Identifiable {
    case chat, tasks, approvals, business, memory, activity, settings
    var id: String { rawValue }
}

struct HomeView: View {
    @Environment(AssistantEngine.self) private var engine
    @Environment(AppSettings.self) private var settings
    var openStandBy: () -> Void

    @State private var showSheet = false
    @State private var panel: HomePanel?
    @State private var showCaption = false
    @State private var ignoreTapUntil = Date.distantPast
    @State private var errorCaption: String?
    @State private var errorTick = 0

    private var cyan: Color { Color(red: 0, green: 0.898, blue: 0.949) }

    var body: some View {
        GeometryReader { geo in
            let side = geo.size.width * 0.60
            let top = geo.safeAreaInsets.top
            let bottom = geo.safeAreaInsets.bottom
            let dockLift = max(bottom, 8) + 72
            let midY = top + (geo.size.height - top - bottom - 72) * 0.5
            ZStack {
                Color.black
                if engine.isSessionActive {
                    VoiceSessionView()
                } else {
                    orb
                        .frame(width: side, height: side)
                        .overlay(alignment: .bottom) { captions.offset(y: 48) }
                        .position(x: geo.size.width / 2, y: midY)
                    swipeCatcher(height: 36, screen: geo.size, above: dockLift)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .overlay(alignment: .bottom) {
                if !engine.isSessionActive {
                    homeDock
                        .padding(.bottom, max(bottom, 8))
                }
            }
        }
        .ignoresSafeArea()
        .sheet(isPresented: $showSheet) { menuSheet }
        .sheet(item: $panel) { item in
            NavigationStack {
                panelDestination(item)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Close") { panel = nil }
                        }
                    }
            }
            .presentationBackground(Color.black)
            .preferredColorScheme(.dark)
            .tint(cyan)
        }
        .onChange(of: engine.errorMessage) { _, newValue in
            guard let newValue, !newValue.isEmpty else { return }
            errorCaption = newValue
            errorTick += 1
            let token = errorTick
            Task {
                try? await Task.sleep(for: .seconds(3.5))
                if errorTick == token { errorCaption = nil }
            }
        }
    }

    private var orb: some View {
        OrbView(level: engine.level, phase: engine.phase,
                primary: settings.primaryColor, accent: settings.accentColor,
                sessionActive: engine.isSessionActive,
                executing: engine.cloudExecuting || (engine.phase == .thinking && engine.statusLine != nil),
                hasError: errorCaption != nil,
                reply: engine.reply)
            .contentShape(Circle())
            .onTapGesture {
                if Date() < ignoreTapUntil { return }
                Task { await engine.toggleSession() }
            }
            .onLongPressGesture(minimumDuration: 0.45) {
                showCaption.toggle()
                ignoreTapUntil = Date().addingTimeInterval(0.45)
            }
            .accessibilityAddTraits(.isButton)
            .accessibilityHint(engine.isSessionActive ? "Stops the session" : "Starts a session")
            .accessibilityAction(named: "Transcript") { showCaption.toggle() }
    }

    private var captions: some View {
        VStack(spacing: 8) {
            if showCaption, !captionText.isEmpty {
                Text(captionText)
                    .font(.system(size: 13, weight: .light))
                    .foregroundStyle(cyan.opacity(0.72))
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
            }
            if let errorCaption {
                Text(errorCaption)
                    .font(.system(size: 12, weight: .light))
                    .foregroundStyle(.white.opacity(0.45))
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
            }
        }
        .frame(maxWidth: 320)
        .padding(.horizontal, 28)
        .allowsHitTesting(false)
    }

    private var captionText: String {
        if !engine.reply.isEmpty { return engine.reply }
        return engine.transcript
    }

    private var homeDock: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                dockButton("Chat", systemImage: "text.bubble") { panel = .chat }
                dockButton("Tasks", systemImage: "checklist") { panel = .tasks }
                dockButton("Approvals", systemImage: "checkmark.circle") { panel = .approvals }
                dockButton("Business", systemImage: "chart.bar") { panel = .business }
                dockButton("Memory", systemImage: "brain") { panel = .memory }
                dockButton("Activity", systemImage: "list.bullet.rectangle") { panel = .activity }
                dockButton("Settings", systemImage: "gearshape") { panel = .settings }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
        }
        .frame(height: 64)
        .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
    }

    private func dockButton(_ title: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Image(systemName: systemImage)
                    .font(.system(size: 15, weight: .light))
                Text(title)
                    .font(.system(size: 9, weight: .medium))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            .foregroundStyle(VoiceLook.mist)
            .frame(width: 62, height: 48)
            .background {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(VoiceLook.blue.opacity(0.16))
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(VoiceLook.lavender.opacity(0.35), lineWidth: 0.6)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
    }

    private func swipeCatcher(height: CGFloat, screen: CGSize, above lift: CGFloat) -> some View {
        Color.black.opacity(0.001)
            .frame(width: screen.width, height: height)
            .position(x: screen.width / 2, y: screen.height - lift - height / 2)
            .gesture(
                DragGesture(minimumDistance: 16)
                    .onEnded { value in
                        if value.translation.height < -28, abs(value.translation.width) < 90 {
                            showSheet = true
                        }
                    }
            )
            .accessibilityLabel("More")
            .accessibilityHint("Swipe up for conversation, tasks, memory and settings")
            .accessibilityAction { showSheet = true }
    }

    private var menuSheet: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 0) {
                    sheetLink("Conversation", systemImage: "text.bubble") { ReplyDetailView() }
                    sheetLink("Briefing", systemImage: "sun.horizon") { CloudBriefingView() }
                    sheetLink("Tasks", systemImage: "checklist") { CloudTasksView() }
                    sheetLink("Approvals", systemImage: "checkmark.circle") { CloudApprovalsView() }
                    sheetLink("Memory", systemImage: "brain") { CloudMemoryGate() }
                    sheetLink("Activity", systemImage: "list.bullet.rectangle") { CloudActivityView() }
                    sheetLink("Business", systemImage: "chart.bar") { CloudBusinessView() }
                    sheetLink("Settings", systemImage: "gearshape") { SettingsView() }
                    sheetLink("Integrations", systemImage: "square.grid.3x3") { IntegrationsSettingsView() }
                    sheetLink("Voice", systemImage: "waveform") { VoicesSettingsView() }
                    sheetLink("Vision", systemImage: "eye") { VisionPlaceholderView() }
                    Button {
                        showSheet = false
                        openStandBy()
                    } label: {
                        menuRow("StandBy", systemImage: "moon.stars")
                    }
                    .buttonStyle(.plain)
                }
                .padding(.top, 8)
            }
            .background(Color.black)
            .navigationTitle("JARVIS")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { showSheet = false }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .presentationBackground(Color.black)
        .preferredColorScheme(.dark)
        .tint(cyan)
    }

    private func sheetLink<Destination: View>(_ title: String, systemImage: String,
                                              @ViewBuilder destination: () -> Destination) -> some View {
        NavigationLink {
            destination()
        } label: {
            menuRow(title, systemImage: systemImage)
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func panelDestination(_ item: HomePanel) -> some View {
        switch item {
        case .chat:
            ReplyDetailView().navigationTitle("Chat")
        case .tasks:
            CloudTasksView()
        case .approvals:
            CloudApprovalsView()
        case .business:
            CloudBusinessView()
        case .memory:
            CloudMemoryGate()
        case .activity:
            CloudActivityView()
        case .settings:
            SettingsView()
        }
    }

    private func menuRow(_ title: String, systemImage: String) -> some View {
        HStack(spacing: 14) {
            Image(systemName: systemImage)
                .frame(width: 24)
            Text(title)
                .font(.system(size: 17, weight: .light))
            Spacer()
            Image(systemName: "chevron.right")
                .font(.system(size: 12, weight: .light))
                .foregroundStyle(cyan.opacity(0.45))
        }
        .foregroundStyle(cyan)
        .padding(.horizontal, 22)
        .padding(.vertical, 16)
        .overlay(alignment: .bottom) {
            Rectangle().fill(cyan.opacity(0.22)).frame(height: 0.5).padding(.leading, 22)
        }
    }

}

// MARK: - Pieces

struct GridMark: View {
    var tint: Color

    var body: some View {
        VStack(spacing: 5) {
            HStack(spacing: 5) { dot(tint); dot(tint) }
            HStack(spacing: 5) { dot(tint); dot(tint) }
        }
    }

    private func dot(_ tint: Color) -> some View {
        Circle().stroke(tint, lineWidth: 1.2).frame(width: 7, height: 7)
            .shadow(color: tint.opacity(0.8), radius: 3)
    }
}

struct HudTile: View {
    let systemImage: String
    let title: String
    let subtitle: String
    var tint: Color
    var active: Bool = false

    var body: some View {
        VStack(spacing: 3) {
            Image(systemName: systemImage)
                .font(.system(size: 16, weight: .light))
                .shadow(color: tint.opacity(0.8), radius: active ? 8 : 4)
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Text(subtitle)
                .font(.system(size: 8, weight: .light))
                .foregroundStyle(.white.opacity(0.45))
                .lineLimit(1)
                .minimumScaleFactor(0.6)
        }
        .foregroundStyle(tint)
        .frame(maxWidth: .infinity)
        .frame(height: 78)
        .background(tint.opacity(active ? 0.16 : 0.04), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(tint.opacity(active ? 1 : 0.45), lineWidth: 1)
        )
        .shadow(color: tint.opacity(active ? 0.35 : 0.12), radius: 6)
    }
}

struct LevelWaveform: View {
    var level: Double
    var tint: Color
    var active: Bool

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            HStack(alignment: .center, spacing: 3) {
                ForEach(0..<5, id: \.self) { i in
                    let wobble = active ? abs(sin(t * 7 + Double(i) * 0.7)) : 0.35
                    Capsule()
                        .fill(tint)
                        .frame(width: 3, height: 4 + (6 + level * 16) * (0.35 + 0.65 * wobble))
                        .shadow(color: tint.opacity(0.8), radius: 2)
                }
            }
        }
    }
}

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
struct ApprovalsView: View {
    @Environment(AssistantEngine.self) private var engine

    private var cyan: Color { Color(red: 0, green: 0.898, blue: 0.949) }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let summary = engine.pendingSummary {
                ConfirmBar(summary: summary,
                           onConfirm: { engine.confirmPendingAction() },
                           onCancel: { engine.cancelPendingAction() })
                    .padding(24)
            } else {
                Text("Nothing is waiting for approval.")
                    .font(.system(size: 15, weight: .light))
                    .foregroundStyle(cyan.opacity(0.8))
                    .multilineTextAlignment(.center)
                    .padding(24)
            }
        }
        .navigationTitle("Approvals")
        .toolbar(.visible, for: .navigationBar)
    }
}

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

struct ReplyDetailView: View {
    @Environment(AssistantEngine.self) private var engine
    @Environment(AppSettings.self) private var settings

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if !engine.turns.isEmpty {
                    ForEach(engine.turns) { turn in
                        labeled(turn.role == "user" ? "You" : "JARVIS", turn.text)
                    }
                } else if !engine.transcript.isEmpty {
                    labeled("You", engine.transcript)
                }
                if let status = engine.statusLine {
                    Text(status)
                        .font(.caption)
                        .foregroundStyle(settings.accentColor)
                }
                if engine.turns.isEmpty {
                    labeled("JARVIS", engine.reply.isEmpty ? "Nothing yet." : engine.reply)
                }
                if !engine.citations.isEmpty {
                    Text("Sources")
                        .font(.caption.weight(.semibold))
                        .tracking(1.2)
                        .foregroundStyle(settings.primaryColor)
                    ForEach(engine.citations) { citation in
                        if let url = URL(string: citation.url) {
                            Link(citation.title, destination: url)
                                .font(.footnote)
                        }
                    }
                }
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color.black)
    }

    private func labeled(_ title: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .tracking(1.4)
                .foregroundStyle(settings.primaryColor)
            Text(text)
                .font(.body)
                .foregroundStyle(.white)
                .textSelection(.enabled)
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

struct VisionPlaceholderView: View {
    @Environment(AppSettings.self) private var settings

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 14) {
                Image(systemName: "eye")
                    .font(.system(size: 42, weight: .thin))
                    .foregroundStyle(settings.primaryColor)
                    .shadow(color: settings.primaryColor.opacity(0.8), radius: 10)
                Text("COMING SOON")
                    .font(.system(size: 14, weight: .light))
                    .tracking(4)
                    .foregroundStyle(settings.primaryColor)
                Text("Vision will see and analyse what's around you. It isn't available in this build.")
                    .font(.system(size: 14, weight: .light))
                    .foregroundStyle(.white.opacity(0.65))
                    .multilineTextAlignment(.center)
            }
            .padding(28)
            .glassPanel(tint: settings.primaryColor)
            .padding(24)
        }
        .navigationTitle("Vision")
        .toolbar(.visible, for: .navigationBar)
    }
}
