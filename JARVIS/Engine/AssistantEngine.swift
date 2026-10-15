import AVFoundation
import Foundation
import Observation
import WidgetKit

/// The conversation loop: listen -> transcribe -> LLM -> speak -> (listen again when continuous).
@MainActor
@Observable
final class AssistantEngine {
    static let shared = AssistantEngine()

    private(set) var phase: JarvisPhase = .idle
    private(set) var level: Double = 0
    private(set) var transcript = ""
    private(set) var reply = ""
    private(set) var isSessionActive = false
    private(set) var isContinuous = false
    var errorMessage: String?
    private(set) var citations: [Citation] = []
    private(set) var statusLine: String?
    private(set) var pendingSummary: String?
    var messageDraft: MessageDraft?

    @ObservationIgnored private var conversation: [ChatMessage] = []
    @ObservationIgnored private let listener = SpeechListener()
    @ObservationIgnored private let output = SpeechOutput()
    @ObservationIgnored private let tools = ToolExecutor()
    @ObservationIgnored private var pendingAction: PendingAction?
    @ObservationIgnored private var silenceTask: Task<Void, Never>?
    @ObservationIgnored private var turnTask: Task<Void, Never>?
    @ObservationIgnored private var pushToTalkHeld = false
    @ObservationIgnored private var manualTurn = false
    @ObservationIgnored private var audioConfigured = false

    /// Seconds of silence that end an utterance in hands-free mode.
    private let silenceTimeout: Duration = .milliseconds(1400)

    private init() {
        listener.onLevel = { [weak self] value in self?.ingestLevel(value) }
        listener.onTranscript = { [weak self] text, isFinal in self?.handleTranscript(text, isFinal: isFinal) }
        listener.onError = { [weak self] error in self?.handleListenerError(error) }
        output.onLevel = { [weak self] value in self?.ingestLevel(value) }
        tools.onComposeMessage = { [weak self] draft in self?.messageDraft = draft }
    }

    // MARK: Session (Action Button / Live Activity)

    func toggleSession() async {
        if isSessionActive { await endSession() } else { await startSession(continuous: true) }
    }

    func startSession(continuous: Bool) async {
        guard await prepareAudio() else { return }
        isSessionActive = true
        isContinuous = continuous
        LiveActivityManager.shared.start(state: activityState)
        interrupt()
        beginListening(manual: false)
    }

    func endSession() async {
        interrupt()
        listener.stop()
        isSessionActive = false
        isContinuous = false
        phase = .idle
        level = 0
        await LiveActivityManager.shared.end(finalState: activityState)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        audioConfigured = false
    }

    // MARK: Push-to-talk / tap-to-talk

    func pushToTalkBegan() {
        pushToTalkHeld = true
        Task {
            guard await prepareAudio(), pushToTalkHeld else { return }
            interrupt()
            beginListening(manual: true)
        }
    }

    func pushToTalkEnded() {
        pushToTalkHeld = false
        if phase == .listening && manualTurn { finishUtterance() }
    }

    /// Single tap (used by StandBy view): listen -> stop; speaking -> interrupt and listen.
    func tapToTalk() {
        switch phase {
        case .listening:
            finishUtterance()
        case .idle, .speaking, .thinking:
            Task {
                guard await prepareAudio() else { return }
                interrupt()
                beginListening(manual: false)
            }
        }
    }

    func testVoice() async {
        guard await prepareAudio() else { return }
        interrupt()
        phase = .speaking
        await speak("Good evening, sir. This is how I shall sound.")
        phase = .idle
        level = 0
    }

    // MARK: Internals

    private func prepareAudio() async -> Bool {
        let speech = await AudioTaps.requestSpeechAuthorization()
        let mic = await AVAudioApplication.requestRecordPermission()
        guard speech == .authorized, mic else {
            errorMessage = "JARVIS needs Microphone and Speech Recognition access. Turn them on in iPhone Settings > JARVIS."
            return false
        }
        if !audioConfigured {
            do {
                let session = AVAudioSession.sharedInstance()
                try session.setCategory(.playAndRecord, mode: .default,
                                        options: [.defaultToSpeaker, .allowBluetoothA2DP, .duckOthers])
                try session.setActive(true)
                audioConfigured = true
            } catch {
                errorMessage = "Audio session error: \(error.localizedDescription)"
                return false
            }
        }
        errorMessage = nil
        return true
    }

    private func interrupt() {
        silenceTask?.cancel()
        turnTask?.cancel()
        turnTask = nil
        output.stop()
    }

    private func beginListening(manual: Bool) {
        manualTurn = manual
        transcript = ""
        do {
            try listener.start()
            phase = .listening
        } catch {
            errorMessage = error.localizedDescription
            phase = .idle
        }
        pushActivity()
    }

