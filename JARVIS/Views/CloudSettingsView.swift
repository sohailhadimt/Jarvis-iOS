import SwiftUI

struct CloudSettingsView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(\.scenePhase) private var scenePhase
    @State private var token = ""
    @State private var report = ""
    @State private var busy = false

    private var cyan: Color { Color(red: 0, green: 0.898, blue: 0.949) }

    var body: some View {
        @Bindable var settings = settings
        Form {
            Section {
                TextField("Backend URL", text: $settings.cloudBaseURL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                SecureField("App token", text: $token)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Button("Save token to Keychain") {
                    KeychainStore.set(token, for: .jarvisCloud)
                    report = token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        ? "App token removed from the Keychain."
                        : "App token saved to the Keychain."
                    CloudMonitor.shared.setVisible(scenePhase == .active)
                }
            } header: {
                Text("JARVIS Cloud")
            } footer: {
                Text("Other routes send Authorization Bearer with this token. The backend does not send email, publish a site, or take payment.")
            }

            Section {
                Button(busy ? "Testing…" : "Test connection") {
                    test()
                }
                .disabled(busy)
                if !report.isEmpty {
                    Text(report)
                        .font(.footnote)
                        .foregroundStyle(.white.opacity(0.7))
                }
            } footer: {
                Text("Test connection calls GET /health and does not need the app token.")
            }
        }
        .navigationTitle("JARVIS Cloud")
        .scrollContentBackground(.hidden)
        .background(Color.black)
        .toolbar(.visible, for: .navigationBar)
        .tint(cyan)
        .onAppear {
            token = KeychainStore.get(.jarvisCloud) ?? ""
        }
        .onChange(of: settings.cloudBaseURL) { _, _ in
            CloudMonitor.shared.setVisible(scenePhase == .active)
        }
    }

    private func test() {
        busy = true
        report = ""
        let raw = settings.cloudBaseURL
        Task {
            defer { busy = false }
            do {
                let health = try await JarvisCloudAPI.health(url: raw)
                var lines = [
                    health.ok ? "Connected." : "The backend answered and reported a problem.",
                    "Service \(health.service), version \(health.version).",
                    "Database \(health.db).",
                    "External actions \(health.externalActions ? "enabled" : "off").",
                ]
                if let message = health.message, !message.isEmpty {
                    lines.append(message)
                }
                if KeychainStore.get(.jarvisCloud) == nil {
                    lines.append("Health succeeded. An app token is still required for other routes.")
                }
                report = lines.joined(separator: " ")
            } catch {
                report = JarvisLines.explain(error)
            }
        }
    }
}
