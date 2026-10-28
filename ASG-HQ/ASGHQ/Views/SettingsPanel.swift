import SwiftUI

struct SettingsPanel: View {
    @ObservedObject var session: HQSession
    @State private var token = ""
    @State private var baseURL = HQSettings.baseURLString
    @State private var name = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Settings").font(.title3.weight(.bold)).foregroundStyle(HQTheme.gold)
                Spacer()
                Button("Close") { session.closeSettings() }
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(HQTheme.gold)
            }
            Text(session.hasToken ? "A token is in the Keychain." : "No token yet. The desks cannot answer until you add one.")
                .font(.caption)
                .foregroundStyle(HQTheme.ink.opacity(0.8))
            SecureField(session.hasToken ? "Replace token" : "JARVIS app token", text: $token)
                .textFieldStyle(.roundedBorder)
            Button("Save token") {
                session.updateToken(token)
                token = ""
                Haptics.success()
            }
            .buttonStyle(GoldButtonStyle())
            .disabled(token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            TextField("Backend URL", text: $baseURL)
                .textFieldStyle(.roundedBorder)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Button("Save URL") { session.updateBaseURL(baseURL) }
                .buttonStyle(GoldButtonStyle())
            TextField("Name", text: $name)
                .textFieldStyle(.roundedBorder)
            Toggle("Haptics", isOn: Binding(
                get: { session.haptics },
                set: { session.setHaptics($0) }
            ))
            .tint(HQTheme.gold)
            .foregroundStyle(HQTheme.ink)
            Button("Sync progress") { Task { await session.sync() } }
                .buttonStyle(GoldButtonStyle())
            if let error = session.syncError {
                Text(error).font(.caption).foregroundStyle(HQTheme.gold)
            }
            if let status = session.status {
                Text(status).font(.caption).foregroundStyle(HQTheme.ink.opacity(0.8))
            }
            Text("ASG HQ is a private TestFlight build for internal testing. It is not submitted to the App Store.")
                .font(.caption2)
                .foregroundStyle(HQTheme.ink.opacity(0.65))
            Spacer()
            Text("ASG HQ \(version) (\(build))")
                .font(.caption2)
                .foregroundStyle(HQTheme.ink.opacity(0.5))
        }
        .padding(16)
        .frame(width: 420)
        .frame(maxHeight: .infinity)
        .background(HQTheme.panel)
        .overlay(Rectangle().frame(width: 1).foregroundStyle(HQTheme.gold), alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .trailing)
        .onAppear { name = session.playerName }
        .onChange(of: name) { _, newValue in
            session.rename(newValue)
        }
    }

    private var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
    }

    private var build: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
    }
}
