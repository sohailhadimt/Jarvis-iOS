import Contacts
import EventKit
import Foundation
import MediaPlayer
import UIKit

// MARK: - Permissions (callbacks built in nonisolated code; see AudioTaps.swift for why)

enum Permissions {
    nonisolated static func contacts() async -> Bool {
        switch CNContactStore.authorizationStatus(for: .contacts) {
        case .authorized, .limited: return true
        case .notDetermined:
            return await withCheckedContinuation { c in
                nonisolated(unsafe) let store = CNContactStore() // kept alive until the callback
                store.requestAccess(for: .contacts) { granted, _ in
                    _ = store
                    c.resume(returning: granted)
                }
            }
        default: return false
        }
    }

    nonisolated static func events() async -> Bool {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess: return true
        case .notDetermined:
            return await withCheckedContinuation { c in
                nonisolated(unsafe) let store = EKEventStore()
                store.requestFullAccessToEvents { granted, _ in
                    _ = store
                    c.resume(returning: granted)
                }
            }
        default: return false
        }
    }

    nonisolated static func reminders() async -> Bool {
        switch EKEventStore.authorizationStatus(for: .reminder) {
        case .fullAccess: return true
        case .notDetermined:
            return await withCheckedContinuation { c in
                nonisolated(unsafe) let store = EKEventStore()
                store.requestFullAccessToReminders { granted, _ in
                    _ = store
                    c.resume(returning: granted)
                }
            }
        default: return false
        }
    }

    nonisolated static func mediaLibrary() async -> Bool {
        switch MPMediaLibrary.authorizationStatus() {
        case .authorized: return true
        case .notDetermined:
            return await withCheckedContinuation { c in
                MPMediaLibrary.requestAuthorization { c.resume(returning: $0 == .authorized) }
            }
        default: return false
        }
    }
}

// MARK: - Contacts

struct ContactHit: Sendable {
    let name: String
    let phones: [(label: String, number: String)]
    let emails: [String]

    var bestPhone: String? {
        phones.first { $0.label.localizedCaseInsensitiveContains("mobile") || $0.label.localizedCaseInsensitiveContains("iphone") }?.number
            ?? phones.first?.number
    }

    var summary: String {
        let p = phones.map { "\($0.label): \($0.number)" }.joined(separator: ", ")
        return "\(name)" + (p.isEmpty ? "" : " | phones: \(p)") + (emails.isEmpty ? "" : " | emails: \(emails.joined(separator: ", "))")
    }
}

enum ContactsService {
    nonisolated static func search(_ query: String) async throws -> [ContactHit] {
        guard await Permissions.contacts() else { throw ToolFailure("Contacts access is off. Enable it in iPhone Settings > JARVIS > Contacts.") }
        let store = CNContactStore()
        let keys = [CNContactGivenNameKey, CNContactFamilyNameKey, CNContactNicknameKey, CNContactOrganizationNameKey,
                    CNContactPhoneNumbersKey, CNContactEmailAddressesKey] as [CNKeyDescriptor]
        let contacts = try store.unifiedContacts(matching: CNContact.predicateForContacts(matchingName: query), keysToFetch: keys)
        return contacts.prefix(10).map { c in
            let name = [c.givenName, c.familyName].filter { !$0.isEmpty }.joined(separator: " ")
            let phones = c.phoneNumbers.map { lv in
                (label: CNLabeledValue<CNPhoneNumber>.localizedString(forLabel: lv.label ?? "phone"), number: lv.value.stringValue)
            }
            return ContactHit(name: name.isEmpty ? c.organizationName : name,
                              phones: phones,
                              emails: c.emailAddresses.map { $0.value as String })
        }
    }
}

struct ToolFailure: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

// MARK: - Dates