    private func handleTranscript(_ text: String, isFinal: Bool) {
        guard phase == .listening else { return }
        transcript = text
        guard !manualTurn else { return }
        if isFinal { finishUtterance(); return }
        silenceTask?.cancel()
        silenceTask = Task { [weak self, silenceTimeout] in
            try? await Task.sleep(for: silenceTimeout)
            guard !Task.isCancelled else { return }
            self?.finishUtterance()
        }
        pushActivity()
    }

    private func handleListenerError(_ error: any Error) {
        guard phase == .listening else { return }
        // Recognition sessions can end (e.g. "no speech detected"); restart in continuous mode.
        if !transcript.isEmpty { finishUtterance(); return }
        if isSessionActive && isContinuous {
            beginListening(manual: false)
        } else {
            listener.stop()
            phase = .idle
            level = 0
            pushActivity()
        }
    }

    private func finishUtterance() {
        silenceTask?.cancel()
        let text = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        phase = .thinking
        listener.stop()
        level = 0
        guard !text.isEmpty else { afterTurn(); return }
        turnTask = Task { await respond(to: text) }
    }

    private func afterTurn() {
        level = 0
        if isSessionActive && isContinuous {
            beginListening(manual: false)
        } else {
            phase = .idle
            pushActivity()
        }
    }

    private func respond(to text: String) async {
        phase = .thinking
        statusLine = nil
        pushActivity()

        // A pending action waits for "yes"/"no".
        if pendingAction != nil {
            switch ConfirmationWords.classify(text) {
            case .yes: await runPendingAction(); return
            case .no: cancelPendingAction(); await say("Very well, cancelled."); afterTurn(); return
            case .other: cancelPendingAction()
            }
        }

        let settings = AppSettings.shared
        let userMessage = ChatMessage(role: "user", content: text)
        tools.resetTurn()
        citations = []

        do {
            let endpoint = try settings.resolvedEndpoint()
            let system = settings.systemPrompt(facts: JarvisStore.allFacts())
            let history = Array(conversation.suffix(16))
            let raw: String
            switch settings.routing {
            case .chatOnly:
                raw = try await LLMClient.complete(messages: [ChatMessage(role: "system", content: system)] + history + [userMessage],
                                                   endpoint: endpoint)
            case .auto:
                raw = try await runAgent(system: system, history: history, user: userMessage, endpoint: endpoint,
                                         includeWebSearch: KeychainStore.get(.openAI) != nil)
            case .split:
                if try await classify(text, endpoint: endpoint) == .question {
                    raw = try await answerQuestion(system: system, history: history, user: userMessage, endpoint: endpoint)
                } else {
                    raw = try await runAgent(system: system, history: history, user: userMessage, endpoint: endpoint,
                                             includeWebSearch: false)
                }
            }
            guard !Task.isCancelled else { return }
            if citations.isEmpty { citations = tools.lastCitations }
            let parsed = MemoryParser.extract(from: raw)
            if settings.autoRemember { JarvisStore.add(parsed.facts) }
            let shown = parsed.cleaned.isEmpty ? "Noted, sir." : parsed.cleaned
            conversation.append(userMessage)
            conversation.append(ChatMessage(role: "assistant", content: shown))
            reply = shown
            saveForWidget(transcript: text, reply: shown)
            await say(ResponsesClient.spokenText(shown))
        } catch {
            if Task.isCancelled { return }
            errorMessage = error.localizedDescription
            reply = "⚠︎ \(error.localizedDescription)"
            if let llmError = error as? LLMError, case .missingKey = llmError {
                isContinuous = false
            }
        }
        guard !Task.isCancelled else { return }
        afterTurn()
    }

    private enum RequestKind { case question, action }

    /// Cheap routing call: is this a knowledge question or something to do on the phone?
    private func classify(_ text: String, endpoint: LLMEndpoint) async throws -> RequestKind {
        if pendingAction != nil { return .action }
        let prompt = """
        Classify the user's request. Reply with exactly one word.
        ACTION: wants something done on the phone or in an app (call, FaceTime, message, WhatsApp, calendar, reminders, \
        timer, alarm, music, maps/directions, open an app, run a shortcut, contacts lookup, send a task to an agent or Grok Bot).
        QUESTION: anything else (knowledge, news, facts, advice, chit-chat).
        """
        let reply = try await ToolChatClient.send(
            messages: [["role": "system", "content": .string(prompt)], ["role": "user", "content": .string(text)]],
            tools: [], endpoint: endpoint, temperature: 0)
        return (reply.content ?? "").uppercased().contains("ACTION") ? .action : .question
    }

    /// Knowledge path: OpenAI Responses API + web_search (citations), or plain chat for custom endpoints.
    private func answerQuestion(system: String, history: [ChatMessage], user: ChatMessage,
                                endpoint: LLMEndpoint) async throws -> String {
        let settings = AppSettings.shared
        if settings.provider == .openAI, let key = KeychainStore.get(.openAI) {
            statusLine = "Searching the web…"
            let answer = try await ResponsesClient.answer(
                input: history + [user],
                instructions: system + "\n\nSearch the web when the answer may have changed recently. "
                    + "Your reply is spoken: 1–3 sentences, no URLs, no markdown.",
                model: settings.searchModel, apiKey: key)
            citations = answer.citations
            return answer.text
        }
        return try await LLMClient.complete(messages: [ChatMessage(role: "system", content: system)] + history + [user],
                                            endpoint: endpoint)
    }

