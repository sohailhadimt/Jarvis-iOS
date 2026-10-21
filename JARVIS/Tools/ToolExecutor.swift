import Foundation
import MessageUI
import UIKit

struct MessageDraft: Identifiable, Sendable {
    let id = UUID()
    let recipients: [String]
    let body: String
}

struct MailDraft: Identifiable, Sendable {
    let id = UUID()
    let recipients: [String]
    let subject: String
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
    var onComposeMail: ((MailDraft) -> Void)?
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
            let digits = AppLauncher.digits(number)
            guard !digits.isEmpty, let url = URL(string: "tel://\(digits)") else { throw ToolFailure("Invalid number.") }
            if CarrierCallHook.enabled {
                return .result(CarrierCallHook.place(to: digits))
            }
            try await AppLauncher.open(url)
            return .result("Calling \(who).")

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

        case "send_email":
            let (who, address) = try await resolveEmail(name: arg("contact_name"), email: arg("email"))
            let body = arg("body") ?? ""
            let subject = arg("subject") ?? ""
            guard MFMailComposeViewController.canSendMail() else { throw ToolFailure("Mail isn't set up on this iPhone.") }
            return .confirm(PendingAction(summary: "Email \(who): \"\(body)\". Shall I open it for you to send?") { [weak self] in
                guard AppLauncher.isForeground else { return "Open JARVIS on screen so I can show the email." }
                self?.onComposeMail?(MailDraft(recipients: [address], subject: subject, body: body))
                return "Here's the email to \(who). Tap send when you're happy."
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
            return .result("Couldn't find \(q) in the music library. Add a music Shortcut in Settings > Apps for streaming.")

        case "set_timer":
            guard !s.timerShortcut.isEmpty else { throw ToolFailure("No timer Shortcut set. Add one in Settings > Apps.") }
            let secs = Int(a["duration_seconds"]?.double ?? 0)
            guard secs > 0, let url = AppLauncher.shortcutURL(name: s.timerShortcut, input: String(secs)) else { throw ToolFailure("Invalid duration.") }
            try await AppLauncher.open(url)
            return .result("Started the '\(s.timerShortcut)' shortcut for \(secs) seconds.")

        case "set_alarm":
            guard !s.alarmShortcut.isEmpty else { throw ToolFailure("No alarm Shortcut set. Add one in Settings > Apps.") }
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
            guard let key = KeychainStore.get(.openAI) else { throw LLMError.missingKey("OpenAI web search") }
            let answer = try await ResponsesClient.answer(
                input: [ChatMessage(role: "user", content: arg("query") ?? "")],
                instructions: "Research the question and answer factually and concisely. Use British English.",
                model: s.searchModel, apiKey: key)
            lastCitations += answer.citations
            let sources = answer.citations.prefix(5).map { "- \($0.title): \($0.url)" }.joined(separator: "\n")
            return .result(answer.text + (sources.isEmpty ? "" : "\nSources:\n" + sources))

        case "create_cloud_task":
            guard let goal = arg("goal") else { throw ToolFailure("What should the cloud task do?") }
            let task = try await JarvisCloudAPI.client().createTask(goal: goal, schedule: arg("schedule"))
            await CloudMonitor.shared.refresh()
            return .result("Created \(task.id). Status \(task.status). Goal: \(task.goal)")

        case "get_briefing":
            let briefing = try await JarvisCloudAPI.client().briefing()
            return .result(CloudSpeech.briefing(briefing))

        case "list_tasks":
            let tasks = try await JarvisCloudAPI.client().tasks(status: arg("status"))
            return .result(CloudSpeech.tasks(tasks))

        case "get_task":
            guard let id = arg("task_id") else { throw ToolFailure("Which task?") }
            let detail = try await JarvisCloudAPI.client().task(id: id)
            return .result(CloudSpeech.taskDetail(detail))

        case "list_approvals":
            let approvals = try await JarvisCloudAPI.client().approvals(status: arg("status") ?? "pending")
            return .result(CloudSpeech.approvals(approvals))

        case "approve_approval", "reject_approval":
            return try await cloudDecision(approve: name == "approve_approval", id: arg("approval_id"))

        case "search_memory":
            let rows = try await JarvisCloudAPI.client().memory(query: arg("query"))
            return .result(CloudSpeech.memory(rows))

        case "save_memory":
            guard let content = arg("content") else { throw ToolFailure("What should I remember?") }
            let saved = try await JarvisCloudAPI.client().createMemory(
                content: content, key: arg("key"), tags: stringList(a, "tags"), sourceURLs: [])
            await CloudMonitor.shared.refresh()
            return .result("Stored memory \(saved.id): \(saved.content)")

        case "pipeline_summary":
            let rows = try await JarvisCloudAPI.client().pipeline()
            return .result(CloudSpeech.pipeline(rows))

        case "place_outbound_call":
            let number = arg("to") ?? arg("phone_number") ?? ""
            let who = arg("contact_name") ?? "them"
            let brief = arg("brief") ?? arg("purpose") ?? ""
            guard !number.isEmpty, !brief.isEmpty else {
                return .result("Need a number and what to say. Nothing was dialled.")
            }
            return .confirm(PendingAction(summary: "Ring \(who)? Nothing is dialled until you tap Approve. The call is for Master Hadi.") {
                guard let client = try? JarvisCloudAPI.client() else {
                    return "The JARVIS cloud is not configured. Nothing was dialled."
                }
                switch await client.placeOutboundCall(to: number, contactName: who, brief: brief) {
                case .placed:
                    return "The call is placed. I am speaking for Master Hadi."
                case .notSetUp:
                    return "Calling is not set up. Nothing was dialled."
                case .failed(let message):
                    return message
                }
            })

        case "shop_around":
            let goal = arg("goal") ?? ""
            guard !goal.isEmpty else { return .result("What should I shop for? Nothing was called.") }
            let providers = ShopAround.providers(in: [goal, arg("providers") ?? ""].joined(separator: "\n"))
            let draft = try await JarvisCloudAPI.client().createShopDraft(goal: goal, providers: providers)
            guard !draft.id.isEmpty else {
                return .result("\(draft.message) Nothing was called.")
            }
            let huntID = draft.id
            return .confirm(PendingAction(summary: "Start those quote calls? Nothing is rung until you tap Approve. Nothing is booked.") {
                guard let client = try? JarvisCloudAPI.client() else {
                    return "The JARVIS cloud is not configured. Nothing was called."
                }
                return (try? await client.startShop(huntID: huntID)) ?? "I could not start those calls. Nothing was booked."
            })

        case "book_quote":
            let client = try JarvisCloudAPI.client()
            let rows = try await client.callHunts()
            let requestedHunt = arg("hunt_id")
            let hunt = rows.first { $0.id == requestedHunt }
                ?? rows.first { $0.status == "comparing" || $0.status == "awaiting_approval" }
            guard let hunt else { return .result("There is no comparison to book. Nothing was dialled.") }
            let requestedQuote = arg("quote_id")
            let quote = hunt.quotes.first { $0.id == requestedQuote && $0.status == "quoted" }
                ?? hunt.quotes.first { $0.id == hunt.recommendedId && $0.status == "quoted" }
                ?? hunt.quotes.first { $0.status == "quoted" }
            guard let quote else { return .result("There is no quote to book yet. Nothing was dialled.") }
            let huntID = hunt.id
            let quoteID = quote.id
            let business = quote.business.isEmpty ? "that business" : quote.business
            return .confirm(PendingAction(summary: "Book \(business)? Nothing is dialled until you tap Approve. Nothing is paid.") {
                guard let client = try? JarvisCloudAPI.client() else {
                    return "The JARVIS cloud is not configured. Nothing was booked."
                }
                return await client.chooseHunt(huntID: huntID, quoteID: quoteID) ?? "I could not book that. Nothing was paid."
            })

        case "send_sms":
            let number = arg("to") ?? arg("phone_number") ?? ""
            let body = arg("body") ?? ""
            let who = arg("contact_name") ?? "them"
            guard !number.isEmpty, !body.isEmpty else {
                return .result("Need a number and a message. Nothing was sent.")
            }
            return .confirm(PendingAction(summary: "Text \(who)? Nothing is sent until you tap Approve.") {
                guard let client = try? JarvisCloudAPI.client() else {
                    return "The JARVIS cloud is not configured. Nothing was sent."
                }
                return await client.sendTwilioSms(to: number, body: body)
            })

        default:
            return .result("ERROR: unknown tool \(name)")
        }
    }

