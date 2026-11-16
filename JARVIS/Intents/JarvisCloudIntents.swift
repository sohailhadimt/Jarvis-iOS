import AppIntents
import Foundation

/// "Ask JARVIS a question": Siri asks what, JARVIS answers aloud with the same brain as texts and calls.
struct AskJarvisQuestionIntent: AppIntent {
    static var title: LocalizedStringResource { "Ask JARVIS a Question" }
    static var description: IntentDescription {
        IntentDescription("Ask JARVIS anything and hear the answer, without opening the app.")
    }
    static var openAppWhenRun: Bool { false }

    @Parameter(title: "Question", requestValueDialog: IntentDialog("What would you like to ask, Sir?"))
    var question: String

    init() {}

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog & ReturnsValue<String> {
        guard let client = try? JarvisCloudAPI.client() else {
            return .result(value: "", dialog: "Add the JARVIS Cloud app token in the app first, Sir.")
        }
        let reply = await client.brainSay(question)?.reply ?? "I couldn't reach my notes just now, Sir. Try again in a moment."
        return .result(value: reply, dialog: IntentDialog(stringLiteral: reply))
    }
}

/// "Text JARVIS": anything you would text the JARVIS line (ring X and ask…, remind me…, weather…). Replies come by SMS.
struct TextJarvisIntent: AppIntent {
    static var title: LocalizedStringResource { "Text JARVIS" }
    static var description: IntentDescription {
        IntentDescription("Send JARVIS a command as if you had texted it. The reply arrives by text, and calls still wait for your YES.")
    }
    static var openAppWhenRun: Bool { false }

    @Parameter(title: "Message", requestValueDialog: IntentDialog("What shall I do, Sir?"))
    var message: String

    init() {}

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let client = try? JarvisCloudAPI.client() else {
            return .result(dialog: "Add the JARVIS Cloud app token in the app first, Sir.")
        }
        let ok = (try? await client.smsCommand(message)) ?? false
        return .result(dialog: ok ? "On it, Sir. I'll text you." : "I couldn't reach JARVIS just now, Sir.")
    }
}

/// "JARVIS call back": offers to ring back the last caller. Nothing is dialled until you reply YES.
struct JarvisCallBackIntent: AppIntent {
    static var title: LocalizedStringResource { "JARVIS Call Back" }
    static var description: IntentDescription {
        IntentDescription("Ask JARVIS to call back the last person who rang. It texts you to confirm first.")
    }
    static var openAppWhenRun: Bool { false }

    init() {}

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let client = try? JarvisCloudAPI.client() else {
            return .result(dialog: "Add the JARVIS Cloud app token in the app first, Sir.")
        }
        let ok = (try? await client.smsCommand("call them back please")) ?? false
        return .result(dialog: ok ? "Very good, Sir. I've texted you to confirm the call back." : "I couldn't reach JARVIS just now, Sir.")
    }
}
