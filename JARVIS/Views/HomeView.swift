import SwiftUI

struct HomeView: View {
    @Environment(AssistantEngine.self) private var engine
    @Environment(AppSettings.self) private var settings
    var openStandBy: () -> Void

    @State private var pttPressed = false
    @State private var showReply = false
    @State private var replyDate: Date?

    private var tint: Color { settings.primaryColor }

    var body: some View {
        NavigationStack {
            GeometryReader { geo in
                let compact = geo.size.height < 700
                ZStack {
                    Color.black.ignoresSafeArea()
                    RadialGradient(colors: [tint.opacity(0.16), .clear],
                                   center: .center, startRadius: 10, endRadius: 280)
                        .frame(width: 560, height: 560)
                        .position(x: geo.size.width / 2, y: geo.size.height * 0.36)
                        .allowsHitTesting(false)

                    Group {
                        if compact {
                            ScrollView {
                                column(orbHeight: 260)
                                    .padding(.horizontal, 16)
                                    .padding(.bottom, 12)
                            }
                        } else {
                            column(orbHeight: max(230, geo.size.height * 0.40))
                                .padding(.horizontal, 16)
                                .padding(.bottom, 6)
                                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                        }
                    }
                    .frame(width: geo.size.width, height: geo.size.height, alignment: .top)
                }
            }
            .toolbar(.hidden, for: .navigationBar)
            .toolbarBackground(.hidden, for: .navigationBar)
            .tint(tint)
            .sheet(isPresented: $showReply) {
                NavigationStack {
                    ReplyDetailView()
                        .navigationTitle("JARVIS")
                        .navigationBarTitleDisplayMode(.inline)
                        .toolbar {
                            ToolbarItem(placement: .confirmationAction) {
                                Button("Done") { showReply = false }
                            }
                        }
                }
                .presentationDetents([.medium, .large])
                .preferredColorScheme(.dark)
            }
            .onChange(of: engine.reply) { _, newValue in
                if !newValue.isEmpty { replyDate = Date() }
            }
        }
    }

    private func column(orbHeight: CGFloat) -> some View {
        VStack(spacing: 12) {
            topBar
            orbBlock
                .frame(height: orbHeight)
            statusCard
            replyCard
            if let summary = engine.pendingSummary {
                ConfirmBar(summary: summary,
                           onConfirm: { engine.confirmPendingAction() },
                           onCancel: { engine.cancelPendingAction() })
            }
            if let error = engine.errorMessage {
                Text(error)
                    .font(.system(size: 12, weight: .light))
                    .foregroundStyle(.orange)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
            }
            tiles
        }
    }

    // MARK: Top bar

    private var topBar: some View {
        HStack(alignment: .center) {
            Button(action: openStandBy) {
                GridMark(tint: tint)
                    .frame(width: 40, height: 40)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("StandBy view")

            Spacer(minLength: 0)

            VStack(spacing: 3) {
                Text("JARVIS")
                    .font(.system(size: 26, weight: .thin))
                    .tracking(8)
                    .foregroundStyle(tint)
                    .shadow(color: tint.opacity(0.7), radius: 8)
                Text("YOUR INTELLIGENT ASSISTANT")
                    .font(.system(size: 8, weight: .medium))
                    .tracking(2.2)
                    .foregroundStyle(.white.opacity(0.55))
            }

            Spacer(minLength: 0)

            NavigationLink {
                SettingsView()
            } label: {
                Image(systemName: "person")
                    .font(.system(size: 16, weight: .light))
                    .foregroundStyle(tint)
                    .frame(width: 40, height: 40)
                    .overlay(Circle().stroke(tint.opacity(0.75), lineWidth: 1))
                    .shadow(color: tint.opacity(0.45), radius: 6)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Profile and settings")
        }
    }

    // MARK: Orb

    private var orbBlock: some View {
        ZStack {
            OrbView(level: engine.level, phase: engine.phase,
                    primary: tint, accent: settings.accentColor)
            OrbReticle(color: tint)
            VStack {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 7) {
                        phaseLabel("LISTENING", active: engine.phase == .listening)
                        phaseLabel("THINKING", active: engine.phase == .thinking)
                        phaseLabel("RESPONDING", active: engine.phase == .speaking)
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 4) {
                        HStack(spacing: 6) {
                            Circle()
                                .fill(tint)
                                .frame(width: 6, height: 6)
                                .shadow(color: tint, radius: 4)
                            Text("AI ONLINE")
                                .font(.system(size: 9, weight: .semibold))
                                .tracking(1.5)
                                .foregroundStyle(tint)
                        }
                        Text("LLM · VISION · TOOLS")
                            .font(.system(size: 7, weight: .medium))
                            .tracking(0.8)
                            .foregroundStyle(tint.opacity(0.4))
                        Text("SECURE")
                            .font(.system(size: 7, weight: .medium))
                            .tracking(1.2)
                            .foregroundStyle(tint.opacity(0.4))
                    }
                }
                Spacer()
            }
            .padding(.horizontal, 2)
            .padding(.top, 6)
            .allowsHitTesting(false)
        }
    }

