import Foundation
import Security

enum KeychainKey: String, CaseIterable {
    case openAI = "openai_api_key"
    case gemini = "gemini_api_key"
    case groq = "groq_api_key"
    case elevenLabs = "elevenlabs_api_key"
    case customAgent = "custom_agent_bearer_key"
    case agentWebhook = "agent_webhook_bearer_key"
    case grokBotWebhook = "grok_bot_routine_webhook_key"
    case jarvisCloud = "jarvis_cloud_app_token"
    /// Own mobile for put-through and problem calls. Empty until typed in Calling settings.
    case ownerPhone = "owner_phone"
    case brave = "brave_search_api_key"
}

/// Minimal Keychain wrapper. Secrets never live in code or UserDefaults.
enum KeychainStore {
    private static let service = "com.sohail.jarvis.keys"

    static func get(_ key: KeychainKey) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key.rawValue,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let value = String(data: data, encoding: .utf8), !value.isEmpty else { return nil }
        return value
    }

    static func set(_ value: String?, for key: KeychainKey) {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key.rawValue,
        ]
        SecItemDelete(base as CFDictionary)
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return }
        var add = base
        add[kSecValueData as String] = Data(value.utf8)
        // AfterFirstUnlock so the Action Button intent can read keys while the phone is locked-but-unlocked-once.
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(add as CFDictionary, nil)
    }

    static func data(account: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data, !data.isEmpty else { return nil }
        return data
    }

    static func setData(_ data: Data?, account: String) {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(base as CFDictionary)
        guard let data, !data.isEmpty else { return }
        var add = base
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(add as CFDictionary, nil)
    }
}
