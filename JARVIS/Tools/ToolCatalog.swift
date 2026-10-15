import Foundation

/// JSON-schema function definitions offered to the model.
@MainActor
enum ToolCatalog {
    static let confirmTools: Set<String> = [
        "call_contact", "call_number", "facetime", "send_imessage_or_sms", "whatsapp_message",
        "send_task_to_agent", "send_task_to_grok_bot", "calendar_delete_event", "reminder_delete",
    ]

    private static func fn(_ name: String, _ description: String,
                           _ properties: [String: JSONValue] = [:], required: [String] = []) -> JSONValue {
        [
            "type": "function",
            "function": [
                "name": .string(name),
                "description": .string(description),
                "parameters": [
                    "type": "object",
                    "properties": .object(properties),
                    "required": .array(required.map(JSONValue.string)),
                ],
            ],
        ]
    }

    private static func str(_ d: String) -> JSONValue { ["type": "string", "description": .string(d)] }
    private static func num(_ d: String) -> JSONValue { ["type": "number", "description": .string(d)] }
    private static func bool(_ d: String) -> JSONValue { ["type": "boolean", "description": .string(d)] }
    private static func oneOf(_ values: [String], _ d: String) -> JSONValue {
        ["type": "string", "enum": .array(values.map(JSONValue.string)), "description": .string(d)]
    }

