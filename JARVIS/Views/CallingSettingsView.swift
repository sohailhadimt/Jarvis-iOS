import SwiftUI
import UIKit

struct CallingSettingsView: View {
    @Environment(AppSettings.self) private var settings
    @AppStorage("jarvis.call.forwarding") private var forwardingMode = "missed"
    @State private var report = "Calling not set up."
    @State private var fromNumber = ""
    @State private var codes = CallingForwarding(unconditional: "", noAnswer: "", busy: "", unreachable: "", cancel: ForwardingGuide.cancel)
    @State private var mobileSet = false
    @State private var pushReady = false
    @State private var busy = false
    @State private var rules: [CallPrivacyRule] = []
    @State private var draftName = ""
    @State private var draftPhone = ""
    @State private var draftNote = ""
    @State private var mobile = ""
    @State private var quietStart = "22:00"
    @State private var quietEnd = "08:00"
    @State private var dailyCap = 3
    @State private var urgentOnly = false
    @State private var questionWait = 40

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
                Text("The Twilio token stays on the worker. A plain call still opens the Phone app. A call with a message waits until you say yes or tap Approve.")
            }

            Section {
                Picker("Forwarding", selection: $forwardingMode) {
                    Text("All calls").tag("all")
                    Text("When I don't answer").tag("missed")
                }
                Text(modeBlurb)
                    .font(.footnote)
                    .foregroundStyle(.white.opacity(0.75))
                if forwardingMode == "all" {
                    codeRow("All calls", codes.unconditional)
                } else {
                    codeRow("No answer", codes.noAnswer)
                    codeRow("Busy", codes.busy)
                    codeRow("Unreachable", codes.unreachable)
                }
                codeRow("Cancel all forwarding", codes.cancel)
            } header: {
                Text("Carrier forwarding")
            } footer: {
                Text("iOS cannot intercept a normal carrier call. Forward your mobile to the Twilio UK number, then JARVIS can answer. Dial the code from the Phone app, or copy it. Cancel with ##002#.")
            }

            Section {
                TextField("Your mobile", text: $mobile)
                    .keyboardType(.phonePad)
                TextField("Quiet from", text: $quietStart)
                TextField("Quiet until", text: $quietEnd)
                Stepper("At most \(dailyCap) problem calls a day", value: $dailyCap, in: 0...5)
                Toggle("Urgent problems only", isOn: $urgentOnly)
                Stepper("Wait \(questionWait)s for your answer", value: $questionWait, in: 30...45)
                Button("Save these limits") { saveLimits() }
            } header: {
                Text("Calls to you")
            } footer: {
                Text("JARVIS can ring this number about a failed task, a blocked call, or a low Twilio balance. Quiet hours and the daily cap keep that inside the balance. Outside those limits he sends a notification instead. The number is saved from here, not built into the app.")
            }

            Section {
                Text(screeningBlurb)
                    .font(.footnote)
                    .foregroundStyle(.white.opacity(0.8))
            } header: {
                Text("When someone calls")
            }

            Section {
                Text("Personal details stay private unless you allow them for a person, or approve them on that call. Schedule, location, and private facts are denied by default.")
                    .font(.footnote)
                    .foregroundStyle(.white.opacity(0.8))
                ForEach(rules) { rule in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(rule.name)
                            Spacer()
                            Text(rule.allowPersonal ? "May share" : "Private")
                                .font(.caption)
                                .foregroundStyle(settings.accentColor)
                        }
                        if !rule.note.isEmpty {
                            Text(rule.note)
                                .font(.caption)
                                .foregroundStyle(.white.opacity(0.7))
                        }
                    }
                    .swipeActions {
                        Button("Delete", role: .destructive) { remove(rule) }
                    }
                }
                TextField("Name", text: $draftName)
                TextField("Phone, optional", text: $draftPhone)
                    .keyboardType(.phonePad)
                TextField("What JARVIS may say", text: $draftNote)
                Button("Allow for this person") { addRule() }
                    .disabled(draftName.trimmingCharacters(in: .whitespaces).isEmpty)
            } header: {
                Text("Personal details")
            }
        }
        .navigationTitle("Calling")
        .scrollContentBackground(.hidden)
        .background(Color.black)
        .toolbar(.visible, for: .navigationBar)
        .tint(settings.primaryColor)
        .onAppear {
            rules = CallPrivacyStore.rules()
            refresh()
        }
    }

    private var modeBlurb: String {
        if forwardingMode == "all" {
            return "Every call to your mobile is sent to JARVIS first."
        }
        return "JARVIS screens a call when you do not answer, you are busy, or your phone is off."
    }

    private var screeningBlurb: String {
        var lines = [
            "JARVIS says he is your assistant and that the call may be handled by AI, then asks who is calling.",
            "You can put them through, let JARVIS handle it, take a message, or decline.",
            "Listen-in shows the live transcript here. Take over rings your real mobile and JARVIS leaves the call.",
        ]
        if !mobileSet { lines.append("Your real mobile is not set on the worker yet, so put-through cannot ring you.") }
        if !pushReady { lines.append("Push is not set up on the worker. A text to your mobile is the fallback once that number is set.") }
        return lines.joined(separator: " ")
    }

    private func codeRow(_ title: String, _ code: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.white.opacity(0.6))
            Text(code)
                .font(.body.monospaced())
                .foregroundStyle(.white)
                .textSelection(.enabled)
            HStack {
                Button("Copy") { UIPasteboard.general.string = code }
                Button("Dial") { dial(code) }
            }
            .font(.caption)
        }
        .padding(.vertical, 4)
    }

    private func dial(_ code: String) {
        UIPasteboard.general.string = code
        let encoded = code.replacingOccurrences(of: "#", with: "%23").replacingOccurrences(of: "+", with: "%2B")
        guard let url = URL(string: "tel:\(encoded)") else { return }
        UIApplication.shared.open(url)
    }

    private func addRule() {
        let name = draftName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        let rule = CallPrivacyRule(
            id: UUID().uuidString,
            name: name,
            phone: draftPhone.trimmingCharacters(in: .whitespacesAndNewlines),
            allowPersonal: true,
            note: draftNote.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        rules.append(rule)
        draftName = ""
        draftPhone = ""
        draftNote = ""
        CallPrivacyStore.replace(rules)
        Task { await CallPrivacyStore.syncIfNeeded() }
    }

    private func remove(_ rule: CallPrivacyRule) {
        rules.removeAll { $0.id == rule.id }
        CallPrivacyStore.replace(rules)
        Task { await CallPrivacyStore.syncIfNeeded() }
    }

    private func saveLimits() {
        let settings = OwnerCallSettings(
            mobile: mobile.trimmingCharacters(in: .whitespacesAndNewlines),
            quietStart: quietStart,
            quietEnd: quietEnd,
            maxCallsPerDay: dailyCap,
            urgentOnly: urgentOnly,
            questionTimeoutSeconds: questionWait
        )
        Task {
            guard let client = try? JarvisCloudAPI.client() else {
                report = "Calling not set up."
                return
            }
            switch await client.saveOwnerCallSettings(settings) {
            case .failed(let message), .notSetUp(let message):
                report = message
            case .done:
                report = "Saved. Problem calls use this mobile, with quiet hours and the daily cap."
            }
        }
    }

    private func refresh() {
        busy = true
        Task {
            defer { busy = false }
            guard JarvisCloud.isConfigured else {
                report = "Calling not set up. Add the JARVIS Cloud URL and app token first. The Twilio token stays on this worker, not on this iPhone."
                applyNumber("")
                return
            }
            do {
                let config = try await JarvisCloudAPI.client().callingConfig()
                mobileSet = config.screening?.mobileSet ?? false
                pushReady = config.screening?.push ?? false
                if let saved = try? await JarvisCloudAPI.client().ownerCallSettings() {
                    mobile = saved.mobile
                    quietStart = saved.quietStart
                    quietEnd = saved.quietEnd
                    dailyCap = saved.maxCallsPerDay
                    urgentOnly = saved.urgentOnly
                    questionWait = saved.questionTimeoutSeconds
                }
                applyNumber(config.fromNumber ?? "")
                if let forwarding = config.forwarding {
                    codes = forwarding
                }
                if config.configured {
                    report = "Calling is ready. Outbound calls and inbound screening use the UK number on the worker."
                } else if config.missing.isEmpty {
                    report = "Calling not set up."
                } else {
                    report = "Calling not set up. Still missing on the worker: \(config.missing.joined(separator: ", "))."
                }
            } catch {
                report = "Calling not set up. \(error.localizedDescription)"
                applyNumber("")
            }
        }
    }

    private func applyNumber(_ number: String) {
        fromNumber = number
        let shown = number.isEmpty ? "NUMBER" : number
        codes = CallingForwarding(
            unconditional: ForwardingGuide.unconditional(shown),
            noAnswer: ForwardingGuide.noAnswer(shown),
            busy: ForwardingGuide.busy(shown),
            unreachable: ForwardingGuide.unreachable(shown),
            cancel: ForwardingGuide.cancel
        )
    }
}
