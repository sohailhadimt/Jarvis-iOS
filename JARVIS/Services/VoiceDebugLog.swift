import Foundation

/// Turn and barge-in notes for the next TestFlight. Best-effort upload to the worker. No audio is stored.
enum VoiceDebugLog {
    private static let lock = NSLock()
    private static var pending: [[String: String]] = []
    private static var posting = false

    static func note(_ kind: String, _ detail: String) {
        let item = [
            "kind": String(kind.prefix(40)),
            "detail": String(detail.prefix(180)),
        ]
        lock.lock()
        pending.append(item)
        if pending.count > 40 {
            pending.removeFirst(pending.count - 40)
        }
        lock.unlock()
        Task { await flush() }
    }

    private static func flush() async {
        lock.lock()
        if posting || pending.isEmpty {
            lock.unlock()
            return
        }
        posting = true
        let batch = pending
        pending.removeAll()
        lock.unlock()
        let client: CloudClient? = await MainActor.run {
            guard JarvisCloud.isConfigured else { return nil }
            return try? JarvisCloudAPI.client()
        }
        guard let client else {
            lock.lock()
            pending.insert(contentsOf: batch.suffix(20), at: 0)
            if pending.count > 40 { pending.removeFirst(pending.count - 40) }
            posting = false
            lock.unlock()
            return
        }
        let accepted = await client.postVoiceDebug(events: batch)
        lock.lock()
        if !accepted {
            pending.insert(contentsOf: batch.suffix(20), at: 0)
            if pending.count > 40 { pending.removeFirst(pending.count - 40) }
            posting = false
            lock.unlock()
            return
        }
        let more = !pending.isEmpty
        posting = false
        lock.unlock()
        if more { await flush() }
    }
}
