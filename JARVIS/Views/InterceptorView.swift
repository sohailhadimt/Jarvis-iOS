import SwiftUI
import UIKit

/// On/off switch for calls forwarded from the owner's mobile, plus Busy mode for a Focus filter.
struct InterceptorView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(AssistantEngine.self) private var engine
    @State private var enabled = true
    @State private var busy = false
    @State private var ready = false
    @State private var note = "Checking the interceptor."
    @State private var codes = CallingForwarding(unconditional: "", noAnswer: "", busy: "", unreachable: "", cancel: "##002#")

    var body: some View {
        Form {
            Section {
                Toggle("Interceptor", isOn: enabledBinding)
                    .disabled(!ready)
            } header: {
                Text("Forwarded calls")
            } footer: {
                Text("When this is on, JARVIS answers a call your carrier forwards and takes a message. When this is off and Busy mode is off, he says “Please try again later.” and texts you who called.")
            }

            Section {
                Toggle("Busy mode", isOn: busyBinding)
                    .disabled(!ready)
            } header: {
                Text("Busy mode")
            } footer: {
                Text("Busy mode answers a forwarded call on its own, including when the interceptor switch is off, so a Focus can turn answering on. In Settings, open Focus, choose a Focus, add a filter, and pick JARVIS Busy mode. The Shortcuts action Set JARVIS busy mode does the same. After that Focus ends, busy mode turns off the next time you open JARVIS. The ring shows BUSY while it is on and you are idle.")
            }

            Section {
                Text(setupLead)
                    .font(.footnote)
                    .foregroundStyle(.white.opacity(0.8))
                if codes.busy.isEmpty {
                    Text("The JARVIS number appears here once calling is connected.")
                        .font(.footnote)
                        .foregroundStyle(.white.opacity(0.75))
                    codeRow("Busy", "**67*<JARVIS number>#")
                    codeRow("No answer", "**61*<JARVIS number>#")
                    codeRow("Unreachable", "**62*<JARVIS number>#")
                } else {
                    codeRow("Busy", codes.busy)
                    codeRow("No answer", codes.noAnswer)
                    codeRow("Unreachable", codes.unreachable)
                }
                codeRow("Cancel all forwarding", codes.cancel.isEmpty ? "##002#" : codes.cancel)
            } header: {
                Text("Carrier setup")
            } footer: {
                Text("These are the generic GSM codes: **67* for busy, **61* for no answer, and **62* for unreachable, then the JARVIS number and #. Dial each one from the Phone app. Some UK networks use a different code.")
            }

            if !note.isEmpty {
                Section {
                    Text(note)
                        .font(.footnote)
                        .foregroundStyle(.white.opacity(0.8))
                }
            }
        }
        .navigationTitle("Interceptor")
        .scrollContentBackground(.hidden)
        .background(Color.black)
        .toolbar(.visible, for: .navigationBar)
        .tint(settings.primaryColor)
        .task { await reload() }
    }

    private var setupLead: String {
        "iOS cannot intercept a normal carrier call. Forward busy, unanswered, and unreachable calls from your mobile to the JARVIS number. JARVIS then greets the caller and takes a message."
    }

    private var enabledBinding: Binding<Bool> {
        Binding(
            get: { enabled },
            set: { value in
                enabled = value
                Task { await save(enabled: value, busy: nil) }
            }
        )
    }

    private var busyBinding: Binding<Bool> {
        Binding(
            get: { busy },
            set: { value in
                busy = value
                Task {
                    let saved = await InterceptorSync.setBusy(value, fromFocus: false)
                    note = saved ? "" : "That change did not save. Try the switch again."
                }
            }
        )
    }

    private func reload() async {
        await InterceptorSync.reconcile()
        do {
            let client = try JarvisCloudAPI.client()
            let state = try await client.interceptorState()
            enabled = state.enabled
            busy = state.busy
            engine.setBusyMode(state.busy)
            if let config = try? await client.callingConfig(), let forwarding = config.forwarding {
                codes = forwarding
            }
            note = ""
            ready = true
        } catch {
            ready = false
            note = "Connect JARVIS Cloud in Settings to change this from the phone. Forwarded calls stay answered until the switch is saved."
        }
    }

    private func save(enabled enabledValue: Bool?, busy busyValue: Bool?) async {
        do {
            let client = try JarvisCloudAPI.client()
            let state = try await client.setInterceptor(enabled: enabledValue, busy: busyValue)
            enabled = state.enabled
            busy = state.busy
            engine.setBusyMode(state.busy)
            note = ""
        } catch {
            note = "That change did not save. Try the switch again."
        }
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
                    .disabled(code.contains("<"))
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
}
