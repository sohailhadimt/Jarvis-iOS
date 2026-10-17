import Foundation
import Network
import Observation

/// Whether the phone can reach the network. The path monitor stays off the main thread.
@MainActor
@Observable
final class Reachability {
    static let shared = Reachability()

    private(set) var online = true
    private let monitor = NWPathMonitor()
    private var started = false

    func start() {
        guard !started else { return }
        started = true
        monitor.pathUpdateHandler = { path in
            let ok = path.status == .satisfied
            Task { @MainActor in
                let was = Reachability.shared.online
                Reachability.shared.online = ok
                if ok, !was { OfflineQueue.shared.flush() }
            }
        }
        monitor.start(queue: DispatchQueue(label: "jarvis.reachability", qos: .utility))
    }
}

/// Typed lines held while the phone is offline, then sent once the line returns.
@MainActor
final class OfflineQueue {
    static let shared = OfflineQueue()

    private let key = "jarvis.offline.queue"
    private var lines: [String] = []
    private var flushing = false

    private init() {
        lines = UserDefaults.standard.stringArray(forKey: key) ?? []
    }

    func enqueue(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        lines.append(trimmed)
        if lines.count > 8 { lines.removeFirst(lines.count - 8) }
        UserDefaults.standard.set(lines, forKey: key)
    }

    func flush() {
        guard !flushing, Reachability.shared.online, !lines.isEmpty else { return }
        flushing = true
        let batch = lines
        lines = []
        UserDefaults.standard.set(lines, forKey: key)
        let spoken = batch.count == 1 ? batch[0] : "While I was offline: " + batch.joined(separator: ". ")
        AssistantEngine.shared.ask(spoken)
        flushing = false
    }
}
