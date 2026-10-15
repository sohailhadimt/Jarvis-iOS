import Foundation
import MessageUI
import UIKit

struct MessageDraft: Identifiable, Sendable {
    let id = UUID()
    let recipients: [String]
    let body: String
}

/// An action that waits for the user to say "yes" (or tap Confirm).
struct PendingAction {
    let summary: String
    let perform: @MainActor () async -> String
}

enum ToolOutcome {
    case result(String)
    case confirm(PendingAction)
}

@MainActor
final class ToolExecutor {
    private let calendar = CalendarService()
    var onComposeMessage: ((MessageDraft) -> Void)?
    private(set) var lastCitations: [Citation] = []

    func resetTurn() { lastCitations = [] }

    func execute(_ call: ToolCall, settings: AppSettings) async -> ToolOutcome {
        let args = JSONValue.parse(call.arguments)
        do {
            return try await run(call.name, args, settings)
        } catch {
            return .result("ERROR: \(error.localizedDescription)")
        }
    }

    // swiftlint:disable:next cyclomatic_complexity function_body_length
    private func run(_ name: String, _ a: JSONValue, _ s: AppSettings) async throws -> ToolOutcome {
        func arg(_ k: String) -> String? {
            guard let v = a[k]?.string?.trimmingCharacters(in: .whitespacesAndNewlines), !v.isEmpty else { return nil }
            return v
        }

        switch name {
        case "contacts_search":
            let hits = try await ContactsService.search(arg("query") ?? "")
            return .result(hits.isEmpty ? "No matching contacts." : hits.map(\.summary).joined(separator: "\n"))

        case "call_contact", "call_number":
            let (who, number) = try await resolvePhone(name: arg("contact_name"), number: arg("phone_number"))
            guard let url = URL(string: "tel://\(AppLauncher.digits(number))") else { throw ToolFailure("Invalid number.") }
            return .confirm(PendingAction(summary: "Call \(who) on \(number)?") {
                await Self.attempt { try await AppLauncher.open(url); return "Calling \(who). Confirm the call on screen." }
            })

        case "facetime":
            var handle = arg("handle")
            var who = handle ?? ""
            if handle == nil {
                let r = try await resolvePhone(name: arg("contact_name"), number: nil)
                who = r.0
                handle = r.1
            }
            guard let h = handle else { throw ToolFailure("Who should I FaceTime?") }
            let audio = a["audio_only"]?.bool ?? false
            let cleaned = h.contains("@") ? h : AppLauncher.digits(h)
            guard let url = URL(string: "\(audio ? "facetime-audio" : "facetime")://\(cleaned)") else { throw ToolFailure("Invalid handle.") }
            return .confirm(PendingAction(summary: "FaceTime\(audio ? " Audio" : "") \(who)?") {
                await Self.attempt { try await AppLauncher.open(url); return "Starting FaceTime with \(who)." }
            })

        case "send_imessage_or_sms":
            let (who, number) = try await resolvePhone(name: arg("contact_name"), number: arg("phone_number"))
            let body = arg("body") ?? ""
            guard MFMessageComposeViewController.canSendText() else { throw ToolFailure("This device can't send messages.") }
            return .confirm(PendingAction(summary: "Message \(who): \"\(body)\". Shall I open it for you to send?") { [weak self] in
                guard AppLauncher.isForeground else { return "Open JARVIS on screen so I can show the message." }
                self?.onComposeMessage?(MessageDraft(recipients: [number], body: body))
                return "Here's the message to \(who). Tap send when you're happy."
            })

        case "whatsapp_message":
            let (who, number) = try await resolvePhone(name: arg("contact_name"), number: arg("phone_number"))
            let body = arg("body") ?? ""
            var c = URLComponents(string: "https://wa.me/\(AppLauncher.whatsappNumber(number, defaultCountryCode: s.countryCode))")!
            c.queryItems = [URLQueryItem(name: "text", value: body)]
            guard let url = c.url else { throw ToolFailure("Couldn't build the WhatsApp link.") }
            return .confirm(PendingAction(summary: "WhatsApp \(who): \"\(body)\". Shall I open it for you to send?") {
                await Self.attempt { try await AppLauncher.open(url); return "WhatsApp is open with your message to \(who). Tap send." }
            })

        case "open_app":
            return .result(try await AppLauncher.openApp(arg("app") ?? ""))

        case "maps_directions":
            let flag = ["walking": "w", "transit": "r", "cycling": "c"][arg("mode") ?? ""] ?? "d"
            var c = URLComponents(string: "https://maps.apple.com/")!
            c.queryItems = [URLQueryItem(name: "daddr", value: arg("destination")), URLQueryItem(name: "dirflg", value: flag)]
            try await AppLauncher.open(c.url!)
            return .result("Opened directions to \(arg("destination") ?? "") in Maps.")

        case "play_music":
            let action = arg("action") ?? "play"
            if action != "play" { return .result(MusicService.control(action)) }
            guard let q = arg("query") else { return .result(MusicService.control("resume")) }
            if try await MusicService.play(query: q) { return .result("Playing \(q).") }
            if !s.musicShortcut.isEmpty, let url = AppLauncher.shortcutURL(name: s.musicShortcut, input: q) {
                try await AppLauncher.open(url)
                return .result("Asked your '\(s.musicShortcut)' shortcut to play \(q).")
            }
            return .result("Couldn't find \(q) in the music library. Add a music Shortcut in Settings > Integrations for streaming.")

        case "set_timer":
            guard !s.timerShortcut.isEmpty else { throw ToolFailure("No timer Shortcut set. Add one in Settings > Integrations.") }
            let secs = Int(a["duration_seconds"]?.double ?? 0)
            guard secs > 0, let url = AppLauncher.shortcutURL(name: s.timerShortcut, input: String(secs)) else { throw ToolFailure("Invalid duration.") }
            try await AppLauncher.open(url)
            return .result("Started the '\(s.timerShortcut)' shortcut for \(secs) seconds.")

        case "set_alarm":
            guard !s.alarmShortcut.isEmpty else { throw ToolFailure("No alarm Shortcut set. Add one in Settings > Integrations.") }
            guard let time = arg("time"), let url = AppLauncher.shortcutURL(name: s.alarmShortcut, input: time) else { throw ToolFailure("Invalid time.") }
            try await AppLauncher.open(url)
            return .result("Started the '\(s.alarmShortcut)' shortcut for \(time).")

        case "run_shortcut":
            guard let n = arg("name"), let url = AppLauncher.shortcutURL(name: n, input: arg("input")) else { throw ToolFailure("Which shortcut?") }
            try await AppLauncher.open(url)
            return .result("Running the '\(n)' shortcut.")

        case "calendar_list_events":
            return .result(try await calendar.listEvents(start: DateParsing.parse(arg("start")), days: a["days"]?.double ?? 1))

        case "calendar_create_event":
            guard let title = arg("title"), let start = DateParsing.parse(arg("start")) else { throw ToolFailure("Need a title and a valid start.") }
            return .result(try await calendar.createEvent(title: title, start: start, end: DateParsing.parse(arg("end")),
                                                          location: arg("location"), notes: arg("notes"),
                                                          allDay: a["all_day"]?.bool ?? false))

        case "calendar_update_event":
            return .result(try await calendar.updateEvent(id: arg("event_id") ?? "", title: arg("title"),
                                                          start: DateParsing.parse(arg("start")), end: DateParsing.parse(arg("end")),
                                                          location: arg("location"), notes: arg("notes")))

        case "calendar_delete_event":
            let event = try await calendar.event(id: arg("event_id") ?? "")
            let cal = calendar
            return .confirm(PendingAction(summary: "Delete '\(event.title ?? "event")' on \(DateParsing.format(event.startDate))?") {
                await Self.attempt { try cal.deleteEvent(event) }
            })

        case "reminders_list":
            return .result(try await calendar.listReminders(includeCompleted: a["include_completed"]?.bool ?? false))

        case "reminder_create":
            guard let title = arg("title") else { throw ToolFailure("Need a title.") }
            return .result(try await calendar.createReminder(title: title, due: DateParsing.parse(arg("due")), notes: arg("notes")))

        case "reminder_update":
            return .result(try await calendar.updateReminder(id: arg("reminder_id") ?? "", title: arg("title"),
                                                             due: DateParsing.parse(arg("due")), completed: a["completed"]?.bool))

        case "reminder_delete":
            let reminder = try await calendar.reminder(id: arg("reminder_id") ?? "")
            let cal = calendar
            return .confirm(PendingAction(summary: "Delete the reminder '\(reminder.title ?? "")'?") {
                await Self.attempt { try cal.deleteReminder(reminder) }
            })

        case "send_task_to_agent":
            return try webhookAction(task: arg("task"), urlString: s.agentWebhookURL, key: .agentWebhook,
                                     label: s.agentWebhookName, note: "")

        case "send_task_to_grok_bot":
            return try webhookAction(task: arg("task"), urlString: s.grokBotWebhookURL, key: .grokBotWebhook,
                                     label: "your Grok Bot", note: " The result will appear in the Bot's chat, not here.")

        case "web_search":
            guard let key = KeychainStore.get(.openAI) else { throw LLMError.missingKey("OpenAI") }
            let answer = try await ResponsesClient.answer(
                input: [ChatMessage(role: "user", content: arg("query") ?? "")],
                instructions: "Research the question and answer factually and concisely. Use British English.",
                model: s.searchModel, apiKey: key)
            lastCitations += answer.citations
            let sources = answer.citations.prefix(5).map { "- \($0.title): \($0.url)" }.joined(separator: "\n")
            return .result(answer.text + (sources.isEmpty ? "" : "\nSources:\n" + sources))

        default:
            return .result("ERROR: unknown tool \(name)")
        }
    }

