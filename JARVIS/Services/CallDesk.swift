import AVFoundation
import CoreMotion
import EventKit
import Foundation

enum CallDeskStage {
    case dialing
    case live
    case ended

    static func of(_ call: StoredCall) -> CallDeskStage {
        if call.stage == "dialing" || call.stage == "live" || call.stage == "ended" {
            return call.stage == "dialing" ? .dialing : call.stage == "live" ? .live : .ended
        }
        switch call.status {
        case "placing", "queued", "initiated", "ringing":
            return .dialing
        case "completed", "failed", "declined", "cancelled":
            return .ended
        default:
            return .live
        }
    }
}

enum AwayCommand {
    static func matches(_ text: String) -> Bool {
        let lower = text.lowercased()
        return lower.contains("answer my calls")
            || lower.contains("stop answering my calls")
            || lower.contains("i'm back")
            || lower.contains("i am back")
            || lower.contains("cancel away")
    }
}

/// Plays a Twilio recording that the worker fetched. The player is kept so the audio is not released mid-sentence.
@MainActor
final class CallPlayback {
    static let shared = CallPlayback()
    private var player: AVAudioPlayer?

    func play(_ data: Data) -> Bool {
        guard let next = try? AVAudioPlayer(data: data) else { return false }
        player = next
        return next.play()
    }
}

/// Sends driving and calendar-busy context. The latest location is included and not kept as a trail on the phone.
@MainActor
final class DevicePresence {
    static let shared = DevicePresence()
    private let motion = CMMotionActivityManager()
    private var activity = "unknown"
    private var started = false
    private var lastPost = Date.distantPast
    private var lastBusy = Date.distantPast

    func start() {
        guard !started else { return }
        started = true
        guard CMMotionActivityManager.isActivityAvailable() else {
            Task { await self.postIfDue() }
            return
        }
        motion.startActivityUpdates(to: .main) { [weak self] update in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.note(update)
            }
        }
    }

    private func note(_ update: CMMotionActivity?) {
        guard let update else { return }
        if update.automotive {
            activity = "automotive"
        } else if update.walking || update.running {
            activity = "walking"
        } else if update.stationary {
            activity = "stationary"
        } else {
            activity = "unknown"
        }
        Task { await self.postIfDue() }
    }

    func postIfDue() async {
        guard Date().timeIntervalSince(lastPost) > 30 else { return }
        guard JarvisCloud.isConfigured, let client = try? JarvisCloudAPI.client() else { return }
        lastPost = Date()
        let fix = DeviceLocation.shared.cached()
        await client.postPresence(activity: activity, busy: Self.calendarBusy(), lat: fix?.lat, lon: fix?.lon)
        await postBusyIfDue()
    }

    /// The next fortnight of busy blocks, only when calendar access is already granted.
    private func postBusyIfDue() async {
        guard Date().timeIntervalSince(lastBusy) > 600 else { return }
        guard EKEventStore.authorizationStatus(for: .event) == .fullAccess else { return }
        guard JarvisCloud.isConfigured, let client = try? JarvisCloudAPI.client() else { return }
        lastBusy = Date()
        await client.postBusy(Self.busyBlocks())
    }

    private static func busyBlocks() -> [[String: Any]] {
        let store = EKEventStore()
        let start = Date()
        let end = Calendar.current.date(byAdding: .day, value: 14, to: start) ?? start
        let events = store.events(matching: store.predicateForEvents(withStart: start, end: end, calendars: nil))
        let formatter = ISO8601DateFormatter()
        return events.prefix(40).map { event in
            [
                "starts_at": formatter.string(from: event.startDate),
                "ends_at": formatter.string(from: event.endDate),
                "title": String((event.title ?? "").prefix(80)),
            ]
        }
    }

    private static func calendarBusy() -> Bool {
        guard EKEventStore.authorizationStatus(for: .event) == .fullAccess else { return false }
        let store = EKEventStore()
        let now = Date()
        let end = now.addingTimeInterval(60)
        let predicate = store.predicateForEvents(withStart: now, end: end, calendars: nil)
        return !store.events(matching: predicate).isEmpty
    }
}
