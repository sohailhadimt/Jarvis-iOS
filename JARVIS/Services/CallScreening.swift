import Foundation

struct CallPrivacyRule: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var name: String
    var phone: String
    var allowPersonal: Bool
    var note: String
}

/// Who JARVIS may tell personal details about Master Hadi. Missing people are denied.
@MainActor
enum CallPrivacyStore {
    private static let key = "jarvis.call.privacy"
    private static var synced = false

    static func rules() -> [CallPrivacyRule] {
        guard let data = UserDefaults.standard.data(forKey: key) else { return [] }
        return (try? JSONDecoder().decode([CallPrivacyRule].self, from: data)) ?? []
    }

    static func replace(_ rules: [CallPrivacyRule]) {
        let encoder = JSONEncoder()
        if let data = try? encoder.encode(rules) {
            UserDefaults.standard.set(data, forKey: key)
        }
        synced = false
    }

    static func note(matching record: PhoneCallRecord?) -> String {
        guard let record else { return "" }
        let name = (record.callerName ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let phone = record.to
        for rule in rules() where rule.allowPersonal {
            if !rule.phone.isEmpty && rule.phone == phone { return rule.note }
            if !name.isEmpty && rule.name.lowercased() == name { return rule.note }
        }
        return ""
    }

    static func syncIfNeeded() async {
        guard !synced else { return }
        guard JarvisCloud.isConfigured, let client = try? JarvisCloudAPI.client() else { return }
        synced = true
        let payload: [[String: Any]] = rules().map { rule in
            var item: [String: Any] = [
                "name": rule.name,
                "allow_personal": rule.allowPersonal,
                "note": rule.note,
            ]
            if !rule.phone.isEmpty { item["phone"] = rule.phone }
            return item
        }
        let result = await client.replaceCallPermissions(payload)
        if case .done = result {
            return
        }
        synced = false
    }
}

@MainActor
enum CallDevice {
    private static let key = "jarvis.call.device"
    private static var uploaded = ""

    static func remember(_ token: String) {
        UserDefaults.standard.set(token, forKey: key)
        uploaded = ""
    }

    static func uploadIfNeeded() async {
        guard let token = UserDefaults.standard.string(forKey: key), !token.isEmpty else { return }
        guard token != uploaded else { return }
        guard JarvisCloud.isConfigured, let client = try? JarvisCloudAPI.client() else { return }
        let result = await client.registerCallDevice(token: token)
        if case .done = result { uploaded = token }
    }
}

enum ForwardingGuide {
    static let cancel = "##002#"

    static func unconditional(_ number: String) -> String { "**21*\(number)#" }
    static func noAnswer(_ number: String) -> String { "**61*\(number)#" }
    static func busy(_ number: String) -> String { "**67*\(number)#" }
    static func unreachable(_ number: String) -> String { "**62*\(number)#" }
}