enum DateParsing {
    static func parse(_ text: String?) -> Date? {
        guard let text = text?.trimmingCharacters(in: .whitespaces), !text.isEmpty else { return nil }
        let iso = ISO8601DateFormatter()
        if let d = iso.date(from: text) { return d }
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = iso.date(from: text) { return d }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_GB_POSIX")
        f.timeZone = .current
        for format in ["yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd'T'HH:mm", "yyyy-MM-dd HH:mm", "yyyy-MM-dd"] {
            f.dateFormat = format
            if let d = f.date(from: text) { return d }
        }
        return nil
    }

    static func format(_ date: Date?) -> String {
        guard let date else { return "none" }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_GB")
        f.dateFormat = "EEE d MMM yyyy, HH:mm"
        let iso = DateFormatter()
        iso.locale = Locale(identifier: "en_GB_POSIX")
        iso.dateFormat = "yyyy-MM-dd'T'HH:mm"
        return f.string(from: date) + " (" + iso.string(from: date) + ")"
    }
}

// MARK: - Calendar & Reminders

struct ReminderInfo: Sendable {
    let id: String
    let title: String
    let due: Date?
    let completed: Bool
}

@MainActor
final class CalendarService {
    private var store = EKEventStore()

    private func eventsReady() async throws {
        let wasDetermined = EKEventStore.authorizationStatus(for: .event) != .notDetermined
        guard await Permissions.events() else {
            throw ToolFailure("Calendar access is off. Enable Full Access in iPhone Settings > JARVIS > Calendars.")
        }
        if !wasDetermined { store = EKEventStore() } // pick up the new grant
    }

    private func remindersReady() async throws {
        let wasDetermined = EKEventStore.authorizationStatus(for: .reminder) != .notDetermined
        guard await Permissions.reminders() else {
            throw ToolFailure("Reminders access is off. Enable Full Access in iPhone Settings > JARVIS > Reminders.")
        }
        if !wasDetermined { store = EKEventStore() }
    }

    func listEvents(start: Date?, days: Double) async throws -> String {
        try await eventsReady()
        let from = start ?? Calendar.current.startOfDay(for: .now)
        let to = from.addingTimeInterval(max(days, 0.1) * 86_400)
        let predicate = store.predicateForEvents(withStart: from, end: to, calendars: nil)
        let events = store.events(matching: predicate).sorted { $0.startDate < $1.startDate }
        guard !events.isEmpty else { return "No events between \(DateParsing.format(from)) and \(DateParsing.format(to))." }
        return events.prefix(30).map { e in
            "event_id: \(e.eventIdentifier ?? "?") | \(e.title ?? "Untitled") | \(e.isAllDay ? "all day " : "")\(DateParsing.format(e.startDate)) to \(DateParsing.format(e.endDate))"
                + (e.location.map { " | at \($0)" } ?? "") + " | calendar: \(e.calendar.title)"
        }.joined(separator: "\n")
    }

    func createEvent(title: String, start: Date, end: Date?, location: String?, notes: String?, allDay: Bool) async throws -> String {
        try await eventsReady()
        guard let calendar = store.defaultCalendarForNewEvents else { throw ToolFailure("No default calendar is set.") }
        let event = EKEvent(eventStore: store)
        event.calendar = calendar
        event.title = title
        event.startDate = start
        event.endDate = end ?? start.addingTimeInterval(3_600)
        event.isAllDay = allDay
        event.location = location
        event.notes = notes
        try store.save(event, span: .thisEvent, commit: true)
        return "Created event_id: \(event.eventIdentifier ?? "?") '\(title)' on \(DateParsing.format(start))."
    }

    func event(id: String) async throws -> EKEvent {
        try await eventsReady()
        guard let e = store.event(withIdentifier: id) else { throw ToolFailure("No event with id \(id). List events first.") }
        return e
    }

