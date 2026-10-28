import Foundation

final class HQSession: ObservableObject {
    let world = OfficeWorld()

    @Published var onboarded: Bool
    @Published var playerName: String
    @Published var haptics: Bool
    @Published var hasToken: Bool
    @Published var look: Outfit
    @Published var looks: [Outfit]
    @Published var furniture: [FurniturePlacement]
    @Published var progress: HQProgress
    @Published var hasSnapshot: Bool
    @Published var syncError: String?
    @Published var status: String?
    @Published var banner: String?
    @Published var lines: [ChatLine] = []
    @Published var sending = false
    @Published var talk: TalkRequest?
    @Published var wardrobeOpen = false
    @Published var perksOpen = false
    @Published var settingsOpen = false
    @Published var worldPrompt: WorldPrompt?
    @Published var zoneName = "office"

    private var cosmeticsDirty = false
    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        return encoder
    }()
    private let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }()

    init() {
        let defaults = UserDefaults.standard
        onboarded = defaults.bool(forKey: "asghq.onboarded")
        playerName = defaults.string(forKey: "asghq.playerName").flatMap { $0.isEmpty ? nil : $0 } ?? "Sohail"
        haptics = defaults.object(forKey: "asghq.haptics") as? Bool ?? true
        hasToken = KeychainStore.token() != nil
        look = Self.load(Outfit.self, key: "asghq.look", fallback: .starter)
        looks = Self.load([Outfit].self, key: "asghq.looks", fallback: [])
        furniture = Self.load([FurniturePlacement].self, key: "asghq.furniture", fallback: .starter)
        if let cached = Self.loadOptional(HQProgress.self, key: "asghq.progress") {
            progress = cached
            hasSnapshot = true
        } else {
            progress = .waiting
            hasSnapshot = false
        }
        Haptics.enabled = haptics
        let perks = Set(progress.perks)
        look = Catalog.sanitized(look, perks: perks)
        furniture = Catalog.sanitized(furniture, perks: perks)
        world.installAccess(corner: perks.contains("corner_office"), roof: perks.contains("rooftop"))
        world.apply(outfit: look)
        world.apply(furniture: furniture)
    }

    var perkSet: Set<String> { Set(progress.perks) }

    func finishOnboarding(name: String, token: String?) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { playerName = String(trimmed.prefix(40)) }
        if let token, !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            KeychainStore.setToken(token)
        }
        hasToken = KeychainStore.token() != nil
        onboarded = true
        UserDefaults.standard.set(true, forKey: "asghq.onboarded")
        persistLocal()
        Haptics.success()
    }

    func updateToken(_ value: String) {
        KeychainStore.setToken(value)
        hasToken = KeychainStore.token() != nil
    }

    func updateBaseURL(_ value: String) {
        HQSettings.baseURLString = value
    }

    func rename(_ value: String) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let next = String(trimmed.prefix(40))
        guard next != playerName else { return }
        playerName = next
        cosmeticsDirty = true
    }

    func setHaptics(_ enabled: Bool) {
        haptics = enabled
        Haptics.enabled = enabled
        UserDefaults.standard.set(enabled, forKey: "asghq.haptics")
    }

    func setStick(x: Float, y: Float) {
        world.setJoystick(x: x, y: y)
    }

    func openTalk(bot: String, mic: Bool) {
        talk = TalkRequest(bot: bot, mic: mic)
        refreshPause()
        Haptics.tap()
    }

    func openGiveTask(mic: Bool) {
        openTalk(bot: world.closestBot(), mic: mic)
    }

    func closeTalk() {
        talk = nil
        refreshPause()
    }

    func openWardrobe() {
        wardrobeOpen = true
        refreshPause()
        Haptics.tap()
    }

    func closeWardrobe() {
        wardrobeOpen = false
        refreshPause()
        Task { await saveCosmetics() }
    }

    func openPerks() {
        perksOpen = true
        refreshPause()
        Haptics.tap()
    }

    func closePerks() {
        perksOpen = false
        refreshPause()
    }

    func openSettings() {
        settingsOpen = true
        refreshPause()
        Haptics.tap()
    }

    func closeSettings() {
        settingsOpen = false
        refreshPause()
        Task { await saveCosmetics() }
    }

    func applyChrome(prompt: WorldPrompt?, zone: String) {
        if prompt != worldPrompt {
            if let prompt, prompt.action != .none { Haptics.tap() }
            worldPrompt = prompt
        }
        if zone != zoneName {
            if zoneName != "office" || zone != "office" { Haptics.tap() }
            zoneName = zone
        }
    }

    func preview(outfit: Outfit) {
        let next = Catalog.sanitized(outfit, perks: perkSet)
        look = next
        cosmeticsDirty = true
        world.enqueue(outfit: next)
    }

    func preview(furniture items: [FurniturePlacement]) {
        let next = Catalog.sanitized(items, perks: perkSet)
        furniture = next
        cosmeticsDirty = true
        world.enqueue(furniture: next)
    }

    func saveNamedLook(_ name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var named = look
        named.name = String(trimmed.prefix(40))
        looks.removeAll { $0.name.caseInsensitiveCompare(named.name) == .orderedSame }
        looks.insert(named, at: 0)
        if looks.count > 12 { looks = Array(looks.prefix(12)) }
        look = named
        cosmeticsDirty = true
        persistLocal()
        Haptics.success()
        Task { await saveCosmetics() }
    }

    func wear(_ outfit: Outfit) {
        preview(outfit: outfit)
        persistLocal()
    }

    func deleteLook(_ outfit: Outfit) {
        looks.removeAll { $0.name == outfit.name }
        cosmeticsDirty = true
        persistLocal()
    }

    func send(bot: String, text: String) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !sending else { return }
        lines.append(ChatLine(bot: bot, role: .player, text: trimmed))
        sending = true
        defer { sending = false }
        do {
            let reply = try await HQClient.talk(bot: bot, text: trimmed)
            lines.append(ChatLine(bot: bot, role: .bot, text: reply.reply, needsApproval: reply.status == "needs_approval"))
            world.setHologram(bot: bot, text: reply.reply)
            if reply.status == "needs_approval" { Haptics.warning() } else { Haptics.success() }
        } catch {
            lines.append(ChatLine(bot: bot, role: .system, text: error.localizedDescription))
        }
    }

    func sync() async {
        do {
            let remote = try await HQClient.progress()
            let already = hasSnapshot
            let previousLevel = progress.level
            let unlocked = Set(remote.perks).subtracting(progress.perks)
            progress = remote
            hasSnapshot = true
            syncError = nil
            world.setAccess(corner: remote.perks.contains("corner_office"), roof: remote.perks.contains("rooftop"))
            if already && remote.level > previousLevel {
                flash("Level \(remote.level)")
                Haptics.success()
            } else if already, let perk = unlocked.first {
                flash(perkLabel(perk))
                Haptics.success()
            }
            if !cosmeticsDirty, let state = remote.state {
                let perks = Set(remote.perks)
                playerName = state.playerName
                look = Catalog.sanitized(state.activeLook, perks: perks)
                looks = state.looks.map { Catalog.sanitized($0, perks: perks) }
                furniture = Catalog.sanitized(filled(state.furniture), perks: perks)
                world.enqueue(outfit: look)
                world.enqueue(furniture: furniture)
            }
            persistLocal()
        } catch {
            syncError = error.localizedDescription
        }
    }

    func saveCosmetics() async {
        persistLocal()
        guard hasToken else { return }
        do {
            try await HQClient.saveState(name: playerName, look: look, looks: looks, furniture: furniture)
            cosmeticsDirty = false
            status = "Saved at HQ."
        } catch {
            status = error.localizedDescription
        }
    }

    func applyChromeFromWorld() {
        let snap = world.chrome()
        applyChrome(prompt: snap.0, zone: snap.1)
    }

    private func refreshPause() {
        world.setPaused(talk != nil || wardrobeOpen || perksOpen || settingsOpen)
    }

    private func flash(_ text: String) {
        banner = text
        Task {
            try? await Task.sleep(nanoseconds: 2_400_000_000)
            if banner == text { banner = nil }
        }
    }

    private func perkLabel(_ perk: String) -> String {
        switch perk {
        case "outfit_pack": return "Outfit pack unlocked"
        case "corner_office": return "Corner office unlocked"
        case "rooftop": return "Rooftop terrace unlocked"
        default: return "Perk unlocked"
        }
    }

    private func filled(_ items: [FurniturePlacement]) -> [FurniturePlacement] {
        Catalog.slots.map { slot in
            items.first { $0.slot == slot } ?? FurniturePlacement(slot: slot, item: "none", color: "navy")
        }
    }

    private func persistLocal() {
        let defaults = UserDefaults.standard
        defaults.set(playerName, forKey: "asghq.playerName")
        defaults.set(hasSnapshot, forKey: "asghq.hasSnapshot")
        if let data = try? encoder.encode(look) { defaults.set(data, forKey: "asghq.look") }
        if let data = try? encoder.encode(looks) { defaults.set(data, forKey: "asghq.looks") }
        if let data = try? encoder.encode(furniture) { defaults.set(data, forKey: "asghq.furniture") }
        if hasSnapshot, let data = try? encoder.encode(progress) { defaults.set(data, forKey: "asghq.progress") }
    }

    private static func load<T: Decodable>(_ type: T.Type, key: String, fallback: T) -> T {
        loadOptional(type, key: key) ?? fallback
    }

    private static func loadOptional<T: Decodable>(_ type: T.Type, key: String) -> T? {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? decoder.decode(T.self, from: data)
    }
}
