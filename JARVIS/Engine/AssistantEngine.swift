import ActivityKit

struct VoiceTurn: Identifiable, Equatable {
    let id: UUID
    var role: String
    var text: String
    var truncated: Bool
    var reasoning: String

    init(role: String, text: String, truncated: Bool = false, reasoning: String = "") {
        id = UUID()
        self.role = role
        self.text = text
        self.truncated = truncated
        self.reasoning = reasoning
    }
}
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
    /// More than one contact matched "call X". A tap or a spoken name places the call.
    private(set) var callChoices: [CallChoice] = []
    /// Contacts that matched "call X and tell them Y" before the brief is confirmed.
    private(set) var briefChoices: [CallChoice] = []
    /// A briefed call waiting for a spoken or tapped yes. Other approvals stay tap-only.
    private(set) var pendingCallBrief: PendingCallBrief?
    /// Bumped when the on-phone call log changes.
    private(set) var callLogTick: Int = 0
    var hasContactChoices: Bool { !callChoices.isEmpty || !briefChoices.isEmpty }
    /// True for a turn that asks about cloud work while a cloud task is planning or running.
    private(set) var cloudExecuting = false
    private(set) var turns: [VoiceTurn] = []
    /// Bumped when a research report is saved, so Conversation can reload it.
    private(set) var researchTick: Int = 0
    /// Bumped when a news briefing is saved, so the News panel can reload it.
    private(set) var newsTick: Int = 0
    private(set) var microphoneMuted = false
    /// True from the moment a session is requested until the microphone is actually listening.
    private(set) var voiceConnecting = false
    /// Energy or a partial transcript while listening.
    private(set) var userIsSpeaking = false
    private(set) var dictationText = ""
    private(set) var isDictating = false
    /// Name of a photo, PDF or text file waiting for the next question.
    private(set) var attachmentName: String?
    /// Latest generated picture, shown until the next one or until it is dismissed.
    private(set) var generatedPreview: Data?
    @ObservationIgnored private var attachmentMime: String?
    @ObservationIgnored private var attachmentData: Data?
    var messageDraft: MessageDraft?
    var mailDraft: MailDraft?

    @ObservationIgnored private var conversation: [ChatMessage] = []
    @ObservationIgnored private let listener = SpeechListener()
    @ObservationIgnored private let output = SpeechOutput()
    @ObservationIgnored private let tools = ToolExecutor()
    @ObservationIgnored private var pendingAction: PendingAction?
    @ObservationIgnored private var heldBrief = ""
    @ObservationIgnored private var callWatch: Task<Void, Never>?
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
    @ObservationIgnored private var bargeSince: Date?
    @ObservationIgnored private var launchedFromControl = false
    @ObservationIgnored private var utteranceBeingSpoken = ""
    @ObservationIgnored private var spokenSoFar = ""
    @ObservationIgnored private var turnAssistantStored = false
    /// Smoothed mic level used only to detect the end of a Groq recording.
    @ObservationIgnored private var captureMeter = 0.0
    /// Sentences still being spoken for the current streamed reply. Cancelled on barge-in.
    @ObservationIgnored private var spokenQueue: SpokenQueue?
    /// Enrolment owns the microphone. Wake and hands-free listening stay down until it finishes.
    @ObservationIgnored private var enrollmentHold = false
    @ObservationIgnored private var resumeSessionAfterEnrollment = false

    /// Silence that ends a turn. Sensitivity 0 waits 700ms; 1 waits 500ms.
    private var silenceTimeout: Duration {
        let sensitivity: Double = min(1.0, max(0.0, AppSettings.shared.vadSensitivity))
        let span: Double = sensitivity * 200.0
        let milliseconds: Double = 700.0 - span
        return .milliseconds(Int(milliseconds))
    }

    /// off → connecting → listening ↔ userSpeaking → thinking → aiSpeaking → listening.
    /// Mute drops into muted. Barge-in (speech for 250ms during playback) returns to userSpeaking.
    var voiceState: VoiceState {
        if VoiceSession.shared.exiting { return .ended }
        guard isSessionActive else { return .off }
        if voiceConnecting { return .connecting }
        if errorMessage != nil, phase == .idle { return .error }
        if microphoneMuted, phase == .listening { return .muted }
        switch phase {
        case .idle: return .listening
        case .listening: return userIsSpeaking ? .userSpeaking : .listening
        case .thinking: return .thinking
        case .speaking: return .aiSpeaking
        }
    }

    private init() {
        listener.onLevel = { [weak self] value in self?.ingestLevel(value) }
        listener.onTranscript = { [weak self] text, isFinal in self?.handleTranscript(text, isFinal: isFinal) }
        listener.onError = { [weak self] error in self?.handleListenerError(error) }
        output.onLevel = { [weak self] value in self?.ingestLevel(value) }
        output.onBargeIn = { [weak self] in self?.bargeIn() }
        listener.onBargeLevel = { [weak self] value in self?.noteBarge(value) }
        tools.onComposeMessage = { [weak self] draft in self?.messageDraft = draft }
        tools.onComposeMail = { [weak self] draft in self?.mailDraft = draft }
        output.bindVoiceGate(listener.gate)
        ContactDirectory.shared.warm()
        HTTPConnections.prewarm()
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

    func toggleMute() {
        microphoneMuted.toggle()
        UISelectionFeedbackGenerator().selectionChanged()
        if microphoneMuted {
            if phase == .listening { listener.stop() }
            userIsSpeaking = false
        } else if isSessionActive, pendingAction == nil, phase != .speaking, phase != .thinking {
            beginListening(manual: false)
        }
    }

    /// Fills the composer from one on-device utterance. Does not open a voice session.
    func toggleDictation() {
        if isDictating {
            listener.stop()
            isDictating = false
            refreshWake()
            return
        }
        guard !isSessionActive else { return }
        isDictating = true
        dictationText = ""
        Task {
            guard await prepareAudio() else {
                isDictating = false
                return
            }
            stopWake()
            do {
                try listener.start()
            } catch {
                isDictating = false
                errorMessage = error.localizedDescription
                refreshWake()
            }
        }
    }

    /// Starts listening and returns before the caller (`perform`) returns.
    /// The Live Activity is requested before the audio session is activated. The engine stays
    /// on this singleton for the whole session, including the gaps between utterances.
    @discardableResult
    func startSession(continuous: Bool, fromControl: Bool = false) async -> SessionStart {
        if isSessionActive, listener.isEngineRunning {
            sessionLog.info("startSession ignored; engine already running")
            publishControlState()
            return .alreadyRunning
        }
        launchedFromControl = fromControl
        microphoneMuted = false
        wakeArmed = false
        if isDictating {
            isDictating = false
            listener.stop()
        }
        voiceConnecting = true
        userIsSpeaking = false
        VoiceSession.shared.chatPresented = true
        VoiceSession.shared.exiting = false
        VoiceSession.shared.captionsOn = AppSettings.shared.captionsDefault
        VoiceSession.shared.showTranscript = false
        UIImpactFeedbackGenerator(style: .soft).impactOccurred()
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
        VoiceSession.shared.exiting = true
        UIImpactFeedbackGenerator(style: .soft).impactOccurred()
        interrupt()
        listener.holdEngine = false
        listener.stop()
        output.bindSharedPlayer(nil)
        isSessionActive = false
        isContinuous = false
        launchedFromControl = false
        microphoneMuted = false
        voiceConnecting = false
        userIsSpeaking = false
        phase = .idle
        level = 0
        await LiveActivityManager.shared.end(finalState: activityState)
        publishControlState()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        audioConfigured = false
        refreshWake()
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(160))
            VoiceSession.shared.exiting = false
        }
    }

    /// Foreground-only. Backgrounding stops the wake recogniser and leaves a control session alone.
    func setForeground(_ active: Bool) {
        appInForeground = active
        if active {
            refreshWake()
        } else {
            stopWake()
            VisionCamera.shared.suspend()
            // A control-center session stays up. An in-app voice session stays only when background conversations are on.
            if isSessionActive, !launchedFromControl, !AppSettings.shared.backgroundConversations {
                Task { await self.endSession(reason: "background") }
            }
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

    /// Keeps a photo, PDF or text file for the next question. Images are stored as JPEG.
    func stageFile(name: String, data: Data, ext: String) {
        if data.count > 8_000_000 {
            errorMessage = "That file is too large. Keep it under 8 MB."
            return
        }
        let lower = ext.lowercased()
        if lower == "pdf" {
            holdAttachment(name: name, mime: "application/pdf", data: data)
            return
        }
        if ["txt", "md", "csv", "json", "text"].contains(lower) {
            holdAttachment(name: name, mime: "text/plain", data: data)
            return
        }
        if let image = UIImage(data: data) {
            let quality: CGFloat = 0.7
            if let jpeg = image.jpegData(compressionQuality: quality) {
                let title = name.isEmpty ? "Photo" : name
                holdAttachment(name: title, mime: "image/jpeg", data: jpeg)
                return
            }
        }
        errorMessage = "JARVIS can read a photo, PDF or text file."
    }

    func clearAttachment() {
        attachmentName = nil
        attachmentMime = nil
        attachmentData = nil
    }

    private func holdAttachment(name: String, mime: String, data: Data) {
        attachmentName = name
        attachmentMime = mime
        attachmentData = data
        errorMessage = nil
    }

    private func takeAttachment(for text: String) -> StagedFile? {
        if Self.needsTools(text) || wantsCloudTool(text) || isBriefingRequest(text) || DeepResearch.wants(text) {
            return nil
        }
        guard let name = attachmentName, let mime = attachmentMime, let data = attachmentData else { return nil }
        clearAttachment()
        return StagedFile(name: name, mime: mime, data: data)
    }

    /// Typed request from the Tasks screen. Same turn pipeline as a finished utterance.
    func ask(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        LatencyLog.beginTurn("text-turn")
        Task {
            let session = AVAudioSession.sharedInstance()
            do {
                try Self.configureVoiceSession(session)
                try session.setActive(true)
                audioConfigured = true
                output.prewarm()
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

    private static func configureVoiceSession(_ session: AVAudioSession) throws {
        try session.setCategory(.playAndRecord, mode: .voiceChat,
                                options: [.defaultToSpeaker, .allowBluetoothHFP])
    }

    private func activateAudioSession() -> Bool {
        if !audioConfigured {
            do {
                let session = AVAudioSession.sharedInstance()
                try Self.configureVoiceSession(session)
                try session.setActive(true)
                audioConfigured = true
                sessionLog.info("AVAudioSession active playAndRecord voiceChat")
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
        spokenQueue?.cancel()
        spokenQueue = nil
        turnTask?.cancel()
        turnTask = nil
        output.stop()
        cloudExecuting = false
    }

    private func beginListening(manual: Bool) {
        LatencyLog.clear()
        manualTurn = manual
        transcript = ""
        heardVoice = false
        loudFrames = 0
        captureMeter = 0
        captureFile = false
        userIsSpeaking = false
        voiceConnecting = false
        if microphoneMuted {
            listener.stop()
            phase = .listening
            pushActivity()
            return
        }
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
        output.bindSharedPlayer(listener.sharedPlayback)
        output.prewarm()
        pushActivity()
    }

    func applyVoicePolicy() {
        listener.applyVoicePolicy()
    }

    /// Stops wake-word and hands-free capture so enrolment can open the microphone.
    func prepareVoiceEnrollment() async {
        if !enrollmentHold {
            resumeSessionAfterEnrollment = isSessionActive
            enrollmentHold = true
        }
        if isSessionActive {
            await endSession(reason: "voice-id")
        } else {
            stopWake()
            if listener.isEngineRunning {
                listener.holdEngine = false
                listener.stop()
            }
        }
    }

    /// Restores wake word, or the hands-free session enrolment interrupted.
    func finishVoiceEnrollment() {
        guard enrollmentHold else { return }
        enrollmentHold = false
        let resume = resumeSessionAfterEnrollment
        resumeSessionAfterEnrollment = false
        if resume {
            Task { await self.startSession(continuous: true) }
        } else {
            refreshWake()
        }
    }

    private func shouldCaptureForGroq() -> Bool {
        !fileCaptureBroken && !groqTranscriptionBroken && KeychainStore.get(.groq) != nil
    }

    private func handleTranscript(_ text: String, isFinal: Bool) {
        if isDictating {
            dictationText = text
            if isFinal {
                isDictating = false
                listener.stop()
                refreshWake()
            }
            return
        }
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
        guard phase == .listening, pendingAction == nil, !microphoneMuted else { return }
        transcript = text
        userIsSpeaking = !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
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
        if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            LatencyLog.noteSpeechEnd()
        }
        let timeout = silenceTimeout
        silenceTask = Task { [weak self] in
            try? await Task.sleep(for: timeout)
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
        LatencyLog.noteSpeechEndIfNeeded()
        LatencyLog.event("speech-end")
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
        cloudExecuting = false
        if isSessionActive && isContinuous {
            sessionLog.info("utterance finished; session stays listening")
            beginListening(manual: false)
        } else {
            phase = .idle
            pushActivity()
            refreshWake()
        }
    }

    func noteStatus(_ line: String?) {
        applyBusyStatus(line)
    }

    private func applyBusyStatus(_ line: String?) {
        if let line {
            statusLine = line
            errorMessage = nil
        } else if statusLine == ModelFallback.busyLine {
            statusLine = nil
        }
        pushActivity()
    }

    private struct Produced: Sendable {
        var text: String
        var spoken: Bool
        var reasoning: String

        init(text: String, spoken: Bool, reasoning: String = "") {
            self.text = text
            self.spoken = spoken
            self.reasoning = reasoning
        }
    }

    /// One model attempt. ModelFallback calls this again after a busy response.
    private func produce(text: String, endpoint: LLMEndpoint, system: String,
                         history: [ChatMessage], user: ChatMessage, streamTalk: Bool) async throws -> Produced {
        if WebKnowledge.needsLiveFacts(text), !Self.needsTools(text), !wantsCloudTool(text) {
            return try await answerLive(system: system, history: history, user: user, endpoint: endpoint)
        }
        if streamTalk {
            let streamed = try await streamedChat(system: system, history: history, user: user, endpoint: endpoint)
            return Produced(text: streamed.text, spoken: streamed.spoken)
        }
        let settings = AppSettings.shared
        let cloudTools = JarvisCloud.isConfigured && wantsCloudTool(text)
        switch settings.routing {
        case .chatOnly:
            if cloudTools {
                let raw = try await runAgent(system: system, history: history, user: user, endpoint: endpoint,
                                             includeWebSearch: false)
                return Produced(text: raw, spoken: false)
            }
            let streamed = try await streamedChat(system: system, history: history, user: user, endpoint: endpoint)
            return Produced(text: streamed.text, spoken: streamed.spoken)
        case .auto:
            let raw = try await runAgent(system: system, history: history, user: user, endpoint: endpoint,
                                         includeWebSearch: KeychainStore.get(.openAI) != nil)
            return Produced(text: raw, spoken: false)
        case .split:
            if cloudTools || Self.needsTools(text) {
                let raw = try await runAgent(system: system, history: history, user: user, endpoint: endpoint,
                                             includeWebSearch: false)
                return Produced(text: raw, spoken: false)
            }
            let classified = try await classify(text, endpoint: endpoint)
            if classified != .question {
                let raw = try await runAgent(system: system, history: history, user: user, endpoint: endpoint,
                                             includeWebSearch: false)
                return Produced(text: raw, spoken: false)
            }
            if endpoint.kind == .openAI {
                let raw = try await answerQuestion(system: system, history: history, user: user, endpoint: endpoint)
                return Produced(text: raw, spoken: false)
            }
            let streamed = try await streamedChat(system: system, history: history, user: user, endpoint: endpoint)
            return Produced(text: streamed.text, spoken: streamed.spoken)
        }
    }

    func placeCall(_ choice: CallChoice) {
        callChoices = []
        briefChoices = []
        heldBrief = ""
        interrupt()
        listener.stop()
        turnTask = Task { await self.dialNow(name: choice.name, number: choice.number) }
    }

    /// A spoken pick from the contact list, without another model request.
    private func resolveCallChoice(_ text: String) async -> Bool {
        guard !callChoices.isEmpty else { return false }
        if LocalCall.isCancel(text) {
            callChoices = []
            await speakLine("Cancelled.", userText: text)
            afterTurn()
            return true
        }
        if LocalCall.parse(text) == nil, let choice = ContactDirectory.shared.pick(text, from: callChoices) {
            callChoices = []
            await dialNow(name: choice.name, number: choice.number)
            return true
        }
        return false
    }

    /// "call X" is matched on the cached index and dialled before Gemini is asked.
    private func handleLocalCall(_ text: String) async -> Bool {
        guard let request = LocalCall.parse(text) else { return false }
        callChoices = []
        briefChoices = []
        heldBrief = ""
        if let number = request.number {
            await dialNow(name: number, number: number)
            return true
        }
        let granted = await ContactDirectory.shared.ensureLoaded()
        guard granted else {
            await speakLine("Contacts access is off. Enable it in iPhone Settings > JARVIS > Contacts.", userText: text)
            afterTurn()
            return true
        }
        switch ContactDirectory.shared.lookup(request.spoken) {
        case .dial(let name, let number):
            await dialNow(name: name, number: number)
            return true
        case .choose(let choices):
            callChoices = choices
            let names = choices.map(\.name).joined(separator: ", ")
            await speakLine("Which one? \(names)", userText: text)
            afterTurn()
            return true
        case .missing:
            if AgentStore.shared.agentNamed(request.spoken) != nil { return false }
            await speakLine("I don't have a number for \(request.spoken).", userText: text)
            afterTurn()
            return true
        }
    }

    private func dialNow(name: String, number: String) async {
        callChoices = []
        let digits = AppLauncher.digits(number)
        guard !digits.isEmpty, let url = URL(string: "tel://\(digits)") else {
            await speakLine("That number isn't valid.", userText: name)
            afterTurn()
            return
        }
        do {
            try await AppLauncher.open(url)
        } catch {
            await speakLine(error.localizedDescription, userText: name)
            afterTurn()
            return
        }
        let line = "Calling \(name)."
        reply = line
        recordAssistant(line)
        saveForWidget(transcript: transcript, reply: line)
        await say(line)
        finishQuietly()
    }

    private func speakLine(_ line: String, userText: String) async {
        reply = line
        recordAssistant(line)
        saveForWidget(transcript: userText, reply: line)
        await say(ResponsesClient.spokenText(line))
    }

    /// The Phone app is opening, so the microphone stays off.
    private func finishQuietly() {
        listener.stop()
        phase = .idle
        level = 0
        cloudExecuting = false
        statusLine = nil
        pushActivity()
        refreshWake()
    }

    private func respond(to text: String) async {
        phase = .thinking
        statusLine = nil
        errorMessage = nil
        reply = ""
        pushActivity()

        // Tool cards stay tap-only. Spoken words do not approve them.
        if pendingAction != nil { return }
        // A briefed phone call is the one approval that also accepts a spoken yes or no.
        if pendingCallBrief != nil {
            await resolvePendingCallBrief(text)
            return
        }

        spokenSoFar = ""
        utteranceBeingSpoken = ""
        turnAssistantStored = false
        let recordedUser = recordUser(text)

        if await resolveBriefChoice(text) { return }
        if await handleBriefedCall(text) { return }

        if let delegation = AgentStore.shared.delegation(in: text) {
            let ack = "\(delegation.agent.name) is on that."
            recordAssistant(ack)
            saveForWidget(transcript: text, reply: ack)
            await say(ResponsesClient.spokenText(ack))
            let agent = delegation.agent
            let goal = delegation.goal
            Task { await AgentStore.shared.delegate(agent: agent, goal: goal) }
            guard !Task.isCancelled else { return }
            afterTurn()
            return
        }

        if await resolveCallChoice(text) { return }
        if await handleLocalCall(text) { return }
        callChoices = []

        if wantsCloudTool(text) && CloudMonitor.shared.hasRunningWork {
            cloudExecuting = true
        }
        if NewsPulse.wants(text) {
            await deliverNews(userText: text)
            return
        }
        if isBriefingRequest(text) {
            await deliverBriefing(userText: text)
            return
        }
        if DeepResearch.wants(text) {
            await deliverResearch(userText: text)
            return
        }
        if ImageStudio.wants(text) {
            await deliverImage(userText: text)
            return
        }

        let settings = AppSettings.shared
        let userMessage = ChatMessage(role: "user", content: text)
        tools.resetTurn()
        citations = []
        let stagedFile = takeAttachment(for: text)
        let visionJPEG: Data?
        if stagedFile == nil {
            visionJPEG = await visionAttachment(for: text)
        } else {
            visionJPEG = nil
        }

        do {
            let facts = JarvisStore.allFacts()
            let prior = recordedUser ? Array(conversation.dropLast()) : conversation
            let history = Array(prior.suffix(16))
            let produced: Produced
            if let stagedFile {
                let system = settings.voicePrompt(facts: facts, question: text)
                produced = try await answerFile(file: stagedFile, system: system, history: history, user: userMessage)
            } else if let visionJPEG {
                let system = settings.voicePrompt(facts: facts, question: text)
                produced = try await answerVision(jpeg: visionJPEG, system: system, history: history, user: userMessage)
            } else {
                let endpoint = try settings.resolvedEndpoint()
                if endpoint.kind != settings.provider {
                    statusLine = "Using \(endpoint.providerName) because no \(settings.provider.title) key is saved."
                }
                let streamTalk = shouldStreamConversation(text)
                let system = streamTalk ? settings.voicePrompt(facts: facts, question: text) : settings.systemPrompt(facts: facts, question: text)
                if shouldThink(text) {
                    produced = try await answerThinking(system: system, history: history, user: userMessage)
                } else {
                    let primary = streamTalk ? settings.conversationalEndpoint(from: endpoint) : endpoint
                    let groq = streamTalk ? settings.fastGroqEndpoint() : settings.groqEndpoint()
                    produced = try await ModelFallback.run(
                        primary: primary,
                        groq: groq,
                        status: { line in self.applyBusyStatus(line) },
                        work: { endpoint in
                            try await self.produce(text: text, endpoint: endpoint, system: system,
                                                   history: history, user: userMessage, streamTalk: streamTalk)
                        }
                    )
                }
            }
            let raw = produced.text
            let alreadySpoken = produced.spoken
            guard !Task.isCancelled else { return }
            if pendingAction != nil {
                phase = .idle
                level = 0
                pushActivity()
                return
            }
            if citations.isEmpty { citations = tools.lastCitations }
            let parsed = MemoryParser.extract(from: raw)
            if settings.autoRemember {
                rememberFacts(parsed.facts)
                let userLine = text
                let replyLine = parsed.cleaned
                Task { await self.learn(user: userLine, reply: replyLine) }
            }
            let shown = parsed.cleaned.isEmpty ? "Noted, sir." : parsed.cleaned
            recordAssistant(shown, reasoning: produced.reasoning)
            saveForWidget(transcript: text, reply: shown)
            if !alreadySpoken {
                await say(ResponsesClient.spokenText(shown))
            }
        } catch {
            if Task.isCancelled { return }
            let line = LLMError.short(error)
            errorMessage = line
            reply = "⚠︎ \(line)"
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
                    return ""
                }
            }
        }
        statusLine = nil
        return "I'm afraid that took more steps than I'm allowed, sir."
    }

    // MARK: Briefed calls

    func chooseBriefedContact(_ choice: CallChoice) {
        let brief = heldBrief
        guard !brief.isEmpty else { return }
        interrupt()
        listener.stop()
        turnTask = Task {
            _ = self.recordUser(choice.name)
            await self.offerBrief(name: choice.name, number: choice.number, brief: brief, userText: choice.name)
        }
    }

    func approvePendingCall() {
        guard pendingCallBrief != nil else { return }
        interrupt()
        listener.stop()
        turnTask = Task { await self.placeApprovedCall(userText: "yes") }
    }

    func declinePendingCall() {
        guard pendingCallBrief != nil else { return }
        interrupt()
        listener.stop()
        turnTask = Task { await self.declineApprovedCall(userText: "no") }
    }

    func refreshOpenCalls() {
        Task { await self.pullOpenCalls() }
    }

    private func resolvePendingCallBrief(_ text: String) async {
        if CallApproval.isYes(text) {
            await placeApprovedCall(userText: text)
            return
        }
        if CallApproval.isNo(text) {
            await declineApprovedCall(userText: text)
            return
        }
        let name = pendingCallBrief?.contactName ?? "them"
        _ = recordUser(text)
        await speakLine("Say yes to call \(name), sir, or no to cancel.", userText: text)
        afterTurn()
    }

    private func resolveBriefChoice(_ text: String) async -> Bool {
        guard !briefChoices.isEmpty else { return false }
        if CallApproval.isNo(text) {
            briefChoices = []
            heldBrief = ""
            await speakLine("Cancelled, sir.", userText: text)
            afterTurn()
            return true
        }
        if let choice = ContactDirectory.shared.pick(text, from: briefChoices) {
            await offerBrief(name: choice.name, number: choice.number, brief: heldBrief, userText: text)
            return true
        }
        let names = briefChoices.map(\.name).joined(separator: ", ")
        await speakLine("Which one? \(names)", userText: text)
        afterTurn()
        return true
    }

    /// "call X and tell them Y" is confirmed here. It does not open tel://.
    private func handleBriefedCall(_ text: String) async -> Bool {
        guard let request = BriefedCall.parse(text) else { return false }
        callChoices = []
        briefChoices = []
        pendingCallBrief = nil
        if request.brief.isEmpty {
            await speakLine("What should I tell them, sir?", userText: text)
            afterTurn()
            return true
        }
        if let number = BriefedCall.phoneNumber(request.who) {
            await offerBrief(name: number, number: number, brief: request.brief, userText: text)
            return true
        }
        let granted = await ContactDirectory.shared.ensureLoaded()
        guard granted else {
            await speakLine("Contacts access is off. Enable it in iPhone Settings > JARVIS > Contacts.", userText: text)
            afterTurn()
            return true
        }
        switch ContactDirectory.shared.lookup(request.who) {
        case .dial(let name, let number):
            await offerBrief(name: name, number: number, brief: request.brief, userText: text)
        case .choose(let choices):
            briefChoices = choices
            heldBrief = request.brief
            let names = choices.map(\.name).joined(separator: ", ")
            await speakLine("Which \(request.who)? \(names)", userText: text)
            afterTurn()
        case .missing:
            await speakLine("I don't have a number for \(request.who).", userText: text)
            afterTurn()
        }
        return true
    }

    private func offerBrief(name: String, number: String, brief: String, userText: String) async {
        briefChoices = []
        callChoices = []
        heldBrief = ""
        if BriefedCall.isEmergency(number) {
            pendingCallBrief = nil
            await speakLine("I won't place that call from here, sir. A plain call still uses your iPhone.", userText: userText)
            afterTurn()
            return
        }
        pendingCallBrief = PendingCallBrief(contactName: name, number: number, brief: brief)
        let spokenBrief = brief.count > 280 ? String(brief.prefix(280)) + "…" : brief
        let who = name == number ? number : name
        let line = "I'll call \(who) and tell them \(spokenBrief). I'll introduce myself as your AI assistant. Say yes, sir, or no to cancel."
        await speakLine(line, userText: userText)
        afterTurn()
    }

    private func placeApprovedCall(userText: String) async {
        guard let brief = pendingCallBrief else { return }
        pendingCallBrief = nil
        briefChoices = []
        heldBrief = ""
        _ = recordUser(userText)
        phase = .thinking
        statusLine = "Placing the call…"
        pushActivity()
        let outcome = await placeBrief(brief)
        statusLine = nil
        switch outcome {
        case .notSetUp:
            CallLogStore.add(StoredCall.local(
                name: brief.contactName, number: brief.number, brief: brief.brief,
                status: "not_set_up", detail: "Calling not set up.", spoken: true))
            callLogTick += 1
            await speakLine("Calling isn't set up yet, sir. The UK number and the worker secrets still need to be added.", userText: userText)
        case .failed(let message):
            let detail = message.count > 180 ? String(message.prefix(180)) : message
            CallLogStore.add(StoredCall.local(
                name: brief.contactName, number: brief.number, brief: brief.brief,
                status: "failed", detail: detail, spoken: true))
            callLogTick += 1
            await speakLine("I couldn't place that call, sir. \(detail)", userText: userText)
        case .placed(let record):
            CallLogStore.update(StoredCall.fromServer(record, spoken: false))
            callLogTick += 1
            await speakLine("Ringing \(brief.contactName) now, sir. I'll tell you what they said when the call ends.", userText: userText)
            afterTurn()
            watchCall(id: record.id)
            return
        }
        guard !Task.isCancelled else { return }
        afterTurn()
    }

    private func declineApprovedCall(userText: String) async {
        guard let brief = pendingCallBrief else { return }
        pendingCallBrief = nil
        briefChoices = []
        heldBrief = ""
        _ = recordUser(userText)
        CallLogStore.add(StoredCall.local(
            name: brief.contactName, number: brief.number, brief: brief.brief,
            status: "cancelled", detail: "", spoken: true))
        callLogTick += 1
        await speakLine("Cancelled, sir. I won't call \(brief.contactName).", userText: userText)
        afterTurn()
    }

    private func placeBrief(_ brief: PendingCallBrief) async -> CallPlaceResult {
        guard JarvisCloud.isConfigured else { return .notSetUp }
        do {
            let client = try JarvisCloudAPI.client()
            return await client.placeOutboundCall(to: brief.number, contactName: brief.contactName, brief: brief.brief)
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    private func watchCall(id: String) {
        callWatch?.cancel()
        callWatch = Task { await self.pollCall(id: id) }
    }

    private func pollCall(id: String) async {
        for _ in 0..<120 {
            try? await Task.sleep(for: .seconds(4))
            if Task.isCancelled { return }
            guard JarvisCloud.isConfigured, let client = try? JarvisCloudAPI.client() else { return }
            guard let record = try? await client.outboundCall(id: id) else { continue }
            absorb(record, announce: true)
            if record.isFinished { return }
        }
    }

    private func pullOpenCalls() async {
        guard JarvisCloud.isConfigured, let client = try? JarvisCloudAPI.client() else { return }
        for row in CallLogStore.openCalls() where row.id.hasPrefix("call_") {
            guard let record = try? await client.outboundCall(id: row.id) else { continue }
            absorb(record, announce: true)
        }
    }

    private func absorb(_ record: PhoneCallRecord, announce: Bool) {
        let existing = CallLogStore.entries().first { $0.id == record.id }
        var stored = StoredCall.fromServer(record, spoken: existing?.spoken ?? false)
        if existing?.spoken == true { stored.spoken = true }
        let shouldSpeak = announce && record.isFinished && !stored.spoken
        if shouldSpeak { stored.spoken = true }
        CallLogStore.update(stored)
        callLogTick += 1
        guard shouldSpeak else { return }
        let name = stored.contactName
        let summary = stored.summary.isEmpty ? stored.detail : stored.summary
        let status = stored.status
        Task { await self.speakCallReport(name: name, summary: summary, status: status) }
    }

    private func speakCallReport(name: String, summary: String, status: String) async {
        let line = CallReport.spoken(name: name, summary: summary, status: status)
        for _ in 0..<40 {
            if phase == .idle || phase == .listening { break }
            try? await Task.sleep(for: .milliseconds(500))
            if Task.isCancelled { return }
        }
        recordAssistant(line)
        saveForWidget(transcript: name, reply: line)
        await say(line)
        if Task.isCancelled { return }
        if isSessionActive && isContinuous {
            beginListening(manual: false)
        } else {
            phase = .idle
            level = 0
            pushActivity()
            refreshWake()
        }
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
        if isSessionActive, phase != .speaking, phase != .thinking {
            beginListening(manual: false)
        }
    }

    private func runPendingAction() async {
        guard let action = pendingAction else { return }
        cancelPendingAction()
        phase = .thinking
        pushActivity()
        let result = await action.perform()
        recordAssistant(result)
        await say(result)
        guard !Task.isCancelled else { return }
        afterTurn()
    }

    func shortcutReturned(_ status: String) {
        statusLine = status == "shortcut-done" ? "Shortcut finished." : "Shortcut didn't complete."
    }

    private func say(_ text: String) async {
        guard !Task.isCancelled else { return }
        utteranceBeingSpoken = text
        output.preparePlayback()
        phase = .speaking
        pushActivity()
        await speak(text)
        if !Task.isCancelled {
            spokenSoFar = Self.joinSpoken(spokenSoFar, text)
            utteranceBeingSpoken = ""
        }
    }

    private func speak(_ text: String) async {
        let monitor = !listener.isEngineRunning && !microphoneMuted
        if listener.isEngineRunning, !microphoneMuted {
            listener.setBargeMonitor(true)
        }
        defer { listener.setBargeMonitor(false) }
        let s = AppSettings.shared
        guard let key = KeychainStore.get(.elevenLabs) else {
            errorMessage = "Add an ElevenLabs key in Settings. ElevenLabs is the only voice."
            return
        }
        do {
            try await output.speakElevenLabs(text: text, voiceID: s.voiceID, apiKey: key,
                                             stability: s.stability, similarity: s.similarity,
                                             monitorMicrophone: monitor)
        } catch {
            if Task.isCancelled { return }
            errorMessage = "ElevenLabs failed (\(error.localizedDescription))."
        }
    }

    private func noteBarge(_ value: Double) {
        guard phase == .speaking else {
            bargeSince = nil
            return
        }
        if listener.speechBandRatio < 0.30 {
            bargeSince = nil
            return
        }
        if AppSettings.shared.voiceMatchEnabled, !listener.allowsUtterance {
            bargeSince = nil
            return
        }
        let sensitivity: Double = min(1.0, max(0.0, AppSettings.shared.vadSensitivity))
        let base: Double = listener.voiceProcessingEnabled ? 0.32 : 0.48
        let span: Double = 1.2 - sensitivity * 0.4
        let threshold: Double = base * span
        if value > threshold {
            let start = bargeSince ?? Date()
            bargeSince = start
            if Date().timeIntervalSince(start) >= 0.25 {
                bargeSince = nil
                bargeIn()
            }
        } else if value < threshold * 0.6 {
            bargeSince = nil
        }
    }

    /// Mic energy during playback: stop the voice immediately and listen.
    private func bargeIn() {
        guard phase == .speaking else { return }
        sessionLog.info("barge-in")
        UISelectionFeedbackGenerator().selectionChanged()
        commitSpokenFragment()
        let keepListening = isSessionActive || isContinuous
        interrupt()
        if keepListening {
            beginListening(manual: false)
            userIsSpeaking = true
        } else {
            phase = .idle
            level = 0
            pushActivity()
        }
    }

    @discardableResult
    private func recordUser(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        conversation.append(ChatMessage(role: "user", content: trimmed))
        turns.append(VoiceTurn(role: "user", text: trimmed))
        return true
    }

    /// A background agent posts its result into this chat without starting another turn.
    func postAgentUpdate(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        recordAssistant(trimmed)
        saveForWidget(transcript: "Agent", reply: trimmed)
    }

    private func recordAssistant(_ text: String, truncated: Bool = false, reasoning: String = "") {
        conversation.append(ChatMessage(role: "assistant", content: text))
        turns.append(VoiceTurn(role: "assistant", text: text, truncated: truncated, reasoning: reasoning))
        reply = text
        turnAssistantStored = true
    }

    /// Barge-in keeps the words that were actually heard and drops the rest of the reply.
    private func commitSpokenFragment() {
        let kept = Self.joinSpoken(spokenSoFar, Self.spokenPrefix(utteranceBeingSpoken, fraction: output.playbackFraction))
        if turnAssistantStored, conversation.last?.role == "assistant" {
            conversation.removeLast()
            if turns.last?.role == "assistant" { turns.removeLast() }
            turnAssistantStored = false
        }
        if kept.isEmpty {
            reply = ""
        } else {
            let marked = kept.hasSuffix("…") ? kept : kept + "…"
            recordAssistant(marked, truncated: true)
        }
        spokenSoFar = ""
        utteranceBeingSpoken = ""
    }

    private static func joinSpoken(_ earlier: String, _ later: String) -> String {
        let first = earlier.trimmingCharacters(in: .whitespacesAndNewlines)
        let second = later.trimmingCharacters(in: .whitespacesAndNewlines)
        if first.isEmpty { return second }
        if second.isEmpty { return first }
        if first.hasSuffix(second) { return first }
        return first + " " + second
    }

    private static func spokenPrefix(_ text: String, fraction: Double) -> String {
        let words = text.split(separator: " ").map(String.init)
        guard !words.isEmpty else { return "" }
        if fraction >= 0.98 { return text.trimmingCharacters(in: .whitespacesAndNewlines) }
        let count = Int((Double(words.count) * fraction).rounded(.down))
        guard count > 0 else { return "" }
        return words.prefix(count).joined(separator: " ")
    }

    /// World headlines from grounded search. "What's been happening" stays on the cloud briefing.
    private func deliverNews(userText: String) async {
        let persona = AppSettings.shared.personality
        let outcome = await NewsPulse.run(question: userText, persona: persona) { step in
            self.statusLine = step
            self.pushActivity()
        }
        guard !Task.isCancelled else { return }
        citations = outcome.citations
        statusLine = nil
        recordAssistant(outcome.report)
        saveForWidget(transcript: userText, reply: outcome.spoken)
        NewsPulseStore.save(text: outcome.report, citations: outcome.citations)
        newsTick += 1
        await say(outcome.spoken)
        guard !Task.isCancelled else { return }
        afterTurn()
    }

    func clearGenerated() {
        generatedPreview = nil
    }

    /// A picture from Gemini's image model, or Pollinations when that is unavailable. Saved to Photos.
    private func deliverImage(userText: String) async {
        statusLine = "Drawing…"
        pushActivity()
        let source = takeImageSource()
        let made = await ImageStudio.make(prompt: userText, sourceJPEG: source)
        guard !Task.isCancelled else { return }
        statusLine = nil
        guard let jpeg = made.jpeg else {
            let line = source == nil ? "I couldn't make that picture." : "I couldn't edit that photo."
            recordAssistant(line)
            saveForWidget(transcript: userText, reply: line)
            await say(line)
            guard !Task.isCancelled else { return }
            afterTurn()
            return
        }
        generatedPreview = jpeg
        let saved = await PhotoSaver.add(jpeg)
        let line = saved ? "Done, sir. It's in your photos." : "Done, sir. Photos access is off, so I haven't saved it."
        recordAssistant(line)
        saveForWidget(transcript: userText, reply: line)
        await say(line)
        guard !Task.isCancelled else { return }
        afterTurn()
    }

    private func takeImageSource() -> Data? {
        guard attachmentMime == "image/jpeg", let data = attachmentData else { return nil }
        clearAttachment()
        return data
    }

    /// A multi-step search. The full report is saved under Conversation. Only the summary is spoken.
    private func deliverResearch(userText: String) async {
        let persona = AppSettings.shared.personality
        let outcome = await DeepResearch.run(question: userText, persona: persona) { step in
            self.statusLine = step
            self.pushActivity()
        }
        guard !Task.isCancelled else { return }
        citations = outcome.citations
        statusLine = nil
        recordAssistant(outcome.report)
        saveForWidget(transcript: userText, reply: outcome.spoken)
        ResearchStore.save(title: outcome.title, question: userText, body: outcome.report, sources: outcome.citations)
        researchTick += 1
        await say(outcome.spoken)
        guard !Task.isCancelled else { return }
        afterTurn()
    }

    /// Morning and "what's been happening" are read from the stored briefing, then spoken as facts then recommendations.
    private func deliverBriefing(userText: String) async {
        let spoken: String
        do {
            let briefing = try await JarvisCloudAPI.client().briefing()
            spoken = CloudSpeech.briefing(briefing)
            await CloudMonitor.shared.refresh()
        } catch {
            spoken = error.localizedDescription
            errorMessage = spoken
        }
        guard !Task.isCancelled else { return }
        recordAssistant(spoken)
        saveForWidget(transcript: userText, reply: spoken)
        await say(spoken)
        guard !Task.isCancelled else { return }
        afterTurn()
    }

    private func isBriefingRequest(_ text: String) -> Bool {
        let lower = text.lowercased()
        let phrases = [
            "what's been happening", "whats been happening", "what has been happening",
            "what have you been doing", "briefing",
        ]
        if phrases.contains(where: { lower.contains($0) }) { return true }
        let stripped = lower.replacingOccurrences(of: "jarvis", with: " ")
        let words = stripped.split { !$0.isLetter }.map(String.init).joined(separator: " ")
        return words == "morning" || words == "good morning"
    }

    private func wantsCloudTool(_ text: String) -> Bool {
        if isBriefingRequest(text) { return true }
        let lower = text.lowercased()
        let needles = [
            "cloud task", "create a task", "new task", "my tasks", "list tasks",
            "approval", "pipeline", "briefing", "mrr", "lead",
        ]
        return needles.contains { lower.contains($0) }
    }

    /// Saves on this iPhone first. A copy is sent to JARVIS Cloud only after that write, and only when cloud is configured.
    func rememberFacts(_ facts: [String]) {
        let saved = JarvisStore.add(facts)
        guard !saved.isEmpty else { return }
        Task { await self.rememberOnCloud(saved) }
    }

    /// A second, quiet pass for durable facts the spoken reply did not mark.
    private func learn(user: String, reply: String) async {
        let trimmed = user.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.worthRemembering(trimmed) else { return }
        guard let endpoint = try? AppSettings.shared.resolvedEndpoint() else { return }
        let fast = AppSettings.shared.conversationalEndpoint(from: endpoint)
        let system = """
        Extract durable facts the user stated about themselves: name, preferences, people, places, work, habits. \
        Ignore questions, one-off requests, weather, news, and the assistant's guesses. \
        Reply with one line per fact in the exact form REMEMBER: fact \
        or a single line NONE. No other text.
        """
        let note = "User: \(trimmed)\nAssistant: \(reply)"
        let messages = [
            ChatMessage(role: "system", content: system),
            ChatMessage(role: "user", content: note),
        ]
        let temperature: Double = 0
        let raw: String
        do {
            raw = try await LLMClient.complete(messages: messages, endpoint: fast, temperature: temperature)
        } catch {
            return
        }
        let found = MemoryParser.extract(from: raw).facts.filter { fact in
            let lower = fact.lowercased()
            return lower != "none" && fact.count <= 180
        }
        let capped = Array(found.prefix(3))
        rememberFacts(capped)
    }

    private static func worthRemembering(_ text: String) -> Bool {
        if text.count < 12 { return false }
        let lower = text.lowercased()
        let signals = ["i ", "i'm", "i’m", "i am", "my ", "i like", "i prefer", "i hate", "i live", "i work", "call me", "remember "]
        return signals.contains { lower.contains($0) }
    }

    /// Local REMEMBER lines stay on the phone. When the cloud is configured, the same facts are stored there too.
    private func rememberOnCloud(_ facts: [String]) async {
        guard JarvisCloud.isConfigured, !facts.isEmpty else { return }
        do {
            let client = try JarvisCloudAPI.client()
            for fact in facts {
                _ = try await client.createMemory(content: fact, key: nil, tags: ["preference"], sourceURLs: [])
            }
            await CloudMonitor.shared.refresh()
        } catch {
            // A failed cloud write must not replace the spoken reply.
        }
    }

    private struct StreamedReply {
        var text: String
        var spoken: Bool
    }

    /// Current facts: Gemini Google Search, then free web notes spoken by Groq or the fast model.
    private func answerLive(system: String, history: [ChatMessage], user: ChatMessage,
                            endpoint: LLMEndpoint) async throws -> Produced {
        statusLine = Self.searchingLine
        pushActivity()
        defer {
            if statusLine == Self.searchingLine { statusLine = nil }
        }
        let date = Date.now.formatted(date: .complete, time: .shortened)
        let brief = system + " Today is \(date). Answer from live information. Do not read URLs aloud."
        if let key = KeychainStore.get(.gemini), !key.isEmpty {
            let models = Self.groundModels()
            var index: Int = 0
            while index < models.count {
                let model = models[index]
                do {
                    let streamed = try await streamedGrounded(model: model, apiKey: key, system: brief,
                                                             history: history, user: user)
                    let trimmed = streamed.text.trimmingCharacters(in: .whitespacesAndNewlines)
                    if trimmed.isEmpty { throw LLMError.emptyReply(provider: "Gemini") }
                    if statusLine == Self.searchingLine { statusLine = nil }
                    return Produced(text: streamed.text, spoken: streamed.spoken)
                } catch {
                    if Task.isCancelled { throw error }
                    let retryOther = Self.groundingRejected(error)
                    if !retryOther { break }
                    index += 1
                }
            }
        }
        let notes = await FreeWebSearch.gather(query: user.content)
        mergeCitations(notes.citations)
        let noteBlock = notes.context.isEmpty
            ? "No live notes arrived. If the fact may have changed, say you could not confirm it."
            : "Live notes:\n\(notes.context)\nUse these notes. Do not invent newer numbers."
        let informed = brief + "\n\n" + noteBlock
        let speaker = AppSettings.shared.fastGroqEndpoint()
            ?? AppSettings.shared.conversationalEndpoint(from: endpoint)
        let streamed = try await streamedChat(system: informed, history: history, user: user, endpoint: speaker)
        if statusLine == Self.searchingLine { statusLine = nil }
        return Produced(text: streamed.text, spoken: streamed.spoken)
    }

    private static let searchingLine = "Searching…"
    private static let lookingLine = "Looking…"

    /// A live frame or a snapped photo. Calls, tools and briefings keep their own path.
    /// A plain web question keeps searching unless they are pointing at something.
    private func visionAttachment(for text: String) async -> Data? {
        if Self.needsTools(text) || wantsCloudTool(text) || isBriefingRequest(text) { return nil }
        let camera = VisionCamera.shared
        if !camera.hasHeld && !camera.isLive { return nil }
        if WebKnowledge.needsLiveFacts(text), !camera.hasHeld, !Self.wantsEyes(text) { return nil }
        if camera.hasHeld { return camera.frameForQuestion() }
        guard camera.isLive else { return nil }
        var waited: Int = 0
        while waited < 8 {
            if let frame = camera.frameForQuestion() { return frame }
            try? await Task.sleep(for: .milliseconds(250))
            waited += 1
        }
        return camera.frameForQuestion()
    }

    private static func wantsEyes(_ text: String) -> Bool {
        let lower = text.lowercased()
        let needles = ["see", "look", "this", "holding", "wearing", "picture", "photo", "camera"]
        return needles.contains { lower.contains($0) }
    }

    private func shouldThink(_ text: String) -> Bool {
        let mode = AppSettings.shared.thinkingMode
        if mode == .off { return false }
        if mode == .auto, !Self.wantsThinking(text) { return false }
        if Self.needsTools(text) || wantsCloudTool(text) || WebKnowledge.needsLiveFacts(text) { return false }
        return true
    }

    private static func wantsThinking(_ text: String) -> Bool {
        let lower = text.lowercased()
        let needles = [
            "explain", "why ", "why?", "how does", "how do ", "compare", "analyse", "analyze",
            "step by step", "prove", "calculate", "work out", "trade-off", "tradeoff",
            "strategy", "debug", "what's wrong", "in depth", "think through", "reason about",
        ]
        return needles.contains { lower.contains($0) }
    }

    /// Hard questions. Gemini spends a thinking budget; Groq uses DeepSeek-R1 distill if Gemini cannot.
    private func answerThinking(system: String, history: [ChatMessage], user: ChatMessage) async throws -> Produced {
        statusLine = Self.reasoningLine
        pushActivity()
        defer {
            if statusLine == Self.reasoningLine || statusLine == ModelFallback.busyLine {
                statusLine = nil
            }
        }
        let brief = system + " Reason privately. Speak only the answer, in one to three sentences unless asked for more."
        if let key = KeychainStore.get(.gemini), !key.isEmpty {
            let models = Self.groundModels()
            var last: Error = LLMError.emptyReply(provider: "Gemini")
            var index: Int = 0
            while index < models.count {
                let model = models[index]
                var attempt: Int = 0
                var moveOn = false
                while attempt < 3 {
                    do {
                        let box = ReasoningBox()
                        let stream = GeminiThinking.stream(system: brief, history: history, user: user,
                                                           model: model, apiKey: key, box: box)
                        let streamed = try await speakStream(stream, fallback: nil)
                        let trimmed = streamed.text.trimmingCharacters(in: .whitespacesAndNewlines)
                        if trimmed.isEmpty { throw LLMError.emptyReply(provider: "Gemini") }
                        return Produced(text: streamed.text, spoken: streamed.spoken, reasoning: box.copy())
                    } catch {
                        if Task.isCancelled { throw error }
                        last = error
                        guard let llm = error as? LLMError else { throw error }
                        if llm.isBusy {
                            statusLine = ModelFallback.busyLine
                            pushActivity()
                            let shift: Int = attempt
                            let delay: Int = 400 * (1 << shift)
                            try await Task.sleep(for: .milliseconds(delay))
                            attempt += 1
                            continue
                        }
                        if Self.groundingRejected(error) {
                            moveOn = true
                            break
                        }
                        moveOn = true
                        break
                    }
                }
                if !moveOn, attempt >= 3 {
                    index += 1
                    continue
                }
                index += 1
                if let llm = last as? LLMError, !Self.groundingRejected(llm), !llm.isBusy {
                    break
                }
            }
        }
        if let key = KeychainStore.get(.groq), !key.isEmpty {
            do {
                let pair = try await GroqThinking.collect(system: brief, history: history, user: user, apiKey: key)
                let stream = Self.once(pair.answer)
                let streamed = try await speakStream(stream, fallback: nil)
                return Produced(text: streamed.text, spoken: streamed.spoken, reasoning: pair.reasoning)
            } catch {
                if Task.isCancelled { throw error }
                if let llm = error as? LLMError, case .http(let code, _, _) = llm, code == 404 || code == 400 {
                    // The distill model can be retired. A normal reply is better than silence.
                } else if let llm = error as? LLMError, llm.isBusy {
                    throw error
                } else {
                    throw error
                }
            }
        }
        guard let endpoint = try? AppSettings.shared.resolvedEndpoint() else {
            throw LLMError.missingKey("Gemini")
        }
        let fast = AppSettings.shared.conversationalEndpoint(from: endpoint)
        let streamed = try await streamedChat(system: brief, history: history, user: user, endpoint: fast)
        return Produced(text: streamed.text, spoken: streamed.spoken)
    }

    private static let reasoningLine = "Reasoning…"

    private static func once(_ text: String) -> AsyncThrowingStream<GroundedDelta, Error> {
        AsyncThrowingStream { continuation in
            continuation.yield(GroundedDelta(text: text, citations: []))
            continuation.finish()
        }
    }

    /// A staged photo, PDF or text file. Gemini reads it. The reply stays in the usual voice.
    private func answerFile(file: StagedFile, system: String, history: [ChatMessage],
                            user: ChatMessage) async throws -> Produced {
        statusLine = Self.readingLine
        pushActivity()
        defer {
            if statusLine == Self.readingLine || statusLine == ModelFallback.busyLine {
                statusLine = nil
            }
        }
        guard let key = KeychainStore.get(.gemini), !key.isEmpty else {
            throw LLMError.missingKey("Gemini")
        }
        let brief = system + " The user attached a file named \(file.name). Answer from that file. Do not invent pages or details that are not in it."
        let models = Self.groundModels()
        var last: Error = LLMError.emptyReply(provider: "Gemini")
        var index: Int = 0
        while index < models.count {
            let model = models[index]
            var attempt: Int = 0
            while attempt < 3 {
                do {
                    let stream = GeminiFiles.stream(system: brief, history: history, user: user,
                                                    file: file, model: model, apiKey: key)
                    let streamed = try await speakStream(stream, fallback: nil)
                    let trimmed = streamed.text.trimmingCharacters(in: .whitespacesAndNewlines)
                    if trimmed.isEmpty { throw LLMError.emptyReply(provider: "Gemini") }
                    return Produced(text: streamed.text, spoken: streamed.spoken)
                } catch {
                    if Task.isCancelled { throw error }
                    last = error
                    guard let llm = error as? LLMError else { throw error }
                    if llm.isBusy {
                        statusLine = ModelFallback.busyLine
                        pushActivity()
                        let shift: Int = attempt
                        let delay: Int = 400 * (1 << shift)
                        try await Task.sleep(for: .milliseconds(delay))
                        attempt += 1
                        continue
                    }
                    if Self.groundingRejected(error) { break }
                    throw error
                }
            }
            index += 1
        }
        throw last
    }

    private static let readingLine = "Reading…"

    /// Gemini sees one JPEG and answers in the same voice as a spoken turn.
    private func answerVision(jpeg: Data, system: String, history: [ChatMessage],
                              user: ChatMessage) async throws -> Produced {
        statusLine = Self.lookingLine
        pushActivity()
        defer {
            if statusLine == Self.lookingLine || statusLine == ModelFallback.busyLine {
                statusLine = nil
            }
        }
        guard let key = KeychainStore.get(.gemini), !key.isEmpty else {
            throw LLMError.missingKey("Gemini")
        }
        let brief = system + " The user is showing you a photo from the iPhone camera. Answer their question about it. When they ask what you see, describe only what is visible. Do not claim you can see anything that is not in the photo."
        let models = Self.groundModels()
        var last: Error = LLMError.emptyReply(provider: "Gemini")
        var index: Int = 0
        while index < models.count {
            let model = models[index]
            var attempt: Int = 0
            while attempt < 3 {
                do {
                    let stream = GeminiVision.stream(system: brief, history: history, user: user,
                                                     jpeg: jpeg, model: model, apiKey: key)
                    let streamed = try await speakStream(stream, fallback: nil)
                    let trimmed = streamed.text.trimmingCharacters(in: .whitespacesAndNewlines)
                    if trimmed.isEmpty { throw LLMError.emptyReply(provider: "Gemini") }
                    if statusLine == Self.lookingLine { statusLine = nil }
                    return Produced(text: streamed.text, spoken: streamed.spoken)
                } catch {
                    if Task.isCancelled { throw error }
                    last = error
                    guard let llm = error as? LLMError else { throw error }
                    if llm.isBusy {
                        statusLine = ModelFallback.busyLine
                        pushActivity()
                        let shift: Int = attempt
                        let delay: Int = 400 * (1 << shift)
                        try await Task.sleep(for: .milliseconds(delay))
                        attempt += 1
                        continue
                    }
                    if Self.groundingRejected(error) { break }
                    throw error
                }
            }
            index += 1
        }
        throw last
    }

    private static func groundModels() -> [String] {
        let fast = AppSettings.fastGeminiModel
        let full = AppSettings.defaultGeminiModel
        if fast == full { return [fast] }
        return [fast, full]
    }

    private static func groundingRejected(_ error: Error) -> Bool {
        guard let llm = error as? LLMError else { return false }
        if case .emptyReply = llm { return true }
        if case .http(let code, _, _) = llm { return code == 400 || code == 404 }
        return false
    }

    private func streamedGrounded(model: String, apiKey: String, system: String,
                                  history: [ChatMessage], user: ChatMessage) async throws -> StreamedReply {
        let stream = GeminiGrounding.stream(system: system, history: history, user: user, model: model, apiKey: apiKey)
        return try await speakStream(stream, fallback: nil)
    }

    /// Speaks each short chunk as it arrives. The first chunk starts ElevenLabs before the reply finishes.
    private func streamedChat(system: String, history: [ChatMessage], user: ChatMessage,
                              endpoint: LLMEndpoint) async throws -> StreamedReply {
        let messages = [ChatMessage(role: "system", content: system)] + history + [user]
        let stream = Self.asGrounded(LLMClient.streamDeltas(messages: messages, endpoint: endpoint))
        return try await speakStream(stream) {
            try await LLMClient.complete(messages: messages, endpoint: endpoint)
        }
    }

    private static func asGrounded(_ text: AsyncThrowingStream<String, Error>) -> AsyncThrowingStream<GroundedDelta, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await piece in text {
                        continuation.yield(GroundedDelta(text: piece, citations: []))
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func speakStream(_ stream: AsyncThrowingStream<GroundedDelta, Error>,
                             fallback: (() async throws -> String)?) async throws -> StreamedReply {
        let queue = SpokenQueue(
            speak: { [weak self] piece in
                await self?.say(piece)
            },
            prefetch: { [weak self] piece in
                self?.prefetchSpeech(piece)
            }
        )
        spokenQueue = queue
        defer {
            if let current = spokenQueue, current === queue {
                spokenQueue = nil
            }
        }
        var full = ""
        var taken = 0
        var spoke = false
        LatencyLog.event("llm-request")
        do {
            for try await delta in stream {
                try Task.checkCancellation()
                mergeCitations(delta.citations)
                if delta.text.isEmpty { continue }
                if full.isEmpty {
                    LatencyLog.event("llm-first-token")
                    if statusLine == Self.searchingLine || statusLine == Self.lookingLine {
                        statusLine = nil
                    }
                }
                full += delta.text
                let cleaned = MemoryParser.extract(from: full).cleaned
                if !cleaned.isEmpty {
                    reply = cleaned
                    pushActivity()
                }
                let ready = Self.takeChunks(from: cleaned, taken: taken, flush: false)
                taken = ready.taken
                for chunk in ready.chunks {
                    let piece = ResponsesClient.spokenText(chunk)
                    if piece.isEmpty { continue }
                    spoke = true
                    queue.add(piece)
                }
            }
        } catch {
            if Task.isCancelled {
                queue.cancel()
                throw error
            }
            if let llm = error as? LLMError, llm.isBusy, full.isEmpty {
                queue.cancel()
                throw error
            }
            if full.isEmpty {
                queue.cancel()
                if let fallback {
                    LatencyLog.event("llm-fallback")
                    let text = try await fallback()
                    return StreamedReply(text: text, spoken: false)
                }
                throw error
            }
        }
        let cleaned = MemoryParser.extract(from: full).cleaned
        let rest = Self.takeChunks(from: cleaned, taken: taken, flush: true)
        for chunk in rest.chunks {
            let piece = ResponsesClient.spokenText(chunk)
            if piece.isEmpty { continue }
            spoke = true
            queue.add(piece)
        }
        await queue.close()
        guard !Task.isCancelled else { return StreamedReply(text: full, spoken: spoke) }
        return StreamedReply(text: full, spoken: spoke)
    }

    private func mergeCitations(_ incoming: [Citation]) {
        guard !incoming.isEmpty else { return }
        var seen = Set(citations.map(\.url))
        var next = citations
        for item in incoming {
            if seen.insert(item.url).inserted {
                next.append(item)
            }
        }
        if next.count != citations.count {
            citations = next
        }
    }

    private func prefetchSpeech(_ text: String) {
        let settings = AppSettings.shared
        guard let key = KeychainStore.get(.elevenLabs) else { return }
        output.prefetch(text: text, voiceID: settings.voiceID, apiKey: key,
                        stability: settings.stability, similarity: settings.similarity)
    }

    /// Ready speech from `taken` characters onward. `flush` returns whatever is left.
    private static func takeChunks(from text: String, taken: Int, flush: Bool) -> (chunks: [String], taken: Int) {
        let count: Int = text.count
        guard taken >= 0, taken < count else { return ([], taken) }
        let start = text.index(text.startIndex, offsetBy: taken)
        var remainder = String(text[start...])
        var chunks: [String] = []
        var used: Int = taken
        while !remainder.isEmpty {
            guard let chunk = firstChunk(in: remainder, flush: flush) else { break }
            let spoken = chunk.trimmingCharacters(in: .whitespacesAndNewlines)
            if !spoken.isEmpty { chunks.append(spoken) }
            let chunkCount: Int = chunk.count
            used += chunkCount
            if chunkCount >= remainder.count { break }
            let after = remainder.index(remainder.startIndex, offsetBy: chunkCount)
            var cursor = after
            while cursor < remainder.endIndex {
                let character = remainder[cursor]
                if !character.isWhitespace { break }
                cursor = remainder.index(after: cursor)
                used += 1
            }
            remainder = String(remainder[cursor...])
        }
        return (chunks, used)
    }

    /// A chunk is ready at punctuation, or at 18 characters on a word boundary.
    private static func firstChunk(in text: String, flush: Bool) -> String? {
        if let punctuated = punctuationChunk(in: text) { return punctuated }
        if let bounded = lengthChunk(in: text) { return bounded }
        guard flush else { return nil }
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return nil }
        return text
    }

    private static func punctuationChunk(in text: String) -> String? {
        let chars = Array(text)
        let count: Int = chars.count
        var index: Int = 0
        while index < count {
            let ch = chars[index]
            let isBreak: Bool = ch == "." || ch == "!" || ch == "?" || ch == ";" || ch == "," || ch == ":"
            if isBreak && index >= 1 {
                let previous = chars[index - 1]
                if ch == "." && previous.isNumber {
                    index += 1
                    continue
                }
                if index + 1 < count {
                    let following = chars[index + 1]
                    if following.isLetter {
                        index += 1
                        continue
                    }
                }
                return String(chars[0...index])
            }
            index += 1
        }
        return nil
    }

    private static func lengthChunk(in text: String) -> String? {
        let minimum: Int = 18
        let count: Int = text.count
        guard count >= minimum else { return nil }
        let windowLimit: Int = min(48, count)
        let window = text.prefix(windowLimit)
        let floor: Int = 12
        if let space = window.lastIndex(of: " ") {
            let distance: Int = text.distance(from: text.startIndex, to: space)
            if distance >= floor {
                return String(text[..<space])
            }
        }
        let cut = text.index(text.startIndex, offsetBy: minimum)
        return String(text[..<cut])
    }

    /// Phone, calendar and cloud actions keep the tool path. Everything else is spoken chat.
    private func shouldStreamConversation(_ text: String) -> Bool {
        if JarvisCloud.isConfigured && wantsCloudTool(text) { return false }
        if AppSettings.shared.routing == .chatOnly { return true }
        return !Self.needsTools(text)
    }

    private static func needsTools(_ text: String) -> Bool {
        let lower = text.lowercased()
        let needles = [
            "message", "whatsapp", "facetime", "face time", "remind", "reminder",
            "calendar", "timer", "alarm", "play ", "music", "directions", "navigate",
            "maps", "open ", "shortcut", "email", "e-mail", "schedule", "text ",
            "sms", "appointment", "meeting",
        ]
        return needles.contains { lower.contains($0) }
    }

    private static func hearsWakeWord(_ text: String) -> Bool {
        text.range(of: "jarvis", options: [.caseInsensitive, .diacriticInsensitive]) != nil
    }

    private func refreshWake() {
        if enrollmentHold { return }
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
        // Raw RMS. While the assistant speaks, the orb scales with a 30 ms attack and 120 ms release.
        // The microphone does not move the orb. Playback metering drives `level` only during speech.
        level = value
        captureMeter = captureMeter * 0.45 + value * 0.55
        noteCaptureLevel()
    }

    /// Groq Whisper is request/response, so silence is detected from the mic level instead of partial transcripts.
    private func noteCaptureLevel() {
        guard captureFile, phase == .listening, !manualTurn else { return }
        let floor: Double = 0.30
        let bandFloor: Double = 0.35
        let band: Double = listener.speechBandRatio
        let speakerOK: Bool = listener.allowsUtterance
        if captureMeter > floor && band >= bandFloor && speakerOK {
            loudFrames += 1
            // Voice match already required a stretch of speech, so one loud frame can end the turn.
            let needed: Int = AppSettings.shared.voiceMatchEnabled ? 1 : 3
            if loudFrames >= needed {
                heardVoice = true
                userIsSpeaking = true
                silenceTask?.cancel()
                LatencyLog.noteSpeechEnd()
                let timeout = silenceTimeout
                silenceTask = Task { [weak self] in
                    try? await Task.sleep(for: timeout)
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

/// Speaks sentence chunks in order. The next chunk's audio is fetched while the current one plays.
@MainActor
private final class SpokenQueue {
    private var pending: [String] = []
    private var pumping = false
    private var closed = false
    private var finished = false
    private var waiter: CheckedContinuation<Void, Never>?
    private var pumpTask: Task<Void, Never>?
    private let speak: (String) async -> Void
    private let prefetch: (String) -> Void

    init(speak: @escaping (String) async -> Void, prefetch: @escaping (String) -> Void) {
        self.speak = speak
        self.prefetch = prefetch
    }

    func add(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !closed else { return }
        pending.append(trimmed)
        if pumping, let latest = pending.last {
            prefetch(latest)
        }
        pump()
    }

    func close() async {
        closed = true
        if finished || (!pumping && pending.isEmpty) { return }
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            if finished || (!pumping && pending.isEmpty) {
                cont.resume()
                return
            }
            waiter = cont
        }
    }

    func cancel() {
        pending.removeAll()
        closed = true
        pumpTask?.cancel()
        finishWait()
    }

    private func pump() {
        guard !pumping else { return }
        pumping = true
        pumpTask = Task { [weak self] in
            guard let self else { return }
            while !self.pending.isEmpty {
                if Task.isCancelled { break }
                let next = self.pending.removeFirst()
                if let upcoming = self.pending.first {
                    self.prefetch(upcoming)
                }
                await self.speak(next)
            }
            self.pumping = false
            self.pumpTask = nil
            if self.closed || Task.isCancelled {
                self.finishWait()
            } else if !self.pending.isEmpty {
                self.pump()
            }
        }
    }

    private func finishWait() {
        finished = true
        let waiting = waiter
        waiter = nil
        waiting?.resume()
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
