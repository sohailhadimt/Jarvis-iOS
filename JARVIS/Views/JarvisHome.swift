import Observation
import SwiftUI
import UIKit

extension Notification.Name {
    static let jarvisOpenStandBy = Notification.Name("jarvisOpenStandBy")
}

enum DrawerRoute: Hashable {
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

struct DrawerItem: Identifiable {
    var route: DrawerRoute
    var title: String
    var subtitle: String
    var icon: String
    var id: String { title }
}

/// Finger position for the drawer. The home screen does not read `fraction`, so a drag does not rebuild it.
@MainActor
@Observable
final class DrawerModel {
    var fraction: CGFloat = 0
    var panning = false
    var onSelect: ((DrawerRoute?) -> Void)?
    private var axis = 0
    private var origin: CGFloat = 0

    static let spring = Animation.spring(duration: 0.42, bounce: 0.05)

    func setOpen(_ open: Bool) {
        if open {
            UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        }
        withAnimation(Self.spring) {
            fraction = open ? 1 : 0
        }
        if open { JarvisHaptics.tap() }
    }

    func drag(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 16, coordinateSpace: .global)
            .onChanged { value in self.changed(value, width: width) }
            .onEnded { value in self.ended(value, width: width) }
    }

    private func changed(_ value: DragGesture.Value, width: CGFloat) {
        guard width > 1 else { return }
        let dx = value.translation.width
        let dy = value.translation.height
        if axis == 0 {
            if abs(dx) < 10, abs(dy) < 10 { return }
            axis = abs(dx) > abs(dy) * 1.15 ? 1 : 2
            if axis == 1 {
                origin = fraction
                panning = true
                UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
            }
        }
        guard axis == 1 else { return }
        let next = min(max(origin + dx / width, 0), 1)
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) { fraction = next }
    }

    private func ended(_ value: DragGesture.Value, width: CGFloat) {
        defer {
            axis = 0
            panning = false
        }
        guard axis == 1, width > 1 else { return }
        let flick = value.predictedEndTranslation.width - value.translation.width
        let projected = origin + value.predictedEndTranslation.width / width
        let open: Bool
        if flick > 70 { open = true }
        else if flick < -70 { open = false }
        else { open = projected > 0.4 }
        setOpen(open)
    }
}

/// Home screen: navy field, glowing ring, greeting, ask bar, and the side drawer.
struct JarvisShell: View {
    @Environment(AssistantEngine.self) private var engine
    @Environment(\.scenePhase) private var scenePhase
    var openStandBy: () -> Void

    @State private var log = ConversationLog.shared
    @State private var drawer = DrawerModel()
    @State private var route: DrawerRoute?

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
        DrawerItem(route: .calls, title: "Calls", subtitle: "Calls & messages", icon: "phone"),
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
                        HomeScreen(ringPaused: scenePhase != .active || route != nil) {
                            drawer.setOpen(true)
                        }
                        DrawerScrim(model: drawer)
                        DrawerSlide(model: drawer, width: drawerW, menu: drawerMenu)
                    }
                    .simultaneousGesture(drawer.drag(width: drawerW))
                }
            }
            .navigationDestination(item: $route) { destination($0) }
            .toolbar(.hidden, for: .navigationBar)
        }
        .preferredColorScheme(.dark)
        .onAppear {
            drawer.onSelect = { next in
                self.route = next
                self.drawer.setOpen(false)
            }
            log.absorb(engine.turns)
        }
        .onChange(of: engine.turns.count) { _, _ in log.absorb(engine.turns) }
        .onChange(of: engine.phase) { _, phase in
            if phase == .idle || phase == .listening { log.absorb(engine.turns) }
        }
        .onReceive(NotificationCenter.default.publisher(for: .jarvisOpenStandBy)) { _ in
            openStandBy()
        }
    }

    private var drawerMenu: DrawerMenu {
        DrawerMenu(model: drawer, items: menu)
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

extension View {
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

struct JarvisWordmark: View {
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

struct HamburgerMark: View {
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

enum JarvisGreeting {
    /// Stable for the calendar day, so the clock ticking each minute does not change the line.
    static func line(at date: Date, name: String = "Sohail") -> String {
        let hour = Calendar.current.component(.hour, from: date)
        let lines: [String]
        if hour < 12 {
            lines = [
                "Good morning, \(name).",
                "Good morning, \(name). I kept the night watch.",
                "Morning, \(name). Coffee first, then the world.",
            ]
        } else if hour < 17 {
            lines = [
                "Good afternoon, \(name).",
                "Good afternoon, \(name). The day is still yours.",
                "Afternoon, \(name). I've been minding the details.",
            ]
        } else {
            lines = [
                "Good evening, \(name).",
                "Good evening, \(name). The house is quiet.",
                "Evening, \(name). Tell me what you need.",
            ]
        }
        let day = Calendar.current.ordinality(of: .day, in: .era, for: date) ?? 0
        return lines[day % lines.count]
    }
}

// MARK: - Drawer destinations

private struct ConversationIndex: View {
    @State private var log = ConversationLog.shared
    @State private var query = ""

    private var rows: [StoredConversation] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return log.sorted }
        return log.sorted.filter { convo in
            convo.title.localizedCaseInsensitiveContains(needle)
                || convo.turns.contains { $0.text.localizedCaseInsensitiveContains(needle) }
        }
    }

    var body: some View {
        ZStack {
            JarvisBackdrop().ignoresSafeArea()
            List {
                if rows.isEmpty {
                    Text(query.isEmpty ? "Conversations you have with JARVIS show up here." : "Nothing saved matches that.")
                        .font(.system(size: 15))
                        .foregroundStyle(Color(hex: "#8E8A99"))
                        .listRowBackground(Color.clear)
                }
                ForEach(rows) { convo in
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
                    let ids = offsets.map { rows[$0].id }
                    for id in ids { log.remove(id) }
                }
            }
            .scrollContentBackground(.hidden)
        }
        .searchable(text: $query, prompt: "Search conversations")
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

struct StoredTurn: Codable, Identifiable, Equatable, Sendable {
    var id: UUID
    var role: String
    var text: String
}

struct StoredConversation: Codable, Identifiable, Equatable, Sendable {
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
    private var saveGeneration = 0
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
        saveGeneration += 1
        let generation = saveGeneration
        let snapshot = items
        let key = key
        Task.detached(priority: .utility) {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .secondsSince1970
            guard let data = try? encoder.encode(snapshot) else { return }
            await MainActor.run {
                guard generation == ConversationLog.shared.saveGeneration else { return }
                UserDefaults.standard.set(data, forKey: key)
            }
        }
    }
}
