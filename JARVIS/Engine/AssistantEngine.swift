import ActivityKit
import AVFoundation
import Foundation
import Observation
import UIKit
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
    @ObservationIgnored private var captureFile = false
    @ObservationIgnored private var heardVoice = false
    @ObservationIgnored private var loudFrames = 0
    /// After a Groq transcription auth failure, later listens in this session use on-device speech.
    @ObservationIgnored private var groqTranscriptionBroken = false
    /// WAV capture failed, so this session stays on live on-device speech.
    @ObservationIgnored private var fileCaptureBroken = false

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
        // A background AudioRecordingIntent is suspended unless a Live Activity is up.
        // In the foreground the on-screen session still runs when Live Activities are off.
        if UIApplication.shared.applicationState != .active,
           !ActivityAuthorizationInfo().areActivitiesEnabled {
            errorMessage = "Turn on Live Activities for JARVIS so the Action Button can listen in the Dynamic Island."
            publishControlState()
            return
        }
        guard await prepareAudio() else {
            publishControlState()
            return
        }
        groqTranscriptionBroken = false
        fileCaptureBroken = false
        isSessionActive = true
        isContinuous = continuous
        phase = .listening
        // Request the island before the microphone tap. iOS only keeps the background
        // recording alive while that Live Activity exists.
        LiveActivityManager.shared.start(state: activityState)
        if UIApplication.shared.applicationState != .active,
           !LiveActivityManager.shared.isRunning {
            await endSession()
            errorMessage = "JARVIS couldn't show the Dynamic Island, so the background session was stopped."
            return
        }
        publishControlState()
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
        publishControlState()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        audioConfigured = false
    }

    /// Writes the App Group flag the control reads, then asks Control Center to redraw it.
    func syncControlState() {
        publishControlState()
    }

    // MARK: Push-to-talk / tap-to-talk

    func pushToTalkBegan() {
        pushToTalkHeld = true
        fileCaptureBroken = false
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

    /// Typed request from the Tasks screen. Same turn pipeline as a finished utterance.
    func ask(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        Task {
            let session = AVAudioSession.sharedInstance()
            do {
                try session.setCategory(.playAndRecord, mode: .default,
                                        options: [.defaultToSpeaker, .allowBluetoothA2DP, .duckOthers])
                try session.setActive(true)
                audioConfigured = true
            } catch {
                // A text turn can still run; speech falls back if the session won't start.
            }
            interrupt()
            listener.stop()
            manualTurn = false
            transcript = trimmed
            phase = .thinking
            level = 0
            errorMessage = nil
            pushActivity()
            turnTask = Task { await respond(to: trimmed) }
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
        heardVoice = false
        loudFrames = 0
        captureFile = false
        do {
            if shouldCaptureForGroq() {
                do {
                    try listener.startFileCapture()
                    captureFile = true
                } catch {
                    fileCaptureBroken = true
                    try listener.start()
                }
            } else {
                try listener.start()
            }
            phase = .listening
        } catch {
            errorMessage = error.localizedDescription
            phase = .idle
        }
        pushActivity()
    }

    private func shouldCaptureForGroq() -> Bool {
        !fileCaptureBroken && !groqTranscriptionBroken && KeychainStore.get(.groq) != nil
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
        guard phase == .listening else { return }
        silenceTask?.cancel()
        phase = .thinking
        level = 0
        pushActivity()
        if captureFile {
            captureFile = false
            let url = listener.stopFileCapture()
            if url == nil, let failure = listener.lastCaptureFailure {
                fileCaptureBroken = true
                errorMessage = failure
            }
            guard let url else { afterTurn(); return }
            turnTask = Task { await transcribeAndRespond(file: url) }
            return
        }
        let text = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        listener.stop()
        guard !text.isEmpty else { afterTurn(); return }
        turnTask = Task { await respond(to: text) }
    }

    private func transcribeAndRespond(file url: URL) async {
        defer { try? FileManager.default.removeItem(at: url) }
        let text: String
        do {
            text = try await transcribeCapturedFile(url)
        } catch {
            if Task.isCancelled { return }
            errorMessage = error.localizedDescription
            reply = "⚠︎ \(error.localizedDescription)"
            afterTurn()
            return
        }
        guard !Task.isCancelled else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        transcript = trimmed
        guard !trimmed.isEmpty else { afterTurn(); return }
        await respond(to: trimmed)
    }

    /// Groq Whisper when a Groq key exists. Otherwise, and if Groq fails, on-device Apple Speech.
    private func transcribeCapturedFile(_ url: URL) async throws -> String {
        if let key = KeychainStore.get(.groq), !groqTranscriptionBroken {
            do {
                statusLine = "Transcribing with Groq…"
                pushActivity()
                return try await GroqTranscription.transcribe(fileURL: url, apiKey: key)
            } catch {
                if Task.isCancelled { throw error }
                if Self.isGroqAuthFailure(error) {
                    groqTranscriptionBroken = true
                    errorMessage = error.localizedDescription
                }
                statusLine = "Using on-device speech…"
                pushActivity()
                do {
                    return try await AppleFileTranscriber.transcribe(url)
                } catch let apple {
                    if Task.isCancelled { throw apple }
                    throw SpeechTranscriptionError(groq: error.localizedDescription, apple: apple.localizedDescription)
                }
            }
        }
        statusLine = "Using on-device speech…"
        pushActivity()
        return try await AppleFileTranscriber.transcribe(url)
    }

    private static func isGroqAuthFailure(_ error: any Error) -> Bool {
        guard let llm = error as? LLMError, case .http(let code, _, provider: _) = llm else { return false }
        return code == 401 || code == 403
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
            if endpoint.kind != settings.provider {
                statusLine = "Using \(endpoint.providerName) because no \(settings.provider.title) key is saved."
            }
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

    /// Knowledge path: OpenAI Responses API with web search, or plain chat for Gemini, Groq and custom endpoints.
    private func answerQuestion(system: String, history: [ChatMessage], user: ChatMessage,
                                endpoint: LLMEndpoint) async throws -> String {
        let settings = AppSettings.shared
        if endpoint.kind == .openAI, let key = endpoint.apiKey {
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
        // RMS from the mic tap (listening) or the player mixer tap (speaking), smoothed.
        level = level * 0.45 + value * 0.55
        noteCaptureLevel()
    }

    /// Groq Whisper is request/response, so silence is detected from the mic level instead of partial transcripts.
    private func noteCaptureLevel() {
        guard captureFile, phase == .listening, !manualTurn else { return }
        if level > 0.2 {
            loudFrames += 1
            if loudFrames >= 3 {
                heardVoice = true
                silenceTask?.cancel()
                silenceTask = Task { [weak self, silenceTimeout] in
                    try? await Task.sleep(for: silenceTimeout)
                    guard !Task.isCancelled else { return }
                    self?.finishUtterance()
                }
            }
        } else if !heardVoice {
            loudFrames = 0
        }
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

    private func publishControlState() {
        SharedConfig.defaults.set(isSessionActive, forKey: SharedConfig.Key.sessionActive)
        ControlCenter.shared.reloadControls(ofKind: SharedConfig.controlKind)
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