    private func webhookAction(task: String?, urlString: String, key: KeychainKey, label: String, note: String) throws -> ToolOutcome {
        guard let task else { throw ToolFailure("What's the task?") }
        guard let url = URL(string: urlString), url.scheme == "https" || url.scheme == "http" else {
            throw ToolFailure("The webhook URL in Settings > Integrations is invalid.")
        }
        let secret = KeychainStore.get(key)
        return .confirm(PendingAction(summary: "Send this task to \(label): \"\(task)\"?") {
            await Self.attempt {
                let status = try await WebhookClient.sendTask(task, url: url, key: secret)
                guard (200..<300).contains(status) else { throw ToolFailure("The webhook answered \(status), so the task wasn't accepted.") }
                return "Sent to \(label).\(note)"
            }
        })
    }

    private func resolvePhone(name: String?, number: String?) async throws -> (String, String) {
        if let number, !AppLauncher.digits(number).isEmpty { return (name ?? number, number) }
        guard let name else { throw ToolFailure("I need a contact name or a number.") }
        let hits = try await ContactsService.search(name).filter { $0.bestPhone != nil }
        guard let first = hits.first, let phone = first.bestPhone else { throw ToolFailure("No contact named \(name) with a phone number.") }
        if hits.count > 1, !hits.contains(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
            throw ToolFailure("Several contacts match \(name): \(hits.prefix(5).map(\.name).joined(separator: ", ")). Ask the user which one.")
        }
        let exact = hits.first { $0.name.caseInsensitiveCompare(name) == .orderedSame } ?? first
        return (exact.name, exact.bestPhone ?? phone)
    }

    private static func attempt(_ body: @MainActor () async throws -> String) async -> String {
        do { return try await body() } catch { return error.localizedDescription }
    }
}
