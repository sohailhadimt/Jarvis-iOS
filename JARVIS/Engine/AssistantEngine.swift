import ActivityKit
import AVFoundation
import Foundation
import Observation
import os
import UIKit
import WidgetKit

private let sessionLog = Logger(subsystem: "com.sohail.jarvis", category: "session")

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
    /// Bumped by start and end so a slow start cannot finish after the user has already toggled off.
    @ObservationIgnored private var sessionEpoch = 0
    @ObservationIgnored private var listenRetries = 0
    @ObservationIgnored private var wakeArmed = false
    @ObservationIgnored private var appInForeground = false
    @ObservationIgnored private var wakeRestarts = 0
    @ObservationIgnored private var bargeFrames = 0
    /// Smoothed mic level used only to detect the end of a Groq recording.
    @ObservationIgnored private var captureMeter = 0.0

    /// Seconds of silence that end an utterance in hands-free mode.
    private let silenceTimeout: Duration = .milliseconds(1400)

    private init() {
        listener.onLevel = { [weak self] value in self?.ingestLevel(value) }
        listener.onTranscript = { [weak self] text, isFinal in self?.handleTranscript(text, isFinal: isFinal) }
        listener.onError = { [weak self] error in self?.handleListenerError(error) }
        output.onLevel = { [weak self] value in self?.ingestLevel(value) }
        output.onBargeIn = { [weak self] in self?.bargeIn() }
        listener.onBargeLevel = { [weak self] value in self?.noteBarge(value) }
        tools.onComposeMessage = { [weak self] draft in self?.messageDraft = draft }
    }

    // MARK: Session (Action Button / Live Activity)

    enum SessionStart: Equatable {
        case started, alreadyRunning, failed, needsForeground
    }

    /// Used when a background control launch has to finish in the foreground.
    func waitUntilForeground() async {
        for _ in 0..<30 {
            if UIApplication.shared.applicationState == .active { return }
            try? await Task.sleep(for: .milliseconds(100))
        }
        sessionLog.error("timed out waiting for the app to become active")
    }

    func toggleSession() async {
        if isSessionActive { await endSession(reason: "in-app-toggle") } else { await startSession(continuous: true) }
    }

    /// Starts listening and returns before the caller (`perform`) returns.
    /// The Live Activity is requested before the audio session is activated. The engine stays
    /// on this singleton for the whole session, including the gaps between utterances.
    @discardableResult
    func startSession(continuous: Bool) async -> SessionStart {
        if isSessionActive, listener.isEngineRunning {
            sessionLog.info("startSession ignored; engine already running")
            publishControlState()
            return .alreadyRunning
        }
        wakeArmed = false
        sessionEpoch += 1
        let epoch = sessionEpoch
        let state = UIApplication.shared.applicationState
        sessionLog.info("startSession epoch=\(epoch) appState=\(state.rawValue) continuous=\(continuous)")

        // Persist ON before any reload. A control refresh that still reads off sends perform(false)
        // and tears the session down.
        isSessionActive = true
        isContinuous = continuous
        phase = .listening
        listener.holdEngine = true
        publishControlState()

        let activityOK = LiveActivityManager.shared.start(state: activityState)
        let inBackground = UIApplication.shared.applicationState != .active
        if !activityOK && inBackground {
            // Activating the mic with no Live Activity makes AudioRecordingIntent kill the process.
            sessionLog.error("Live Activity missing in background; not activating the microphone")
            errorMessage = "Turn on Live Activities for JARVIS so the Action Button can listen in the Dynamic Island."
            await endSession(reason: "live-activity-unavailable")
            return .needsForeground
        }
        guard epoch == sessionEpoch else {
            sessionLog.info("startSession superseded before audio")
            return .failed
        }

        // Permissions already granted: activate the session and start the engine with no await,
        // so both are running before perform() can return.
        if !activateAudioIfAuthorized() {
            if inBackground {
                sessionLog.error("audio session was not activated in the background")
                return .needsForeground
            }
            guard await activateAudio() else {
                sessionLog.error("activateAudio failed: \(self.errorMessage ?? "", privacy: .public)")
                guard epoch == sessionEpoch else { return .failed }
                await endSession(reason: "audio-failed")
                return .failed
            }
            guard epoch == sessionEpoch else { return .failed }
        }

        if !LiveActivityManager.shared.isRunning {
            _ = LiveActivityManager.shared.start(state: activityState)
        }
        groqTranscriptionBroken = false
        fileCaptureBroken = false
        listenRetries = 0
        interrupt()
        beginListening(manual: false)
        if !listener.isEngineRunning {
            try? listener.keepEngineAlive()
        }
        guard listener.isEngineRunning else {
            sessionLog.error("audio engine was not running when startSession returned")
            guard epoch == sessionEpoch else { return .failed }
            await endSession(reason: "engine-not-running")
            return .failed
        }
        sessionLog.info("session listening; engine held")
        return .started
    }

    func endSession(reason: String = "toggle-off") async {
        sessionEpoch += 1
        sessionLog.info("endSession \(reason, privacy: .public)")
        interrupt()
        listener.holdEngine = false
        listener.stop()
        isSessionActive = false
        isContinuous = false
        phase = .idle
        level = 0
        await LiveActivityManager.shared.end(finalState: activityState)
        publishControlState()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        audioConfigured = false
        refreshWake()
    }

    /// Foreground-only. Backgrounding stops the wake recogniser and leaves a control session alone.
    func setForeground(_ active: Bool) {
        appInForeground = active
        if active {
            refreshWake()
        } else {
            stopWake()
        }
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
            wakeArmed = false
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
        stopWake()
        guard await prepareAudio() else {
            refreshWake()
            return
        }
        interrupt()
        phase = .speaking
        await speak("Good evening, sir. This is how I shall sound.")
        phase = .idle
        level = 0
        refreshWake()
    }

    // MARK: Internals

    /// True when the microphone is already allowed and the playAndRecord session is active.
    /// This path does not suspend, so a control's `perform()` can start the engine before it returns.
    private func activateAudioIfAuthorized() -> Bool {
        guard AudioTaps.speechAuthorizationStatus() == .authorized,
              AVAudioApplication.shared.recordPermission == .granted else {
            errorMessage = "JARVIS needs Microphone and Speech Recognition access. Open JARVIS once and allow both."
            return false
        }
        return activateAudioSession()
    }

    /// Permission prompts only happen in the foreground. A control launch must not `await` before the
    /// Live Activity exists, and must not activate the session when that activity is missing.
    private func activateAudio() async -> Bool {
        var speech = AudioTaps.speechAuthorizationStatus()
        var mic = AVAudioApplication.shared.recordPermission
        if speech != .authorized || mic != .granted {
            guard UIApplication.shared.applicationState == .active else {
                errorMessage = "JARVIS needs Microphone and Speech Recognition access. Open JARVIS once and allow both."
                return false
            }
            speech = await AudioTaps.requestSpeechAuthorization()
            let micGranted = await AVAudioApplication.requestRecordPermission()
            guard speech == .authorized, micGranted else {
                errorMessage = "JARVIS needs Microphone and Speech Recognition access. Turn them on in iPhone Settings > JARVIS."
                return false
            }
        }
        return activateAudioSession()
    }

    private func prepareAudio() async -> Bool {
        guard await activateAudio() else { return false }
        return true
    }

    private func activateAudioSession() -> Bool {
        if !audioConfigured {
            do {
                let session = AVAudioSession.sharedInstance()
                try session.setCategory(.playAndRecord, mode: .default,
                                        options: [.defaultToSpeaker, .allowBluetoothA2DP, .duckOthers])
                try session.setActive(true)
                audioConfigured = true
                sessionLog.info("AVAudioSession active playAndRecord")
            } catch {
                errorMessage = "Audio session error: \(error.localizedDescription)"
                sessionLog.error("AVAudioSession failed: \(error.localizedDescription, privacy: .public)")
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
        captureMeter = 0
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
            listenRetries = 0
        } catch {
            errorMessage = error.localizedDescription
            sessionLog.error("beginListening failed: \(error.localizedDescription, privacy: .public)")
            if isSessionActive {
                try? listener.keepEngineAlive()
                if isContinuous, listenRetries < 3 {
                    listenRetries += 1
                    let attempt = listenRetries
                    sessionLog.info("retrying recognition \(attempt)")
                    Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(500))
                        // A successful start zeroes listenRetries, so this retry does not interrupt it.
                        guard self.isSessionActive, self.listenRetries == attempt else { return }
                        self.beginListening(manual: false)
                    }
                }
            }
            if !isSessionActive || !listener.isEngineRunning {
                phase = .idle
            }
        }
        pushActivity()
    }

    private func shouldCaptureForGroq() -> Bool {
        !fileCaptureBroken && !groqTranscriptionBroken && KeychainStore.get(.groq) != nil
    }

    private func handleTranscript(_ text: String, isFinal: Bool) {
        if wakeArmed, !isSessionActive {
            if Self.hearsWakeWord(text) {
                wakeArmed = false
                sessionLog.info("wake word")
                Task { await self.startSession(continuous: true) }
                return
            }
            if isFinal { beginWakeRecognition() }
            return
        }
        guard phase == .listening else { return }
        transcript = text
        guard !manualTurn else { return }
        if isFinal {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty, isSessionActive, isContinuous, !manualTurn {
                // The recogniser closes an empty utterance on its own. That must not end the session.
                sessionLog.info("empty recognition result; restarting listen")
                beginListening(manual: false)
                return
            }
            finishUtterance()
            return
        }
        silenceTask?.cancel()
        silenceTask = Task { [weak self, silenceTimeout] in
            try? await Task.sleep(for: silenceTimeout)
            guard !Task.isCancelled else { return }
            self?.finishUtterance()
        }
        pushActivity()
    }

    private func handleListenerError(_ error: any Error) {
        if wakeArmed, !isSessionActive {
            beginWakeRecognition()
            return
        }
        guard phase == .listening else { return }
        // Recognition sessions can end (e.g. "no speech detected"); restart in continuous mode.
        if !transcript.isEmpty { finishUtterance(); return }
        if isSessionActive && isContinuous {
            sessionLog.info("recognition ended; restarting listen")
            beginListening(manual: false)
        } else {
            listener.stop()
            phase = .idle
            level = 0
            pushActivity()
            refreshWake()
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
            sessionLog.info("utterance finished; session stays listening")
            beginListening(manual: false)
        } else {
            phase = .idle
            pushActivity()
            refreshWake()
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
            var alreadySpoken = false
            switch settings.routing {
            case .chatOnly:
                let streamed = try await streamedChat(system: system, history: history, user: userMessage, endpoint: endpoint)
                raw = streamed.text
                alreadySpoken = streamed.spoken
            case .auto:
                raw = try await runAgent(system: system, history: history, user: userMessage, endpoint: endpoint,
                                         includeWebSearch: KeychainStore.get(.openAI) != nil)
            case .split:
                if try await classify(text, endpoint: endpoint) == .question {
                    if endpoint.kind == .openAI {
                        raw = try await answerQuestion(system: system, history: history, user: userMessage, endpoint: endpoint)
                    } else {
                        let streamed = try await streamedChat(system: system, history: history, user: userMessage, endpoint: endpoint)
                        raw = streamed.text
                        alreadySpoken = streamed.spoken
                    }
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
            if !alreadySpoken {
                await say(ResponsesClient.spokenText(shown))
            }
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
        let monitor = !listener.isEngineRunning
        if listener.isEngineRunning {
            listener.setBargeMonitor(true)
        }
        defer { listener.setBargeMonitor(false) }
        let s = AppSettings.shared
        if let key = KeychainStore.get(.elevenLabs) {
            do {
                try await output.speakElevenLabs(text: text, voiceID: s.voiceID, apiKey: key,
                                                 stability: s.stability, similarity: s.similarity,
                                                 monitorMicrophone: monitor)
                return
            } catch {
                if Task.isCancelled { return }
                errorMessage = "ElevenLabs failed (\(error.localizedDescription)); using the system voice."
            }
        }
        await output.speakSystem(text)
    }

    private func noteBarge(_ value: Double) {
        guard phase == .speaking else {
            bargeFrames = 0
            return
        }
        let threshold = listener.voiceProcessingEnabled ? 0.32 : 0.48
        if value > threshold {
            bargeFrames += 1
            if bargeFrames >= 4 {
                bargeFrames = 0
                bargeIn()
            }
        } else if value < threshold * 0.6 {
            bargeFrames = 0
        }
    }

    /// Mic energy during playback: stop the voice immediately and listen.
    private func bargeIn() {
        guard phase == .speaking else { return }
        sessionLog.info("barge-in")
        let keepListening = isSessionActive || isContinuous
        interrupt()
        if keepListening {
            beginListening(manual: false)
        } else {
            phase = .idle
            level = 0
            pushActivity()
        }
    }

    private struct StreamedReply {
        var text: String
        var spoken: Bool
    }

    /// Speaks the first sentence while the rest of the chat completion is still streaming.
    private func streamedChat(system: String, history: [ChatMessage], user: ChatMessage,
                              endpoint: LLMEndpoint) async throws -> StreamedReply {
        let messages = [ChatMessage(role: "system", content: system)] + history + [user]
        var full = ""
        var spokenPiece = ""
        var speakTask: Task<Void, Never>?
        do {
            for try await delta in LLMClient.streamDeltas(messages: messages, endpoint: endpoint) {
                try Task.checkCancellation()
                full += delta
                let cleaned = MemoryParser.extract(from: full).cleaned
                if !cleaned.isEmpty {
                    reply = cleaned
                    pushActivity()
                }
                if speakTask == nil, let sentence = Self.firstSentence(in: cleaned) {
                    spokenPiece = sentence
                    let piece = ResponsesClient.spokenText(sentence)
                    if !piece.isEmpty {
                        speakTask = Task { await self.say(piece) }
                    }
                }
            }
        } catch {
            speakTask?.cancel()
            if Task.isCancelled { throw error }
            if full.isEmpty {
                let text = try await LLMClient.complete(messages: messages, endpoint: endpoint)
                return StreamedReply(text: text, spoken: false)
            }
        }
        if let speakTask {
            await speakTask.value
            guard !Task.isCancelled else { return StreamedReply(text: full, spoken: true) }
            let cleaned = MemoryParser.extract(from: full).cleaned
            if let range = cleaned.range(of: spokenPiece) {
                let rest = cleaned[range.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
                if !rest.isEmpty {
                    await say(ResponsesClient.spokenText(rest))
                }
            }
            return StreamedReply(text: full, spoken: true)
        }
        return StreamedReply(text: full, spoken: false)
    }

    private static func firstSentence(in text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 12 else { return nil }
        let chars = Array(trimmed)
        for index in 0..<chars.count {
            let ch = chars[index]
            guard ch == "." || ch == "!" || ch == "?" else { continue }
            guard index >= 11 else { continue }
            if ch == ".", index > 0, chars[index - 1].isNumber { continue }
            if index + 1 < chars.count, chars[index + 1].isLetter { continue }
            return String(chars[0...index])
        }
        return nil
    }

    private static func hearsWakeWord(_ text: String) -> Bool {
        text.range(of: "jarvis", options: [.caseInsensitive, .diacriticInsensitive]) != nil
    }

    private func refreshWake() {
        let want = appInForeground && AppSettings.shared.wakeWordEnabled && !isSessionActive && phase == .idle
        if want {
            startWake()
        } else if wakeArmed {
            stopWake()
        }
    }

    private func startWake() {
        guard !wakeArmed, !isSessionActive, phase == .idle else { return }
        guard AudioTaps.speechAuthorizationStatus() == .authorized,
              AVAudioApplication.shared.recordPermission == .granted else { return }
        guard activateAudioSession() else { return }
        wakeArmed = true
        wakeRestarts = 0
        listener.holdEngine = false
        beginWakeRecognition()
    }

    private func beginWakeRecognition() {
        guard wakeArmed, !isSessionActive, phase == .idle else { return }
        do {
            try listener.start()
            wakeRestarts = 0
        } catch {
            wakeRestarts += 1
            guard wakeRestarts <= 3 else {
                wakeArmed = false
                return
            }
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(600))
                self.beginWakeRecognition()
            }
        }
    }

    private func stopWake() {
        let was = wakeArmed
        wakeArmed = false
        guard was, !isSessionActive else { return }
        listener.holdEngine = false
        listener.stop()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        audioConfigured = false
    }

    private func ingestLevel(_ value: Double) {
        guard phase == .listening || phase == .speaking else { return }
        // Raw RMS. The orb applies the 30 ms attack / 250 ms release.
        // Playback metering drives `level` while speaking; the mic drives it while listening.
        level = value
        captureMeter = captureMeter * 0.45 + value * 0.55
        noteCaptureLevel()
    }

    /// Groq Whisper is request/response, so silence is detected from the mic level instead of partial transcripts.
    private func noteCaptureLevel() {
        guard captureFile, phase == .listening, !manualTurn else { return }
        if captureMeter > 0.2 {
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
        let defaults = SharedConfig.defaults
        defaults.set(isSessionActive, forKey: SharedConfig.Key.sessionActive)
        // The widget extension reads this key on reload. Flush before Control Center asks it to.
        defaults.synchronize()
        sessionLog.info("control flag \(self.isSessionActive, privacy: .public)")
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
