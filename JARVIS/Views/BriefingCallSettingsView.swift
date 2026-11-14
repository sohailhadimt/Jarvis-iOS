import SwiftUI

/// "Call me at": JARVIS phones the owner's mobile with the morning briefing on the chosen days.
struct BriefingCallSettingsView: View {
    @State private var enabled = false
    @State private var time = Calendar.current.date(from: DateComponents(hour: 7, minute: 30)) ?? Date()
    @State private var days: Set<Int> = [1, 2, 3, 4, 5]
    @State private var loaded = false
    @State private var note: String?

    private let names = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]

    var body: some View {
        Form {
            Section {
                Toggle("Call me with my briefing", isOn: $enabled)
                DatePicker("Call me at", selection: $time, displayedComponents: .hourAndMinute)
                HStack {
                    ForEach(0..<7, id: \.self) { day in
                        Button(names[day]) {
                            if days.contains(day) { days.remove(day) } else { days.insert(day) }
                        }
                        .buttonStyle(.bordered)
                        .tint(days.contains(day) ? .accentColor : .gray)
                        .font(.caption2)
                    }
                }
            } footer: {
                Text("London time. The call comes from the JARVIS number to your mobile, reads facts from the cloud first, then listens for follow-ups. The briefing is saved in your conversation. Off by default.")
            }
            Section {
                Button("Save") { save() }.disabled(!loaded)
                if let note { Text(note).font(.footnote).foregroundStyle(.secondary) }
            }
        }
        .navigationTitle("Morning briefing call")
        .task { await load() }
    }

    private var timeText: String {
        let parts = Calendar.current.dateComponents([.hour, .minute], from: time)
        return String(format: "%02d:%02d", parts.hour ?? 7, parts.minute ?? 30)
    }

    private func load() async {
        guard let client = try? JarvisCloudAPI.client() else {
            note = "Add the app token in Settings, JARVIS Cloud first."
            return
        }
        if let stored = await client.briefingCallSettings() {
            enabled = stored.enabled
            days = Set(stored.days)
            let bits = stored.time.split(separator: ":").compactMap { Int($0) }
            if bits.count == 2, let date = Calendar.current.date(from: DateComponents(hour: bits[0], minute: bits[1])) {
                time = date
            }
            loaded = true
        } else {
            note = "Could not reach JARVIS Cloud."
        }
    }

    private func save() {
        Task {
            guard let client = try? JarvisCloudAPI.client() else { return }
            let ok = await client.saveBriefingCallSettings(enabled: enabled, time: timeText, days: days.sorted())
            note = ok ? (enabled ? "Saved. JARVIS will ring at \(timeText) on the chosen days." : "Saved. No briefing calls.") : "Could not save. Try again."
        }
    }
}
