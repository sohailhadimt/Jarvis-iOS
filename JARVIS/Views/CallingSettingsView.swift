import SwiftUI

struct CallingSettingsView: View {
    @Environment(AppSettings.self) private var settings
    @State private var report = "Calling not set up."
    @State private var busy = false

    var body: some View {
        Form {
            Section {
                Text(report)
                    .font(.footnote)
                    .foregroundStyle(.white.opacity(0.85))
                Button(busy ? "Checking…" : "Check again") { refresh() }
                    .disabled(busy)
            } header: {
                Text("Phone calls")
            } footer: {
                Text("Calling not set up until the worker has its Twilio secrets and the UK number. The auth token is never stored in this app. A plain call still opens the Phone app. Call someone and tell them a message only after you say yes or tap Approve.")
            }
        }
        .navigationTitle("Calling")
        .scrollContentBackground(.hidden)
        .background(Color.black)
        .toolbar(.visible, for: .navigationBar)
        .tint(settings.primaryColor)
        .onAppear { refresh() }
    }

    private func refresh() {
        busy = true
        Task {
            defer { busy = false }
            guard JarvisCloud.isConfigured else {
                report = "Calling not set up. Add the JARVIS Cloud URL and app token first. The Twilio token stays on the worker, not on this iPhone."
                return
            }
            do {
                let config = try await JarvisCloudAPI.client().callingConfig()
                if config.configured {
                    report = "Calling is ready. Outbound calls use the UK number on the worker. This iPhone does not hold the Twilio token."
                } else if config.missing.isEmpty {
                    report = "Calling not set up."
                } else {
                    report = "Calling not set up. Still missing on the worker: \(config.missing.joined(separator: ", "))."
                }
            } catch {
                report = "Calling not set up. \(error.localizedDescription)"
            }
        }
    }
}