    private func stringList(_ a: JSONValue, _ key: String) -> [String] {
        if let values = a[key]?.array {
            return values.compactMap(\.string).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        }
        guard let raw = a[key]?.string else { return [] }
        return raw.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }

    /// Approve and reject always wait for a spoken yes. The summary comes from the pending row, not the model.
    private func cloudDecision(approve: Bool, id: String?) async throws -> ToolOutcome {
        guard let id else { throw ToolFailure("Which approval?") }
        let client = try JarvisCloudAPI.client()
        let pending = try await client.approvals(status: "pending")
        guard let found = pending.first(where: { $0.id == id }) else {
            return .result("That approval is not in the pending list. Nothing was changed.")
        }
        let summary = approve
            ? "Approve this? \(found.summary) Nothing will be emailed, published or paid."
            : "Reject this? \(found.summary)"
        return .confirm(PendingAction(summary: summary) {
            do {
                let decision = try await client.decide(id: id, approve: approve, reason: nil)
                await CloudMonitor.shared.refresh()
                let sent = decision.externalActionTaken ? "An external action was recorded." : "Nothing was sent."
                return "\(approve ? "Approved" : "Rejected"). \(found.summary) \(sent)"
            } catch {
                return "ERROR: \(error.localizedDescription)"
            }
        })
    }

    private func webhookAction(task: String?, urlString: String, key: KeychainKey, label: String, note: String) throws -> ToolOutcome {
        guard let task else { throw ToolFailure("What's the task?") }
        guard let url = URL(string: urlString), url.scheme == "https" || url.scheme == "http" else {
            throw ToolFailure("The webhook URL in Settings > Apps is invalid.")
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

    private func resolveEmail(name: String?, email: String?) async throws -> (String, String) {
        if let email, email.contains("@") { return (name ?? email, email) }
        guard let name else { throw ToolFailure("I need a contact name or an email address.") }
        let hits = try await ContactsService.search(name).filter { !$0.emails.isEmpty }
        guard let first = hits.first, let address = first.emails.first else {
            throw ToolFailure("No contact named \(name) with an email address.")
        }
        if hits.count > 1, !hits.contains(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
            throw ToolFailure("Several contacts match \(name): \(hits.prefix(5).map(\.name).joined(separator: ", ")). Ask the user which one.")
        }
        let exact = hits.first { $0.name.caseInsensitiveCompare(name) == .orderedSame } ?? first
        return (exact.name, exact.emails.first ?? address)
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
