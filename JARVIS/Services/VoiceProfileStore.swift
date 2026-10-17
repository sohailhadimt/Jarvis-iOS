import Foundation

/// The enrolled voice print lives in the Keychain and never leaves the phone.
enum VoiceProfileStore {
    private static let account = "voice_id_profile"

    static var hasProfile: Bool { load() != nil }

    static func load() -> VoiceProfile? {
        guard let data = KeychainStore.data(account: account) else { return nil }
        guard let profile = try? JSONDecoder().decode(VoiceProfile.self, from: data) else { return nil }
        guard profile.version == SpeakerEmbedding.profileVersion else { return nil }
        guard profile.embedding.count == SpeakerEmbedding.dimension else { return nil }
        return profile
    }

    static func save(_ profile: VoiceProfile) {
        guard let data = try? JSONEncoder().encode(profile) else { return }
        KeychainStore.setData(data, account: account)
    }

    static func clear() {
        KeychainStore.setData(nil, account: account)
    }
}
