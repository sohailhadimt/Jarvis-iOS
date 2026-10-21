import Foundation

/// Turn and barge-in notes for the next TestFlight. Best-effort upload to the worker. No audio is stored.
enum VoiceDebugLog {
    private static let lock = NSLock()
    private static var pending: [[String: String]] = []
    private static var posting = false
    private static var attempts = 0
    private static var bound: CloudClient?
    private static let stamp: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    /// The client that minted the live token. Debug posts use it instead of looking the token up again.
    static func use(_ client: CloudClient) {
        lock.lock()
        bound = client
        lock.unlock()
        Task { await flush() }
    }

    static func note(_ kind: String, _ detail: String) {
        let item: [String: String]
        lock.lock()
        item = [
            "kind": String(kind.prefix(40)),
            "detail": safeLocked(detail),
            "at": stamp.string(from: Date()),
        ]
        pending.append(item)
        if pending.count > 40 {
            pending.removeFirst(pending.count - 40)
        }
        lock.unlock()
        Task { await flush() }
    }

    /// Drops tokens, API keys, and phone numbers before a detail leaves the phone.
    static func safe(_ detail: String) -> String {
        lock.lock()
        let text = safeLocked(detail)
        lock.unlock()
        return text
    }

    private static func safeLocked(_ detail: String) -> String {
        var text = detail.replacingOccurrences(of: "\n", with: " ")
        if let token = text.range(of: "access_token=", options: .caseInsensitive) {
            text = String(text[..<token.lowerBound]) + "access_token redacted"
        }
        text = text.replacingOccurrences(
            of: #"AIza[0-9A-Za-z_\-]{10,}"#,
            with: "[key]",
            options: .regularExpression
        )
        text = text.replacingOccurrences(
            of: #"\+\d[\d\s().-]{6,}\d"#,
            with: "[number]",
            options: .regularExpression
        )
        text = text.replacingOccurrences(
            of: #"\b0\d{2,4}[\s.-]\d{3,4}[\s.-]\d{3,4}\b"#,
            with: "[number]",
            options: .regularExpression
        )
        text = text.replacingOccurrences(
            of: #"\b0\d{9,10}\b"#,
            with: "[number]",
            options: .regularExpression
        )
        return String(text.prefix(180))
    }

    private static func flush() async {
        lock.lock()
        if posting || pending.isEmpty {
            lock.unlock()
            return
        }
        posting = true
        let batch = pending
        let client = bound
        pending.removeAll()
        lock.unlock()
        let active: CloudClient?
        if let client {
            active = client
        } else {
            active = await MainActor.run {
                guard JarvisCloud.isConfigured else { return nil }
                return try? JarvisCloudAPI.client()
            }
        }
        guard let active else {
            requeue(batch, retry: true)
            return
        }
        let accepted = await active.postVoiceDebug(events: batch)
        if !accepted {
            requeue(batch, retry: true)
            return
        }
        lock.lock()
        attempts = 0
        let more = !pending.isEmpty
        posting = false
        lock.unlock()
        if more { await flush() }
    }

    private static func requeue(_ batch: [[String: String]], retry: Bool) {
        lock.lock()
        pending.insert(contentsOf: batch.suffix(20), at: 0)
        if pending.count > 40 { pending.removeFirst(pending.count - 40) }
        posting = false
        attempts += 1
        let again = retry && attempts <= 3
        lock.unlock()
        guard again else { return }
        Task {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            await flush()
        }
    }
}
