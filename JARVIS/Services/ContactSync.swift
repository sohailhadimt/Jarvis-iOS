import Contacts
import Foundation

/// Sends names and phone numbers (nothing else) to Sir's private JARVIS backend, so a text or call
/// like "ring Ali and ask…" or "what's Mum's number" can find the person. Needs the app token.
@MainActor
final class ContactSync {
    static let shared = ContactSync()

    private(set) var lastReport = ""
    private var running = false
    private let lastKey = "jarvis.contacts.lastSync"
    private let minimumGap: TimeInterval = 6 * 60 * 60

    private init() {}

    /// On launch: only when Contacts is already allowed, and at most every six hours.
    func syncOnLaunch() {
        let status = CNContactStore.authorizationStatus(for: .contacts)
        guard status == .authorized || status == .limited else { return }
        guard (try? JarvisCloudAPI.client()) != nil else { return }
        let last = UserDefaults.standard.double(forKey: lastKey)
        if last > 0, Date().timeIntervalSince1970 - last < minimumGap { return }
        Task { _ = await sync(ask: false) }
    }

    /// The "Sync contacts" button. Asks for access the first time.
    func sync(ask: Bool) async -> String {
        if running { return "Already syncing, Sir." }
        running = true
        defer { running = false }
        guard await Self.allowed(ask: ask) else {
            lastReport = "Contacts access is off. Turn it on in Settings › JARVIS › Contacts."
            return lastReport
        }
        let client: CloudClient
        do {
            client = try JarvisCloudAPI.client()
        } catch {
            lastReport = "Add the JARVIS Cloud app token first."
            return lastReport
        }
        let payload = await Task.detached(priority: .utility) { Self.fetchAll() }.value
        guard !payload.isEmpty else {
            lastReport = "No contacts with phone numbers to sync."
            return lastReport
        }
        do {
            let result = try await client.syncContacts(payload)
            UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: lastKey)
            lastReport = "Synced \(result.people) contacts (\(result.stored) numbers)."
        } catch {
            lastReport = "Contacts didn't sync: \(JarvisLines.explain(error))"
        }
        return lastReport
    }

    private nonisolated static func allowed(ask: Bool) async -> Bool {
        let status = CNContactStore.authorizationStatus(for: .contacts)
        if status == .authorized || status == .limited { return true }
        guard ask, status == .notDetermined else { return false }
        return (try? await CNContactStore().requestAccess(for: .contacts)) ?? false
    }

    /// Names and numbers only. No emails, addresses, notes or photos leave the phone.
    private nonisolated static func fetchAll() -> [[String: Any]] {
        let store = CNContactStore()
        let keys: [CNKeyDescriptor] = [
            CNContactFormatter.descriptorForRequiredKeys(for: .fullName),
            CNContactNicknameKey as CNKeyDescriptor,
            CNContactOrganizationNameKey as CNKeyDescriptor,
            CNContactPhoneNumbersKey as CNKeyDescriptor,
        ]
        let request = CNContactFetchRequest(keysToFetch: keys)
        var out: [[String: Any]] = []
        try? store.enumerateContacts(with: request) { contact, stop in
            guard !contact.phoneNumbers.isEmpty else { return }
            var name = CNContactFormatter.string(from: contact, style: .fullName) ?? ""
            if name.trimmingCharacters(in: .whitespaces).isEmpty { name = contact.nickname }
            if name.trimmingCharacters(in: .whitespaces).isEmpty { name = contact.organizationName }
            name = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { return }
            let phones: [[String: String]] = contact.phoneNumbers.prefix(8).map { line in
                let label = line.label.map { CNLabeledValue<CNPhoneNumber>.localizedString(forLabel: $0) } ?? ""
                return ["number": line.value.stringValue, "label": label]
            }
            out.append(["name": String(name.prefix(120)), "phones": phones])
            if !contact.nickname.isEmpty, contact.nickname.caseInsensitiveCompare(name) != .orderedSame {
                out.append(["name": String(contact.nickname.prefix(120)), "phones": phones])
            }
            if out.count >= 5000 { stop.pointee = true }
        }
        return out
    }
}