    static func definitions(settings: AppSettings, includeWebSearch: Bool) -> [JSONValue] {
        let iso = "Local date-time, ISO 8601, e.g. 2026-10-15T14:30"
        var tools: [JSONValue] = [
            fn("contacts_search", "Search the user's contacts by name. Returns names, phone numbers and emails.",
               ["query": str("Name or part of a name")], required: ["query"]),
            fn("call_contact", "Phone call a contact by name (iOS shows a call confirmation).",
               ["contact_name": str("Contact name")], required: ["contact_name"]),
            fn("call_number", "Phone call a number (iOS shows a call confirmation).",
               ["phone_number": str("Phone number")], required: ["phone_number"]),
            fn("facetime", "Start a FaceTime video or audio call with a contact name or number/email.",
               ["contact_name": str("Contact name (optional if handle given)"),
                "handle": str("Phone number or Apple ID email"),
                "audio_only": bool("true for FaceTime Audio")]),
            fn("send_imessage_or_sms", "Prepare an iMessage/SMS with the body prefilled. The user taps Send.",
               ["contact_name": str("Contact name"), "phone_number": str("Number if no contact"),
                "body": str("Message text")], required: ["body"]),
            fn("whatsapp_message", "Open WhatsApp with a chat and prefilled message. The user taps Send.",
               ["contact_name": str("Contact name"), "phone_number": str("Number if no contact"),
                "body": str("Message text")], required: ["body"]),
            fn("open_app", "Open an app by deep link.",
               ["app": oneOf(AppLauncher.apps.keys.sorted(), "App to open")], required: ["app"]),
            fn("maps_directions", "Open Apple Maps with directions.",
               ["destination": str("Address or place"),
                "mode": oneOf(["driving", "walking", "transit", "cycling"], "Travel mode")],
               required: ["destination"]),
            fn("play_music", "Play music from the user's library, or control playback.",
               ["query": str("Song, artist or album (omit for controls)"),
                "action": oneOf(["play", "pause", "resume", "next", "previous"], "Default play")]),
            fn("set_timer", "Start a timer via the user's timer Shortcut.",
               ["duration_seconds": num("Length in seconds"), "label": str("Optional label")],
               required: ["duration_seconds"]),
            fn("set_alarm", "Set an alarm via the user's alarm Shortcut.",
               ["time": str("Alarm time, 24h HH:mm"), "label": str("Optional label")], required: ["time"]),
            fn("calendar_list_events", "List calendar events.",
               ["start": str("\(iso). Default: today 00:00"), "days": num("How many days, default 1")]),
            fn("calendar_create_event", "Create a calendar event.",
               ["title": str("Title"), "start": str(iso), "end": str("\(iso). Default start + 1h"),
                "location": str("Location"), "notes": str("Notes"), "all_day": bool("All-day event")],
               required: ["title", "start"]),
            fn("calendar_update_event", "Change an event. Get event_id from calendar_list_events first.",
               ["event_id": str("event_id"), "title": str("New title"), "start": str(iso), "end": str(iso),
                "location": str("New location"), "notes": str("New notes")], required: ["event_id"]),
            fn("calendar_delete_event", "Delete an event by event_id.",
               ["event_id": str("event_id")], required: ["event_id"]),
            fn("reminders_list", "List reminders.", ["include_completed": bool("Include completed ones")]),
            fn("reminder_create", "Create a reminder.",
               ["title": str("Title"), "due": str(iso), "notes": str("Notes")], required: ["title"]),
            fn("reminder_update", "Change or complete a reminder. Get reminder_id from reminders_list.",
               ["reminder_id": str("reminder_id"), "title": str("New title"), "due": str(iso),
                "completed": bool("Mark done")], required: ["reminder_id"]),
            fn("reminder_delete", "Delete a reminder by reminder_id.",
               ["reminder_id": str("reminder_id")], required: ["reminder_id"]),
        ]

        let names = settings.shortcuts.map(\.name).filter { !$0.isEmpty }
        if !names.isEmpty {
            let list = settings.shortcuts.map { "\($0.name)\($0.note.isEmpty ? "" : " (\($0.note))")" }.joined(separator: "; ")
            tools.append(fn("run_shortcut", "Run one of the user's Shortcuts. Available: \(list).",
                            ["name": oneOf(names, "Shortcut name"), "input": str("Optional text input")],
                            required: ["name"]))
        }
        if !settings.agentWebhookURL.isEmpty {
            tools.append(fn("send_task_to_agent", "Send a task to the user's own agent webhook (\(settings.agentWebhookName)).",
                            ["task": str("Self-contained task description")], required: ["task"]))
        }
        if !settings.grokBotWebhookURL.isEmpty {
            tools.append(fn("send_task_to_grok_bot",
                            "Send a task to the user's Grok Bot through a routine webhook. The Bot posts results in its own chat; nothing comes back here.",
                            ["task": str("Self-contained task description")], required: ["task"]))
        }
        if includeWebSearch {
            tools.append(fn("web_search", "Search the web for current facts, news, prices, weather, sport, opening times etc.",
                            ["query": str("The question to research")], required: ["query"]))
        }
        if JarvisCloud.isConfigured {
            let taskStatus = ["planning", "running", "awaiting_approval", "completed", "failed"]
            tools.append(fn("create_cloud_task",
                            "Create a task on JARVIS Cloud. It is planned on the backend. Nothing is emailed, published or paid.",
                            ["goal": str("What the cloud should do"),
                             "schedule": str("Optional 5-field UTC cron. Omit to run once.")],
                            required: ["goal"]))
            tools.append(fn("get_briefing",
                            "Read the stored JARVIS Cloud briefing. The result separates facts from recommendations. Speak facts first, then recommendations. Add nothing that is not in the result."))
            tools.append(fn("list_tasks", "List stored JARVIS Cloud tasks.",
                            ["status": oneOf(taskStatus, "Optional status filter")]))
            tools.append(fn("get_task", "Read one stored JARVIS Cloud task, including subtasks, progress, findings and drafts.",
                            ["task_id": str("Task id from list_tasks")], required: ["task_id"]))
            tools.append(fn("list_approvals", "List stored JARVIS Cloud approvals. Defaults to pending.",
                            ["status": oneOf(["pending", "approved", "rejected"], "Optional status. Default pending")]))
            tools.append(fn("approve_approval",
                            "Ask the user to approve one pending cloud approval. The app reads the stored summary and waits for yes. Nothing is emailed, published or paid.",
                            ["approval_id": str("Approval id from list_approvals")], required: ["approval_id"]))
            tools.append(fn("reject_approval",
                            "Ask the user to reject one pending cloud approval. The app reads the stored summary and waits for yes.",
                            ["approval_id": str("Approval id from list_approvals")], required: ["approval_id"]))
            tools.append(fn("search_memory", "Search stored JARVIS Cloud memory. Say nothing is stored when the result is empty.",
                            ["query": str("Substring to search. Omit to list recent memory.")]))
            tools.append(fn("save_memory", "Store one fact in JARVIS Cloud memory.",
                            ["content": str("Fact to store"),
                             "key": str("Optional key"),
                             "tags": str("Optional comma-separated tags")],
                            required: ["content"]))
            tools.append(fn("pipeline_summary",
                            "Summarise the stored sales pipeline. Null monthly revenue is unknown and is not zero."))
        }
        return tools
    }
}