    /// Function-calling loop: the model picks tools, the app runs them and returns results.
    private func runAgent(system: String, history: [ChatMessage], user: ChatMessage,
                          endpoint: LLMEndpoint, includeWebSearch: Bool) async throws -> String {
        let settings = AppSettings.shared
        let definitions = ToolCatalog.definitions(settings: settings, includeWebSearch: includeWebSearch)
        var messages: [JSONValue] = ([ChatMessage(role: "system", content: system)] + history + [user]).map { (m: ChatMessage) -> JSONValue in
            ["role": .string(m.role), "content": .string(m.content)]
        }
        for _ in 0..<6 {
            try Task.checkCancellation()
            let response = try await ToolChatClient.send(messages: messages, tools: definitions, endpoint: endpoint)
            guard !response.toolCalls.isEmpty else { return response.content ?? "" }
            messages.append(response.assistantMessage)
            for call in response.toolCalls {
                statusLine = "Using \(call.name.replacingOccurrences(of: "_", with: " "))…"
                pushActivity()
                switch await tools.execute(call, settings: settings) {
                case .result(let result):
                    messages.append(["role": "tool", "tool_call_id": .string(call.id), "content": .string(result)])
                case .confirm(let action):
                    pendingAction = action
                    pendingSummary = action.summary
                    statusLine = nil
                    return action.summary + " Say yes to go ahead, or no to cancel."
                }
            }
        }
        statusLine = nil
        return "I'm afraid that took more steps than I'm allowed, sir."
    }

    // MARK: Confirmation

    func confirmPendingAction() {
        guard pendingAction != nil else { return }
        interrupt()
        listener.stop()
        turnTask = Task {
            await runPendingAction()
        }
    }

    func cancelPendingAction() {
        pendingAction = nil
        pendingSummary = nil
    }

    private func runPendingAction() async {
        guard let action = pendingAction else { return }
        cancelPendingAction()
        phase = .thinking
        pushActivity()
        let result = await action.perform()
        reply = result
        conversation.append(ChatMessage(role: "assistant", content: result))
        await say(result)
        guard !Task.isCancelled else { return }
        afterTurn()
    }

    func shortcutReturned(_ status: String) {
        statusLine = status == "shortcut-done" ? "Shortcut finished." : "Shortcut didn't complete."
    }

    private func say(_ text: String) async {
        guard !Task.isCancelled else { return }
        phase = .speaking
        pushActivity()
        await speak(text)
    }

    private func speak(_ text: String) async {
        let s = AppSettings.shared
        if let key = KeychainStore.get(.elevenLabs) {
            do {
                try await output.speakElevenLabs(text: text, voiceID: s.voiceID, apiKey: key,
                                                 stability: s.stability, similarity: s.similarity)
                return
            } catch {
                if Task.isCancelled { return }
                errorMessage = "ElevenLabs failed (\(error.localizedDescription)); using the system voice."
            }
        }
        await output.speakSystem(text)
    }

    private func ingestLevel(_ value: Double) {
        guard phase == .listening || phase == .speaking else { return }
        level = level * 0.6 + value * 0.4
    }

    private var activityState: JarvisActivityAttributes.ContentState {
        .init(phase: phase, transcript: String(transcript.suffix(90)), reply: String(reply.prefix(140)))
    }

    private func pushActivity() {
        guard isSessionActive else { return }
        let state = activityState
        Task { await LiveActivityManager.shared.update(state) }
    }

    private func saveForWidget(transcript: String, reply: String) {
        let d = SharedConfig.defaults
        d.set(transcript, forKey: SharedConfig.Key.lastTranscript)
        d.set(reply, forKey: SharedConfig.Key.lastReply)
        WidgetCenter.shared.reloadTimelines(ofKind: SharedConfig.standByWidgetKind)
    }
}

enum ConfirmationWords {
    enum Kind { case yes, no, other }

    static func classify(_ text: String) -> Kind {
        let t = " " + text.lowercased().filter { $0.isLetter || $0 == " " || $0 == "'" } + " "
        let no = [" no ", " nope ", " cancel ", " don't ", " do not ", " stop ", " never mind "]
        let yes = [" yes ", " yeah ", " yep ", " yup ", " sure ", " go ahead ", " do it ", " confirm ", " please do ",
                   " send it ", " call them ", " ok ", " okay ", " affirmative "]
        if no.contains(where: { t.contains($0) }) { return .no }
        if yes.contains(where: { t.contains($0) }) { return .yes }
        return .other
    }
}