    private func phaseLabel(_ title: String, active: Bool) -> some View {
        Text(title)
            .font(.system(size: 9, weight: active ? .semibold : .regular))
            .tracking(1.7)
            .foregroundStyle(tint.opacity(active ? 1 : 0.28))
            .shadow(color: active ? tint.opacity(0.8) : .clear, radius: 6)
    }

    // MARK: Cards

    private var statusTitle: String {
        switch engine.phase {
        case .listening: "Listening..."
        case .thinking: "Thinking..."
        case .speaking: "Responding..."
        case .idle: engine.isSessionActive ? "Listening..." : "Standing by"
        }
    }

    private var statusSubtitle: String {
        if engine.phase == .listening, !engine.transcript.isEmpty { return engine.transcript }
        if let status = engine.statusLine, engine.phase == .thinking { return status }
        return "Speak naturally, I'm here."
    }

    private var statusCard: some View {
        HStack(spacing: 12) {
            LevelWaveform(level: engine.level, tint: tint, active: engine.phase == .listening || engine.phase == .speaking)
                .frame(width: 28, height: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(statusTitle)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(.white)
                Text(statusSubtitle)
                    .font(.system(size: 12, weight: .light))
                    .foregroundStyle(.white.opacity(0.55))
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            micButton
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .glassPanel(tint: tint, radius: 24)
    }

    private var micButton: some View {
        Circle()
            .fill(tint.opacity(pttPressed ? 0.28 : 0.06))
            .overlay(Circle().stroke(tint, lineWidth: 1.4))
            .shadow(color: tint.opacity(pttPressed ? 0.95 : 0.55), radius: pttPressed ? 14 : 8)
            .overlay(Image(systemName: "mic").font(.system(size: 20, weight: .light)).foregroundStyle(tint))
            .frame(width: 58, height: 58)
            .scaleEffect(pttPressed ? 1.06 : 1)
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

    private var replyHeadline: String {
        if !engine.transcript.isEmpty { return engine.transcript }
        return "Here's what I found for you..."
    }

    private var replyBody: String {
        if !engine.reply.isEmpty { return engine.reply }
        return "I can help you with research, analysis, creative ideas, automation and more."
    }

    private var replyCard: some View {
        Button {
            showReply = true
        } label: {
            HStack(alignment: .top, spacing: 12) {
                StaticOrb(phase: engine.phase, primary: tint, accent: settings.accentColor)
                    .frame(width: 36, height: 36)
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("JARVIS")
                            .font(.system(size: 11, weight: .semibold))
                            .tracking(1.4)
                            .foregroundStyle(tint)
                        Spacer()
                        Text(stamp)
                            .font(.system(size: 11, weight: .light))
                            .foregroundStyle(.white.opacity(0.4))
                    }
                    Text(replyHeadline)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text(replyBody)
                        .font(.system(size: 12, weight: .light))
                        .foregroundStyle(.white.opacity(0.62))
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if !engine.citations.isEmpty {
                        Text(engine.citations.prefix(2).map(\.title).joined(separator: " · "))
                            .font(.system(size: 10, weight: .light))
                            .foregroundStyle(settings.accentColor.opacity(0.9))
                            .lineLimit(1)
                    }
                }
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .light))
                    .foregroundStyle(tint.opacity(0.7))
                    .padding(.top, 18)
            }
            .padding(14)
            .glassPanel(tint: tint, radius: 22)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Latest JARVIS reply")
    }

    private var stamp: String {
        guard let replyDate else { return "Just now" }
        let seconds = Date().timeIntervalSince(replyDate)
        if seconds < 45 { return "Just now" }
        if seconds < 3600 { return "\(max(1, Int(seconds / 60)))m ago" }
        return replyDate.formatted(date: .omitted, time: .shortened)
    }

    // MARK: Tiles

    private var tiles: some View {
        HStack(spacing: 8) {
            Button {
                Task { await engine.toggleSession() }
            } label: {
                HudTile(systemImage: "mic", title: "Talk",
                        subtitle: engine.isSessionActive ? "End session" : "Voice chat",
                        tint: tint, active: engine.isSessionActive)
            }
            .buttonStyle(.plain)

            NavigationLink {
                TasksView()
            } label: {
                HudTile(systemImage: "checklist", title: "Tasks", subtitle: "Plan & organize", tint: tint)
            }
            .buttonStyle(.plain)

            NavigationLink {
                VisionPlaceholderView()
            } label: {
                HudTile(systemImage: "eye", title: "Vision", subtitle: "See & analyze", tint: tint)
            }
            .buttonStyle(.plain)

            NavigationLink {
                IntegrationsSettingsView()
            } label: {
                HudTile(systemImage: "bolt", title: "Automation", subtitle: "Make it happen", tint: tint)
            }
            .buttonStyle(.plain)

            NavigationLink {
                SettingsView()
            } label: {
                HudTile(systemImage: "gearshape", title: "Settings", subtitle: "Customize", tint: tint)
            }
            .buttonStyle(.plain)
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
                if !engine.transcript.isEmpty {
                    labeled("You", engine.transcript)
                }
                if let status = engine.statusLine {
                    Text(status)
                        .font(.caption)
                        .foregroundStyle(settings.accentColor)
                }
                labeled("JARVIS", engine.reply.isEmpty ? "Nothing yet." : engine.reply)
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