    func updateEvent(id: String, title: String?, start: Date?, end: Date?, location: String?, notes: String?) async throws -> String {
        let e = try await event(id: id)
        if let title { e.title = title }
        if let start {
            let duration = e.endDate.timeIntervalSince(e.startDate)
            e.startDate = start
            e.endDate = end ?? start.addingTimeInterval(duration)
        } else if let end { e.endDate = end }
        if let location { e.location = location }
        if let notes { e.notes = notes }
        try store.save(e, span: .thisEvent, commit: true)
        return "Updated '\(e.title ?? "")' now \(DateParsing.format(e.startDate)) to \(DateParsing.format(e.endDate))."
    }

    func deleteEvent(_ e: EKEvent) throws -> String {
        try store.remove(e, span: .thisEvent, commit: true)
        return "Deleted '\(e.title ?? "event")'."
    }

    nonisolated static func fetchReminders(includeCompleted: Bool) async -> [ReminderInfo] {
        let store = EKEventStore()
        let predicate = includeCompleted
            ? store.predicateForReminders(in: nil)
            : store.predicateForIncompleteReminders(withDueDateStarting: nil, ending: nil, calendars: nil)
        return await withCheckedContinuation { c in
            store.fetchReminders(matching: predicate) { reminders in
                let infos = (reminders ?? []).map { r in
                    ReminderInfo(id: r.calendarItemIdentifier, title: r.title ?? "",
                                 due: r.dueDateComponents.flatMap { Calendar.current.date(from: $0) },
                                 completed: r.isCompleted)
                }
                c.resume(returning: infos)
            }
        }
    }

    func listReminders(includeCompleted: Bool) async throws -> String {
        try await remindersReady()
        let items = await Self.fetchReminders(includeCompleted: includeCompleted)
        guard !items.isEmpty else { return "No reminders." }
        return items.prefix(40).map {
            "reminder_id: \($0.id) | \($0.title) | due: \(DateParsing.format($0.due))\($0.completed ? " | done" : "")"
        }.joined(separator: "\n")
    }

    func createReminder(title: String, due: Date?, notes: String?) async throws -> String {
        try await remindersReady()
        guard let list = store.defaultCalendarForNewReminders() else { throw ToolFailure("No default Reminders list.") }
        let r = EKReminder(eventStore: store)
        r.calendar = list
        r.title = title
        r.notes = notes
        if let due {
            r.dueDateComponents = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: due)
            r.addAlarm(EKAlarm(absoluteDate: due))
        }
        try store.save(r, commit: true)
        return "Created reminder_id: \(r.calendarItemIdentifier) '\(title)'" + (due.map { " due \(DateParsing.format($0))" } ?? "") + "."
    }

    func reminder(id: String) async throws -> EKReminder {
        try await remindersReady()
        guard let r = store.calendarItem(withIdentifier: id) as? EKReminder else {
            throw ToolFailure("No reminder with id \(id). List reminders first.")
        }
        return r
    }

    func updateReminder(id: String, title: String?, due: Date?, completed: Bool?) async throws -> String {
        let r = try await reminder(id: id)
        if let title { r.title = title }
        if let due { r.dueDateComponents = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: due) }
        if let completed { r.isCompleted = completed }
        try store.save(r, commit: true)
        return "Updated reminder '\(r.title ?? "")'."
    }

    func deleteReminder(_ r: EKReminder) throws -> String {
        try store.remove(r, commit: true)
        return "Deleted reminder '\(r.title ?? "")'."
    }
}

// MARK: - Music

@MainActor
enum MusicService {
    /// Plays matching songs from the user's library (incl. Apple Music items added to the library).
    static func play(query: String) async throws -> Bool {
        guard await Permissions.mediaLibrary() else {
            throw ToolFailure("Media library access is off. Enable it in iPhone Settings > JARVIS > Media & Apple Music.")
        }
        for property in [MPMediaItemPropertyTitle, MPMediaItemPropertyArtist, MPMediaItemPropertyAlbumTitle] {
            let q = MPMediaQuery.songs()
            q.addFilterPredicate(MPMediaPropertyPredicate(value: query, forProperty: property, comparisonType: .contains))
            if let items = q.items, !items.isEmpty {
                let player = MPMusicPlayerController.systemMusicPlayer
                player.setQueue(with: q)
                player.play()
                return true
            }
        }
        return false
    }

