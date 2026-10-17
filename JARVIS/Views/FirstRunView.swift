import AVFoundation
import EventKit
import SwiftUI

/// First launch. Skipping still leaves JARVIS usable on this iPhone.
struct FirstRunView: View {
    var onFinish: () -> Void
    @Environment(AppSettings.self) private var settings
    @State private var page = 0
    @State private var token = ""
    @State private var lock = false
    @State private var briefing = true
    @State private var hour = 7
    @State private var minute = 30
    @State private var micReady = false
    @FocusState private var tokenFocused: Bool

    var body: some View {
        ZStack {
            JarvisBackdrop().ignoresSafeArea()
            VStack(spacing: 0) {
                JarvisWordmark()
                    .padding(.top, 28)
                TabView(selection: $page) {
                    pageWelcome.tag(0)
                    pageMic.tag(1)
                    pageLock.tag(2)
                    pageBriefing.tag(3)
                    pageCloud.tag(4)
                }
                .tabViewStyle(.page(indexDisplayMode: .always))
                Button(page == 4 ? "Begin" : "Continue") { advance() }
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 52)
                    .background(Color(hex: "#2E8BFF"), in: Capsule())
                    .padding(.horizontal, 24)
                    .padding(.bottom, 8)
                Button("Skip for now") { finish() }
                    .font(.system(size: 15))
                    .foregroundStyle(Color(hex: "#8E8A99"))
                    .padding(.bottom, 20)
            }
        }
        .preferredColorScheme(.dark)
    }

    private var pageWelcome: some View {
        copy(
            title: "Good to see you, Sohail.",
            body: "I'm JARVIS. I'll stay on this iPhone with you, and the worker keeps the night watch."
        )
    }

    private var pageMic: some View {
        copy(
            title: micReady ? "I can hear you." : "Let me hear you.",
            body: "Microphone and speech stay on this iPhone. I only listen after you start a conversation, or when you say Hey Siri, JARVIS."
        )
    }

    private var pageLock: some View {
        VStack(spacing: 16) {
            copy(
                title: "Keep the screen to yourself.",
                body: "Face ID, or your passcode, covers the home screen when you leave. You can change this later."
            )
            Toggle("Lock with Face ID", isOn: $lock)
                .font(.system(size: 16))
                .tint(Color(hex: "#2E8BFF"))
                .padding(.horizontal, 28)
        }
    }

    private var pageBriefing: some View {
        VStack(spacing: 16) {
            copy(
                title: "A briefing, when you want it.",
                body: "I'll remind you at this time, London. Opening me after that reads the briefing. The worker routine stays off until you enable it in Agents."
            )
            Toggle("Daily briefing", isOn: $briefing)
                .font(.system(size: 16))
                .tint(Color(hex: "#2E8BFF"))
                .padding(.horizontal, 28)
            HStack {
                Picker("Hour", selection: $hour) {
                    ForEach(0..<24, id: \.self) { Text(String(format: "%02d", $0)).tag($0) }
                }
                .pickerStyle(.wheel)
                .frame(width: 80, height: 120)
                Picker("Minute", selection: $minute) {
                    ForEach([0, 15, 30, 45], id: \.self) { Text(String(format: "%02d", $0)).tag($0) }
                }
                .pickerStyle(.wheel)
                .frame(width: 80, height: 120)
            }
        }
    }

    private var pageCloud: some View {
        ScrollView {
            VStack(spacing: 16) {
                copy(
                    title: "The worker token, if you have it.",
                    body: "Calling, the team, and the cloud briefing need the app token from the worker. It stays in the Keychain. Leave this blank and I'll still talk on the phone."
                )
                SecureField("App token", text: $token)
                    .textContentType(.password)
                    .focused($tokenFocused)
                    .submitLabel(.done)
                    .onSubmit { tokenFocused = false }
                    .font(.system(size: 16))
                    .padding(.horizontal, 16)
                    .frame(height: 48)
                    .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .padding(.horizontal, 24)
            }
        }
        .scrollDismissesKeyboard(.interactively)
    }

    private func copy(title: String, body: String) -> some View {
        VStack(spacing: 12) {
            Text(title)
                .font(.system(size: 26, weight: .regular))
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
            Text(body)
                .font(.system(size: 16))
                .foregroundStyle(Color(hex: "#A39BB4"))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func advance() {
        JarvisHaptics.tap()
        if page == 1 { Task { await allowMicrophone() } }
        if page == 3 { Task { await allowCalendar() } }
        if page < 4 {
            withAnimation(.easeOut(duration: 0.25)) { page += 1 }
        } else {
            finish()
        }
    }

    private func allowMicrophone() async {
        _ = await AudioTaps.requestSpeechAuthorization()
        _ = await AVAudioApplication.requestRecordPermission()
        micReady = true
    }

    private func allowCalendar() async {
        _ = try? await EKEventStore().requestFullAccessToEvents()
    }

    private func finish() {
        tokenFocused = false
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { KeychainStore.set(trimmed, for: .jarvisCloud) }
        settings.privacyLock = lock && PrivacyGate.canUnlock()
        settings.briefingEnabled = briefing
        settings.briefingHour = hour
        settings.briefingMinute = minute
        settings.glanceEnabled = true
        settings.onboarded = true
        DeviceLocation.shared.prepare()
        BriefingClock.schedule()
        JarvisHaptics.success()
        onFinish()
    }
}

struct PrivacyCover: View {
    var unlock: () -> Void

    var body: some View {
        ZStack {
            Color(hex: "#05080F").ignoresSafeArea()
            VStack(spacing: 18) {
                JarvisWordmark()
                Text("Locked")
                    .font(.system(size: 15))
                    .foregroundStyle(Color(hex: "#8E8A99"))
                Button(action: unlock) {
                    Text("Unlock")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 28)
                        .frame(height: 44)
                        .background(Color(hex: "#2E8BFF"), in: Capsule())
                }
                .buttonStyle(.plain)
            }
        }
    }
}

struct BootOverlay: View {
    var onFinished: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var shown = false

    var body: some View {
        ZStack {
            Color(hex: "#05080F").ignoresSafeArea()
            VStack(spacing: 14) {
                JarvisWordmark()
                    .opacity(shown ? 1 : 0.2)
                Capsule()
                    .fill(Color(hex: "#2E8BFF"))
                    .frame(width: shown ? 120 : 8, height: 1.5)
                    .opacity(0.85)
                Text(shown ? "SYSTEMS ONLINE" : "INITIALISING")
                    .font(.system(size: 11, weight: .medium))
                    .tracking(2.4)
                    .foregroundStyle(Color(hex: "#4A7FD0"))
            }
        }
        .onAppear(perform: start)
        .accessibilityLabel("JARVIS starting")
    }

    private func start() {
        if !reduceMotion { BootChime.play() }
        JarvisHaptics.tap()
        if reduceMotion {
            onFinished()
            return
        }
        withAnimation(.easeOut(duration: 0.45)) { shown = true }
        Task {
            try? await Task.sleep(for: .milliseconds(880))
            onFinished()
        }
    }
}