    static func control(_ action: String) -> String {
        let player = MPMusicPlayerController.systemMusicPlayer
        switch action {
        case "pause": player.pause(); return "Paused."
        case "resume": player.play(); return "Resumed."
        case "next": player.skipToNextItem(); return "Skipped."
        case "previous": player.skipToPreviousItem(); return "Went back."
        default: return "Unknown music action."
        }
    }
}

// MARK: - URL launching

@MainActor
enum AppLauncher {
    /// Known deep links. Each needs its scheme in LSApplicationQueriesSchemes for canOpenURL.
    static let apps: [String: [String]] = [
        "instagram": ["instagram://app"],
        "tiktok": ["tiktok://", "snssdk1233://"],
        "snapchat": ["snapchat://"],
        "whatsapp": ["whatsapp://"],
        "youtube": ["youtube://"],
        "spotify": ["spotify://"],
        "x": ["twitter://"],
        "maps": ["maps://"],
        "google maps": ["comgooglemaps://"],
        "music": ["music://"],
        "settings": [UIApplication.openSettingsURLString],
        "shortcuts": ["shortcuts://"],
        "facetime": ["facetime://"],
        "mail": ["message://"],
        "phone": ["tel://"],
    ]

    static var isForeground: Bool { UIApplication.shared.applicationState == .active }

    @discardableResult
    static func open(_ url: URL) async throws -> String {
        guard isForeground else {
            throw ToolFailure("iOS only lets JARVIS open other apps while it's on screen. Open JARVIS and ask again.")
        }
        let ok = await UIApplication.shared.open(url)
        guard ok else { throw ToolFailure("iOS couldn't open \(url.scheme ?? "that link"). Is the app installed?") }
        return "Opened."
    }

    static func openApp(_ name: String) async throws -> String {
        let key = name.lowercased().trimmingCharacters(in: .whitespaces)
        guard let candidates = apps[key] else {
            throw ToolFailure("I don't have a deep link for \(name). Known apps: \(apps.keys.sorted().joined(separator: ", ")).")
        }
        for s in candidates {
            if let url = URL(string: s), UIApplication.shared.canOpenURL(url) {
                try await open(url)
                return "Opened \(name)."
            }
        }
        throw ToolFailure("\(name) doesn't seem to be installed.")
    }

    static func shortcutURL(name: String, input: String?) -> URL? {
        var c = URLComponents()
        c.scheme = "shortcuts"
        c.host = "x-callback-url"
        c.path = "/run-shortcut"
        var items = [URLQueryItem(name: "name", value: name)]
        if let input, !input.isEmpty {
            items += [URLQueryItem(name: "input", value: "text"), URLQueryItem(name: "text", value: input)]
        }
        items += [URLQueryItem(name: "x-success", value: "jarvis://shortcut-done"),
                  URLQueryItem(name: "x-cancel", value: "jarvis://shortcut-cancel"),
                  URLQueryItem(name: "x-error", value: "jarvis://shortcut-error")]
        c.queryItems = items
        return c.url
    }

    static func digits(_ number: String) -> String {
        let kept = number.filter { $0.isNumber || $0 == "+" }
        return kept
    }

    /// wa.me needs the full international number without "+" or leading zeros. UK 07… becomes 447…
    static func whatsappNumber(_ number: String, defaultCountryCode: String) -> String {
        var d = digits(number)
        if d.hasPrefix("+") { d.removeFirst() }
        else if d.hasPrefix("00") { d.removeFirst(2) }
        else if d.hasPrefix("0") { d = defaultCountryCode + d.dropFirst() }
        return d
    }
}
