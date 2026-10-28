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

    private(set) var phase: JarvisPhase = .idle {
        didSet {
            VoiceMeter.shared.phase = phase
            listener.gate.turn.setAssistantSpeaking(phase == .speaking)
        }
    }
    private(set) var level: Double = 0 {
        didSet {
            // Non-zero levels are written on the audio thread. A zero here drops the ring at once.
            if level == 0 { VoiceMeter.shared.level = 0 }
        }
    }
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
    /// The inbound call JARVIS is screening, when one is live.
    private(set) var inboundCall: PhoneCallRecord?
    /// A question from a live call that needs Sohail's answer.
    private(set) var pendingQuestion: CallQuestion?
    /// True while that answer is being sent, so a second tap does not send it twice.
    private(set) var relayingAnswer = false
    /// Latest problem JARVIS reported, when one is waiting in the app.
    private(set) var ownerAlert: OwnerAlert?
    /// Calls shown as cards on the home screen.
    private(set) var deskCalls: [StoredCall] = []
    /// Quote comparisons waiting on the home screen. Booking stays an approval.
    private(set) var hunts: [CallHunt] = []
    /// Inbound call notes. Shown in Calls, then spoken once and marked read.
    private(set) var callMessages: [CallMessage] = []
    /// The message card a notification tap opened.
    private(set) var focusedCallMessageID: String?
    /// False when the Grok assistant webhook is not on the worker. Home chat then answers from here.
    private(set) var grokConnected: Bool?
    @ObservationIgnored private var deliveringCallMessages = false
    @ObservationIgnored private var openingCallMessageID: String?
    @ObservationIgnored private var heardCallMessageIDs: Set<String> = []
    /// The 6-digit code for texting JARVIS. Hidden once that phone is linked.
    private(set) var pairCode = ""
    private(set) var pairNumber = ""
    private(set) var pairLinked = true
    /// True while a spoken away order is still in force.
    private(set) var awayActive = false
    /// True while Busy mode is answering forwarded calls.
    private(set) var busyMode = false
    var interceptor: Bool { inboundCall != nil || awayActive || busyMode }
    var ringLabel: String? {
        if deskCalls.contains(where: { CallDeskStage.of($0) == .dialing }) { return "Dialling" }
        if inboundCall != nil || deskCalls.contains(where: { CallDeskStage.of($0) == .live }) { return "On the call" }
        if busyMode, phase == .idle { return "BUSY" }
        switch phase {
        case .listening: return "LISTENING"
        case .speaking: return "SPEAKING"
        case .thinking: return "THINKING"
        default: return nil
        }
    }
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
    @ObservationIgnored private var screenWatch: Task<Void, Never>?
    @ObservationIgnored private var inboundIDs: Set<String> = []
    /// Call id whose Live Activity the user dismissed. A new call clears it.
    @ObservationIgnored private var dismissedCallActivityID: String?
    @ObservationIgnored private var heardQuestions: Set<String> = []
    @ObservationIgnored private var remindedQuestions: Set<String> = []
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
    /// Partials in the current utterance. The first one must not end the turn.
    @ObservationIgnored private var partialCount = 0
    @ObservationIgnored private var lastPartial = ""
    @ObservationIgnored private var utteranceStarted: Date?
    @ObservationIgnored private var endpointArmed = false
    /// Recognition restarts after Apple Speech closes on a pause. Capped so a stuck final cannot spin.
    @ObservationIgnored private var recognitionRestarts = 0
    /// Words already accepted before the recogniser restarted. A new partial must not replace them.
    @ObservationIgnored private var heardPrefix = ""
    /// Speech must last this long before silence is allowed to end it.
    private let minimumUtteranceSeconds: Double = 0.8
    /// Sentences still being spoken for the current streamed reply. Cancelled on barge-in.
    @ObservationIgnored private var spokenQueue: SpokenQueue?
    /// Speaks "Right." only when the real reply is still silent after 1.2 seconds.
    @ObservationIgnored private var fillerTask: Task<Void, Never>?
    @ObservationIgnored private var fillerIndex = 0
    /// Enrolment owns the microphone. Wake and hands-free listening stay down until it finishes.
    @ObservationIgnored private var enrollmentHold = false
    @ObservationIgnored private var resumeSessionAfterEnrollment = false
    /// Gemini Live owns VAD, turns, and tools. A failed open stays on screen instead of pretending to listen.
    @ObservationIgnored private var usingGeminiLive = false
    @ObservationIgnored private var geminiLive: GeminiLiveSession?
    @ObservationIgnored private var liveReconnects = 0
    @ObservationIgnored private var liveReopening = false
    /// Exactly "Gemini Live connected" or "Fallback: <error>" once a session has tried the live path.
    private(set) var voiceLink: String?
    @ObservationIgnored private var lastLiveFailure: String?
    @ObservationIgnored private var debugClient: CloudClient?
    @ObservationIgnored private var sharedPersona = ""
    @ObservationIgnored private var brainVoiceID = "JBFqnCBsd6RMkjVDRZzb"

    /// Quiet after the latest words, only for the unused file-capture path. Live turns use the meter.
    private var endpointPause: Duration {
        let seconds = min(1.2, max(0.8, AppSettings.shared.endpointSilence))
        return .milliseconds(Int((seconds * 1000).rounded()))
    }

    /// off → connecting → listening ↔ userSpeaking → thinking → aiSpeaking → listening.
    /// Mute drops into muted. Barge-in is 300 ms of the user's own speech, and only while echo cancellation is on.
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
        listener.gate.turn.setHandler { [weak self] event in
            Task { @MainActor in self?.handleTurn(event) }
        }
        tools.onComposeMessage = { [weak self] draft in self?.messageDraft = draft }
        tools.onComposeMail = { [weak self] draft in self?.mailDraft = draft }
        output.bindVoiceGate(listener.gate)
        ContactDirectory.shared.warm()
        HTTPConnections.prewarm()
        Task { await self.mergeSharedHistory() }
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
            if usingGeminiLive || phase == .listening { listener.stop() }
            userIsSpeaking = false
        } else if isSessionActive, usingGeminiLive {
            let live = geminiLive
            try? listener.startLiveFeed { [weak live] pcm in
                live?.sendAudio(pcm)
            }
            phase = .listening
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
            output.yieldMicrophone()
            do {
                try listener.start()
            } catch {
                isDictating = false
                reply = ""
                if let listenerError = error as? ListenerError, listenerError == .noInput {
                    errorMessage = JarvisLines.voiceUnavailable
                } else if error is ListenerError {
                    errorMessage = JarvisLines.speechUnavailable
                } else {
                    errorMessage = JarvisLines.explain(error)
                }
                sessionLog.error("dictation failed: \(error.localizedDescription, privacy: .public)")
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
        listener.gate.turn.reset()
        listener.gate.turn.setPause(AppSettings.shared.endpointSilence)
        listener.gate.turn.setSensitivity(AppSettings.shared.vadSensitivity)
        listener.gate.turn.setEagerness(AppSettings.shared.turnEagerness)
        HTTPConnections.prewarm()
        output.prewarm()
        publishControlState()

        let activityOK = beginLiveActivity()
        let inBackground = UIApplication.shared.applicationState != .active
        if !activityOK && inBackground {
            // Activating the mic with no Live Activity makes AudioRecordingIntent kill the process.
            sessionLog.error("Live Activity missing in background; not activating the microphone")
            if AppSettings.shared.liveActivityEnabled {
                errorMessage = "Turn on Live Activities for JARVIS so the Action Button can listen in the Dynamic Island."
            }
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
            _ = beginLiveActivity()
        }
        groqTranscriptionBroken = false
        fileCaptureBroken = false
        listenRetries = 0
        listener.resetOnDevicePreference()
        interrupt()
        guard epoch == sessionEpoch, isSessionActive else { return .failed }
        lastLiveFailure = nil
        voiceLink = "Connecting…"
        phase = .listening
        pushActivity()
        if await beginGeminiLive(epoch: epoch) {
            voiceConnecting = false
            voiceLink = "Gemini Live connected"
        } else if epoch == sessionEpoch, isSessionActive {
            let why = lastLiveFailure ?? "Gemini Live did not connect"
            voiceLink = "Fallback: \(why)"
            phase = .listening
            voiceConnecting = false
            try? listener.keepEngineAlive()
        } else {
            return .failed
        }
        if let debugClient {
            let status = await VoiceDebugLog.deliver(debugClient)
            annotateDebug(status)
        }
        if voiceLink?.hasPrefix("Fallback:") == true {
            phase = .listening
            pushActivity()
            return .started
        }
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
        let wasSession = isSessionActive
        sessionEpoch += 1
        sessionLog.info("endSession \(reason, privacy: .public)")
        if usingGeminiLive {
            VoiceDebugLog.note("live-close", reason)
        }
        usingGeminiLive = false
        geminiLive?.stop()
        geminiLive = nil
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
        if !wasSession, let id = activeCallID() {
            dismissedCallActivityID = id
        }
        await LiveActivityManager.shared.end(finalState: activityState)
        refreshCallActivity()
        publishControlState()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        audioConfigured = false
        listener.resetOnDevicePreference()
        refreshWake()
        if let debugClient {
            let status = await VoiceDebugLog.deliver(debugClient)
            annotateDebug(status)
        }
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

    /// Typed request. The home chat uses the assistant webhook. Other screens keep the on-device brain.
    func ask(_ text: String, agent: Bool = false) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if !Reachability.shared.online {
            OfflineQueue.shared.enqueue(trimmed)
            errorMessage = "I'm offline, sir. I'll send that when the line is back."
            reply = ""
            phase = .idle
            level = 0
            return
        }
        LatencyLog.beginTurn("text-turn")
        Task {
            let session = AVAudioSession.sharedInstance()
            do {
                let ready = session.category == .playAndRecord && session.mode == .voiceChat
                if !ready {
                    try Self.configureVoiceSession(session)
                }
                try session.setActive(true)
                if session.isInputGainSettable {
                    try? session.setInputGain(1)
                }
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
            turnTask = Task { await respond(to: trimmed, agent: agent) }
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

    private func hearingAllowed() -> Bool {
        AudioTaps.speechAuthorizationStatus() == .authorized
            && AVAudioApplication.shared.recordPermission == .granted
    }

    /// Clears a previous reply so the denied line is what stays on screen.
    private func showHearingDenied(needsSettings: Bool) {
        reply = ""
        errorMessage = needsSettings ? JarvisLines.microphoneDenied : JarvisLines.microphoneClosed
    }

    /// True when the microphone is already allowed and the playAndRecord session is active.
    /// This path does not suspend, so a control's `perform()` can start the engine before it returns.
    private func activateAudioIfAuthorized() -> Bool {
        guard hearingAllowed() else { return false }
        return activateAudioSession()
    }

    /// Permission prompts only happen in the foreground. A control launch must not `await` before the
    /// Live Activity exists, and must not activate the session when that activity is missing.
    private func activateAudio() async -> Bool {
        if !hearingAllowed() {
            guard UIApplication.shared.applicationState == .active else {
                showHearingDenied(needsSettings: false)
                return false
            }
            let speech = await AudioTaps.requestSpeechAuthorization()
            let micGranted = await AVAudioApplication.requestRecordPermission()
            guard speech == .authorized, micGranted else {
                showHearingDenied(needsSettings: true)
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
        // 10 ms buffers keep barge-in and the first TTS buffer from waiting on a large chunk.
        try? session.setPreferredSampleRate(48_000)
        try? session.setPreferredIOBufferDuration(0.01)
    }

    /// Category first, then activate. A live engine is left alone: setCategory mid-playback stops the voice.
    private func activateAudioSession() -> Bool {
        let session = AVAudioSession.sharedInstance()
        let live = listener.isEngineRunning || phase == .speaking
        if applyVoiceSession(session, allowReconfigure: !live) {
            return true
        }
        if live {
            VoiceDebugLog.note("session", "left the audio session alone during playback")
            return session.category == .playAndRecord
        }
        sessionLog.error("AVAudioSession failed; retrying after deactivate")
        try? session.setActive(false, options: .notifyOthersOnDeactivation)
        audioConfigured = false
        if applyVoiceSession(session, allowReconfigure: true) {
            return true
        }
        errorMessage = JarvisLines.voiceUnavailable
        reply = ""
        return false
    }

    private func applyVoiceSession(_ session: AVAudioSession, allowReconfigure: Bool) -> Bool {
        do {
            let categoryReady = session.category == .playAndRecord && session.mode == .voiceChat
            if !categoryReady {
                guard allowReconfigure else { return false }
                try Self.configureVoiceSession(session)
            } else if !allowReconfigure && audioConfigured {
                return true
            }
            if allowReconfigure {
                let rate = session.sampleRate
                if rate == 0 || abs(rate - 48_000) > 50 {
                    try? session.setPreferredSampleRate(48_000)
                    try? session.setPreferredIOBufferDuration(0.01)
                }
            }
            try session.setActive(true)
            if session.isInputGainSettable {
                try? session.setInputGain(1)
            }
            audioConfigured = true
            errorMessage = nil
            if !categoryReady {
                sessionLog.info("AVAudioSession active playAndRecord voiceChat")
            }
            return true
        } catch {
            sessionLog.error("AVAudioSession failed: \(error.localizedDescription, privacy: .public)")
            audioConfigured = false
            return false
        }
    }

    private func interrupt() {
        silenceTask?.cancel()
        fillerTask?.cancel()
        fillerTask = nil
        spokenQueue?.cancel()
        spokenQueue = nil
        turnTask?.cancel()
        turnTask = nil
        output.stop()
        cloudExecuting = false
    }

    private func beginListening(manual: Bool) {
        if usingGeminiLive {
            voiceConnecting = false
            phase = .listening
            pushActivity()
            return
        }
        LatencyLog.clear()
        listener.gate.turn.reset()
        listener.gate.turn.setPause(AppSettings.shared.endpointSilence)
        listener.gate.turn.setSensitivity(AppSettings.shared.vadSensitivity)
        listener.gate.turn.setEagerness(AppSettings.shared.turnEagerness)
        listener.gate.turn.noteTranscript("")
        manualTurn = manual
        transcript = ""
        heardVoice = false
        heardPrefix = ""
        loudFrames = 0
        captureMeter = 0
        captureFile = false
        partialCount = 0
        lastPartial = ""
        utteranceStarted = nil
        endpointArmed = false
        recognitionRestarts = 0
        userIsSpeaking = false
        voiceConnecting = false
        output.yieldMicrophone()
        guard activateAudioSession() else {
            listener.holdEngine = false
            listener.stop()
            phase = .idle
            pushActivity()
            return
        }
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
            listener.refreshVoiceProcessing()
            listener.gate.turn.setEchoCancelled(listener.voiceProcessingEnabled)
            let rate = Int(listener.inputSampleRate.rounded())
            VoiceDebugLog.note("listen", "aec \(listener.voiceProcessingEnabled ? "on" : "off") rate \(rate)")
            phase = .listening
            listenRetries = 0
            errorMessage = nil
        } catch {
            sessionLog.error("beginListening failed: \(error.localizedDescription, privacy: .public)")
            let permanent = error as? ListenerError == .unavailable || error as? ListenerError == .noInput
            let canRetry = !permanent && isSessionActive && isContinuous && listenRetries < 3
            if permanent {
                reply = ""
                errorMessage = (error as? ListenerError) == .noInput
                    ? JarvisLines.voiceUnavailable
                    : JarvisLines.speechUnavailable
            } else if canRetry {
                try? listener.keepEngineAlive()
                listenRetries += 1
                let attempt = listenRetries
                sessionLog.info("retrying recognition \(attempt)")
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(500))
                    // A successful start zeroes listenRetries, so this retry does not interrupt it.
                    guard self.isSessionActive, self.listenRetries == attempt else { return }
                    self.beginListening(manual: false)
                }
            } else if isSessionActive {
                try? listener.keepEngineAlive()
                errorMessage = JarvisLines.missedSpeech
            } else {
                errorMessage = JarvisLines.explain(error)
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
        // A whole-file Whisper upload starts only after the recording stops. Live turns use
        // streaming recognition so the reply can begin when the meter hears the pause.
        false
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
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            if isFinal, !transcript.isEmpty {
                holdListen()
            } else if isFinal, isSessionActive, isContinuous {
                sessionLog.info("empty recognition result; restarting listen")
                beginListening(manual: false)
            }
            return
        }
        let combined = Self.joinHeard(heardPrefix, trimmed)
        let changed = combined != lastPartial
        lastPartial = combined
        transcript = combined
        listener.gate.turn.noteTranscript(combined)
        userIsSpeaking = true
        if utteranceStarted == nil { utteranceStarted = Date() }
        if changed {
            partialCount += 1
            recognitionRestarts = 0
        }
        guard !manualTurn else { return }
        // The turn meter ends the pause. A recogniser final only restarts capture and keeps the words.
        if isFinal {
            heardPrefix = combined
            VoiceDebugLog.note("recognition-final", "kept \(combined.count) characters")
            holdListen()
        }
        pushActivity()
    }

    /// A restarted recogniser reports only the new words. The earlier phrase stays in front.
    private static func joinHeard(_ prefix: String, _ next: String) -> String {
        if prefix.isEmpty { return next }
        if next.isEmpty { return prefix }
        if next.hasPrefix(prefix) { return next }
        return prefix + " " + next
    }

    private func handleListenerError(_ error: any Error) {
        if wakeArmed, !isSessionActive {
            beginWakeRecognition()
            return
        }
        guard phase == .listening else { return }
        // A closed recogniser must not cut the sentence off. The turn meter ends it.
        if !transcript.isEmpty {
            holdListen()
            return
        }
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

    /// Restarts recognition without wiping the words already heard, so a pause can still grow.
    private func holdListen() {
        guard isSessionActive, phase == .listening, !microphoneMuted, !captureFile else { return }
        guard recognitionRestarts < 8 else {
            VoiceDebugLog.note("recognition-restart", "cap")
            return
        }
        recognitionRestarts += 1
        VoiceDebugLog.note("recognition-restart", "pass \(recognitionRestarts)")
        do {
            try listener.start()
        } catch {
            sessionLog.error("keepListening failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Adaptive endpoint. Each new partial cancels the previous wait.
    private func armEndpoint() {
        endpointArmed = true
        silenceTask?.cancel()
        let pause = endpointPause
        let minimum = minimumUtteranceSeconds
        silenceTask = Task { [weak self] in
            try? await Task.sleep(for: pause)
            guard let self, !Task.isCancelled, self.phase == .listening else { return }
            let started = self.utteranceStarted ?? Date()
            let age = Date().timeIntervalSince(started)
            if age < minimum {
                let rest = minimum - age
                try? await Task.sleep(for: .milliseconds(Int((rest * 1000).rounded(.up))))
                guard !Task.isCancelled, self.phase == .listening else { return }
            }
            if !self.captureFile {
                let trimmed = self.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.count < 2 { return }
            }
            self.finishUtterance()
        }
    }

    private func finishUtterance() {
        if usingGeminiLive { return }
        guard phase == .listening else { return }
        silenceTask?.cancel()
        let heard = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        if heard.count < 2 {
            LatencyLog.noteFalseTrigger()
            userIsSpeaking = false
            transcript = ""
            lastPartial = ""
            partialCount = 0
            return
        }
        heardPrefix = ""
        LatencyLog.noteSpeechEndIfNeeded()
        LatencyLog.event("speech-end")
        VoiceDebugLog.note("end-of-turn", "characters \(heard.count)")
        phase = .thinking
        level = 0
        pushActivity()
        armReplyFiller()
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
            errorMessage = JarvisLines.explain(error)
            sessionLog.error("transcription failed: \(error.localizedDescription, privacy: .public)")
            reply = ""
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

    /// Gemini Live when the worker can mint a token. A failure stays visible. It does not start Apple Speech.
    private func beginGeminiLive(epoch: Int) async -> Bool {
        await mergeSharedHistory()
        guard JarvisCloud.isConfigured, let client = try? JarvisCloudAPI.client() else {
            debugClient = nil
            noteLiveError("cloud not configured")
            return false
        }
        debugClient = client
        VoiceDebugLog.use(client)
        liveReconnects = 0
        liveReopening = false
        guard let connected = await connectLive(client: client, epoch: epoch) else { return false }
        return installLive(connected.session, modality: connected.modality, window: connected.window, epoch: epoch)
    }

    private func liveInstruction() -> String {
        let identity: String
        if sharedPersona.isEmpty {
            identity = AppSettings.shared.systemPrompt(facts: JarvisStore.allFacts())
        } else {
            identity = sharedPersona
        }
        var memory = ""
        for turn in conversation.suffix(12) {
            let text = turn.content.trimmingCharacters(in: .whitespacesAndNewlines)
            if text.isEmpty { continue }
            let who = turn.role == "assistant" ? "JARVIS" : "Master Hadi"
            if !memory.isEmpty { memory += "\n" }
            memory += "\(who): \(text)"
        }
        let recent = memory.isEmpty ? "" : "\nRecent conversation, including texts and calls:\n\(memory)\n"
        return identity + recent + """

        This is a live conversation. Speak in one to three short sentences. No markdown, lists, or emojis.
        The server hears normal speech and decides when the user has finished. Do not ask them to repeat unless the transcript is empty.
        You can place a Twilio call with place_outbound_call, shop for quotes with shop_around, book a quote with book_quote, send an SMS with send_sms, create a reminder with reminder_create, and read the briefing with get_briefing.
        Calls, shop dialling, bookings, and texts wait for the Approve button. Never say a call is ringing or a text has been sent until the tool result says it happened.
        Calls you place speak for Master Hadi, never Sohail. Do not use the iPhone dialler.
        """
    }

    private func connectLive(client: CloudClient, epoch: Int) async -> (session: GeminiLiveSession, modality: LiveModality, window: String)? {
        guard epoch == sessionEpoch else { return nil }
        let instruction = liveInstruction()
        let tools = LiveWire.declarations(from: ToolCatalog.liveDefinitions(settings: AppSettings.shared))
        let session = GeminiLiveSession()
        session.onEffect = { [weak self] effect in
            Task { @MainActor in
                self?.handleLive(effect)
            }
        }
        let textTicket = await client.liveTicket()
        guard epoch == sessionEpoch else { return nil }
        guard case .ready(let first) = textTicket, let textURL = URL(string: first.websocketURL) else {
            let reason: String
            if case .unavailable(let why) = textTicket {
                reason = why
            } else {
                reason = "token"
            }
            noteLiveError(reason)
            return nil
        }
        var modality = LiveModality.text
        var window = first.sessionExpiresAt ?? first.expiresAt ?? ""
        var opened = await openLive(session, url: textURL, instruction: instruction, tools: tools, modality: .text, client: client, epoch: epoch)
        if opened == .textRejected {
            noteLiveError("text modality rejected")
            let audioTicket = await client.liveTicket()
            guard epoch == sessionEpoch, case .ready(let second) = audioTicket, let audioURL = URL(string: second.websocketURL) else {
                noteLiveError("audio token")
                return nil
            }
            modality = .audioTranscript
            window = second.sessionExpiresAt ?? second.expiresAt ?? window
            opened = await openLive(session, url: audioURL, instruction: instruction, tools: tools, modality: .audioTranscript, client: client, epoch: epoch)
        }
        guard opened == .ready, epoch == sessionEpoch, isSessionActive else {
            session.stop()
            if case .failed(let reason) = opened {
                noteLiveError(reason)
            } else if opened == .textRejected {
                noteLiveError("modality")
            }
            return nil
        }
        return (session, modality, window)
    }

    /// One setup, then one fresh token if the socket or setup fails. The token itself is never logged.
    private func openLive(
        _ session: GeminiLiveSession,
        url: URL,
        instruction: String,
        tools: [JSONValue],
        modality: LiveModality,
        client: CloudClient,
        epoch: Int
    ) async -> LiveOpenResult {
        var opened = await session.open(url: url, instruction: instruction, tools: tools, modality: modality)
        if case .failed(let reason) = opened {
            noteLiveError(reason)
            let retry = await client.liveTicket()
            guard epoch == sessionEpoch, case .ready(let ticket) = retry, let retryURL = URL(string: ticket.websocketURL) else {
                return opened
            }
            opened = await session.open(url: retryURL, instruction: instruction, tools: tools, modality: modality)
        }
        return opened
    }

    private func installLive(_ session: GeminiLiveSession, modality: LiveModality, window: String, epoch: Int) -> Bool {
        do {
            try listener.startLiveFeed { [weak session] pcm in
                session?.sendAudio(pcm)
            }
        } catch {
            session.stop()
            noteLiveError("microphone")
            noteCapturePath()
            return false
        }
        guard epoch == sessionEpoch, isSessionActive else {
            session.stop()
            listener.stop()
            VoiceDebugLog.note("live-close", "cancelled")
            return false
        }
        geminiLive = session
        usingGeminiLive = true
        output.bindSharedPlayer(listener.sharedPlayback)
        output.prewarm()
        phase = .listening
        let mode = modality == .text ? "text" : "audio-transcript"
        VoiceDebugLog.note("live-open", "\(mode) session \(window)")
        noteCapturePath()
        pushActivity()
        return true
    }

    private func noteCapturePath() {
        let permission: String
        switch AVAudioApplication.shared.recordPermission {
        case .granted: permission = "granted"
        case .denied: permission = "denied"
        default: permission = "undetermined"
        }
        VoiceDebugLog.note("mic-permission", permission)
        let route = AVAudioSession.sharedInstance().currentRoute
        let inputs = route.inputs.map(\.portType.rawValue).joined(separator: "+")
        let outputs = route.outputs.map(\.portType.rawValue).joined(separator: "+")
        let rate = Int(listener.inputSampleRate.rounded())
        let mic = microphoneMuted ? "muted" : "open"
        let aec = listener.voiceProcessingEnabled ? "on" : "off"
        VoiceDebugLog.note("audio-route", "mic \(mic) in \(inputs) out \(outputs) hz \(rate) aec \(aec)")
    }

    private func reopenLive() async {
        guard usingGeminiLive, liveReconnects < 1, let client = try? JarvisCloudAPI.client() else {
            liveReopening = false
            fallBackFromLive("reconnect")
            return
        }
        liveReconnects += 1
        VoiceDebugLog.use(client)
        let epoch = sessionEpoch
        geminiLive?.stop()
        guard let connected = await connectLive(client: client, epoch: epoch) else {
            liveReopening = false
            fallBackFromLive("reconnect")
            return
        }
        liveReopening = false
        if !installLive(connected.session, modality: connected.modality, window: connected.window, epoch: epoch) {
            fallBackFromLive("reconnect")
        }
    }

    private func handleLive(_ effect: LiveEffect) {
        guard usingGeminiLive else { return }
        switch effect {
        case .ready:
            break
        case .speak(let text):
            enqueueLiveSpeech(text)
        case .interrupt:
            VoiceDebugLog.note("barge-in", "live")
            stopLivePlayback()
        case .speechStart:
            userIsSpeaking = true
            stopLivePlayback()
            pushActivity()
        case .speechEnd:
            userIsSpeaking = false
            LatencyLog.noteSpeechEnd()
            VoiceDebugLog.note("turn-complete", "activity-end")
            pushActivity()
        case .user(let text):
            transcript = text
            userIsSpeaking = true
            pushActivity()
        case .userFinal(let text):
            transcript = text
            VoiceDebugLog.note("input-transcript", text)
            _ = recordUser(text)
            let heard = text
            Task { await self.shareTurn(role: "user", text: heard) }
            pushActivity()
        case .tool(let id, let name, let arguments):
            Task { await self.answerLiveTool(id: id, name: name, arguments: arguments) }
        case .failed(let reason):
            if liveReopening { return }
            let recoverable = reason == "goaway" || reason == "socket" || reason == "audio send"
            if recoverable, liveReconnects < 1 {
                liveReopening = true
                noteLiveError(reason)
                Task { await self.reopenLive() }
            } else {
                fallBackFromLive(reason)
            }
        }
    }

    private func enqueueLiveSpeech(_ text: String) {
        let parsed = MemoryParser.extract(from: text)
        if AppSettings.shared.autoRemember {
            rememberFacts(parsed.facts)
        }
        let spoken = parsed.cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !spoken.isEmpty else { return }
        recordAssistant(spoken)
        let shared = spoken
        Task { await self.shareTurn(role: "assistant", text: shared) }
        if spokenQueue == nil {
            spokenQueue = SpokenQueue(
                speak: { [weak self] line in
                    guard let self, self.usingGeminiLive else { return }
                    self.phase = .speaking
                    self.reply = line
                    self.pushActivity()
                    await self.speak(line, voiceID: self.brainVoiceID)
                    if self.usingGeminiLive, self.phase == .speaking {
                        self.phase = .listening
                        self.pushActivity()
                    }
                },
                prefetch: { [weak self] line in
                    guard let self else { return }
                    let settings = AppSettings.shared
                    guard let key = KeychainStore.get(.elevenLabs) else { return }
                    self.output.prefetch(text: line, voiceID: self.brainVoiceID, apiKey: key,
                                         stability: settings.stability, similarity: settings.similarity)
                }
            )
        }
        spokenQueue?.add(spoken)
    }

    private func stopLivePlayback() {
        spokenQueue?.cancel()
        spokenQueue = nil
        output.stop()
        fillerTask?.cancel()
        fillerTask = nil
        if phase == .speaking || phase == .thinking {
            phase = .listening
        }
        userIsSpeaking = true
        pushActivity()
    }

    private func answerLiveTool(id: String, name: String, arguments: String) async {
        guard usingGeminiLive else { return }
        statusLine = "Using \(name.replacingOccurrences(of: "_", with: " "))…"
        pushActivity()
        let call = ToolCall(id: id, name: name, arguments: arguments)
        let outcome = await tools.execute(call, settings: AppSettings.shared)
        let result: String
        switch outcome {
        case .result(let text):
            result = text
        case .confirm(let action):
            pendingAction = action
            pendingSummary = action.summary
            result = "Nothing has been sent or dialled. Tell the user to tap Approve on the iPhone. Do not claim it is done."
        }
        if name == "shop_around" || name == "book_quote" || name == "place_outbound_call" {
            if let client = try? JarvisCloudAPI.client(), let rows = try? await client.callHunts() {
                hunts = rows
            }
        }
        statusLine = nil
        geminiLive?.sendToolResult(id: id, name: name, result: result)
        pushActivity()
    }

    private func noteLiveError(_ reason: String) {
        let clean = VoiceDebugLog.safe(reason)
        let short = clean.isEmpty ? "unavailable" : String(clean.prefix(80))
        lastLiveFailure = short
        VoiceDebugLog.note("live-error", short)
    }

    private func annotateDebug(_ status: Int) {
        if status == -1 || status == 204 { return }
        if (200..<300).contains(status) { return }
        let suffix = status == 0 ? " · debug unreachable" : " · debug HTTP \(status)"
        guard let link = voiceLink else { return }
        if link.contains("debug ") { return }
        voiceLink = String((link + suffix).prefix(140))
    }

    /// Pulls the phone line's persona and history into this conversation. Existing lines stay.
    private func mergeSharedHistory() async {
        guard JarvisCloud.isConfigured, let client = try? JarvisCloudAPI.client() else { return }
        if let persona = await client.brainPersona() {
            let text = persona.persona.trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { sharedPersona = text }
            if persona.voiceID == "JBFqnCBsd6RMkjVDRZzb" {
                brainVoiceID = "JBFqnCBsd6RMkjVDRZzb"
            }
        }
        guard let history = await client.brainHistory() else { return }
        for turn in history.turns {
            let role = turn.role == "assistant" ? "assistant" : "user"
            let text = turn.body.trimmingCharacters(in: .whitespacesAndNewlines)
            if text.isEmpty { continue }
            let known = conversation.contains { item in item.role == role && item.content == text }
            if known { continue }
            conversation.append(ChatMessage(role: role, content: text))
            let shown = turns.contains { item in item.role == role && item.text == text }
            if !shown {
                turns.append(VoiceTurn(role: role, text: text))
            }
        }
    }

    private func shareTurn(role: String, text: String) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let client: CloudClient?
        if let debugClient {
            client = debugClient
        } else {
            client = try? JarvisCloudAPI.client()
        }
        guard let client else { return }
        await client.brainLine(source: "app", role: role, text: trimmed)
    }

    private func fallBackFromLive(_ reason: String) {
        guard usingGeminiLive else { return }
        liveReopening = false
        usingGeminiLive = false
        geminiLive?.stop()
        geminiLive = nil
        spokenQueue?.cancel()
        spokenQueue = nil
        output.stop()
        listener.stop()
        noteLiveError(reason)
        VoiceDebugLog.note("live-close", "fallback")
        let why = lastLiveFailure ?? "unavailable"
        voiceLink = "Fallback: \(why)"
        phase = .listening
        voiceConnecting = false
        try? listener.keepEngineAlive()
        pushActivity()
        let client = debugClient
        Task {
            guard let client else { return }
            let status = await VoiceDebugLog.deliver(client)
            self.annotateDebug(status)
        }
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
            await speakLine(JarvisLines.explain(error), userText: name)
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

    private func speakLine(_ line: String, userText: String, voiceID: String = "", share: Bool = true) async {
        reply = line
        recordAssistant(line)
        saveForWidget(transcript: userText, reply: line)
        await say(ResponsesClient.spokenText(line), voiceID: voiceID)
        if share {
            await shareTurn(role: "user", text: userText)
            await shareTurn(role: "assistant", text: line)
        }
    }

    /// Home text chat. The same brain as the phone line answers.
    private func deliverAgentChat(userText: String) async {
        statusLine = "JARVIS is thinking…"
        phase = .thinking
        errorMessage = nil
        pushActivity()
        await answerFromHere(userText)
    }

    /// Home chat. The worker answers from the shared persona and history.
    private func answerFromHere(_ userText: String) async {
        await mergeSharedHistory()
        if JarvisCloud.isConfigured, let client = try? JarvisCloudAPI.client() {
            if let spoken = await client.brainSay(userText) {
                if spoken.voiceID == "JBFqnCBsd6RMkjVDRZzb" {
                    brainVoiceID = "JBFqnCBsd6RMkjVDRZzb"
                }
                errorMessage = nil
                await speakLine(spoken.reply, userText: userText, voiceID: brainVoiceID, share: false)
                return
            }
        }
        let facts = JarvisStore.allFacts()
        var system = AppSettings.shared.voicePrompt(facts: facts, question: userText)
        if !sharedPersona.isEmpty {
            system = sharedPersona + "\n" + system
        }
        await deliverCloudOrFallback(userText: userText, system: system, history: conversation, user: userText)
    }

    /// Weather, news, facts and nearby questions are answered on the worker in one spoken line.
    private func deliverLiveAnswer(userText: String) async -> Bool {
        guard JarvisCloud.isConfigured, let client = try? JarvisCloudAPI.client() else { return false }
        let here = WebKnowledge.needsHere(userText) ? await DeviceLocation.shared.fix() : nil
        let facts = JarvisStore.allFacts()
        var system = AppSettings.shared.voicePrompt(facts: facts, question: userText)
            + " Answer in one or two spoken sentences. Give the fact itself. Do not say you will search or look it up. Do not read URLs or list links."
        if !sharedPersona.isEmpty {
            system = sharedPersona + "\n" + system
        }
        var messages: [[String: String]] = [["role": "system", "content": system]]
        for turn in conversation.suffix(8) {
            let role = turn.role == "assistant" ? "assistant" : "user"
            let content = turn.content.trimmingCharacters(in: .whitespacesAndNewlines)
            if !content.isEmpty { messages.append(["role": role, "content": content]) }
        }
        messages.append(["role": "user", "content": userText])
        guard let line = await client.converse(messages: messages, location: here) else { return false }
        if Self.isSearchPromise(line) { return false }
        errorMessage = nil
        citations = []
        await speakLine(line, userText: userText, voiceID: brainVoiceID)
        guard !Task.isCancelled else { return true }
        afterTurn()
        return true
    }

    /// A short promise to go and search, with no fact in it.
    private static func isSearchPromise(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count < 140 else { return false }
        let lower = trimmed.lowercased()
        let starts = lower.hasPrefix("i'll") || lower.hasPrefix("i will") || lower.hasPrefix("let me")
            || lower.hasPrefix("i'm going to") || lower.hasPrefix("i am going to")
        guard starts else { return false }
        return lower.contains("search") || lower.contains("look that up") || lower.contains("look it up")
            || lower.contains("look this up") || lower.contains("google")
    }

    /// On-device keys are optional. The worker holds Gemini and Groq, and a failed turn still gets a spoken line.
    private func deliverCloudOrFallback(userText: String, system: String, history: [ChatMessage], user: String) async {
        var messages: [[String: String]] = [["role": "system", "content": system]]
        for turn in history.suffix(16) {
            let role = turn.role == "assistant" ? "assistant" : "user"
            let content = turn.content.trimmingCharacters(in: .whitespacesAndNewlines)
            if !content.isEmpty { messages.append(["role": role, "content": content]) }
        }
        let asked = user.trimmingCharacters(in: .whitespacesAndNewlines)
        if !asked.isEmpty { messages.append(["role": "user", "content": asked]) }
        if JarvisCloud.isConfigured, let client = try? JarvisCloudAPI.client() {
            if let line = await client.converse(messages: messages) {
                errorMessage = nil
                await speakLine(line, userText: userText)
                return
            }
        }
        if let endpoint = try? AppSettings.shared.resolvedEndpoint() {
            var chat: [ChatMessage] = [ChatMessage(role: "system", content: system)]
            for turn in messages.dropFirst() {
                let role = turn["role"] ?? "user"
                let content = turn["content"] ?? ""
                if !content.isEmpty { chat.append(ChatMessage(role: role, content: content)) }
            }
            if let line = try? await LLMClient.complete(messages: chat, endpoint: endpoint) {
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    errorMessage = nil
                    await speakLine(trimmed, userText: userText)
                    return
                }
            }
        }
        errorMessage = nil
        await speakLine("I'm here, sir. I couldn't reach my notes just now. Ask me again in a moment.", userText: userText)
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

    private func respond(to text: String, agent: Bool = false) async {
        await mergeSharedHistory()
        phase = .thinking
        statusLine = agent ? "JARVIS is thinking…" : nil
        errorMessage = nil
        reply = ""
        pushActivity()

        // Tool cards stay tap-only. Spoken words do not approve them.
        if pendingAction != nil {
            afterTurn()
            return
        }
        // A briefed phone call is the one approval that also accepts a spoken yes or no.
        if pendingCallBrief != nil {
            await resolvePendingCallBrief(text)
            return
        }
        if AwayCommand.matches(text) {
            await applyAway(text)
            return
        }
        if let waiting = deskCalls.first(where: { $0.delegationStatus == "awaiting_decision" }) {
            await sendDecision(waiting.id, choice: text)
            await speakLine("Right away, Sir.", userText: text)
            guard !Task.isCancelled else { return }
            afterTurn()
            return
        }
        if let question = pendingQuestion {
            let answer = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !answer.isEmpty else {
                afterTurn()
                return
            }
            if !relayingAnswer {
                relayingAnswer = true
                Task { await self.sendCallAnswer(question, answer) }
                await speakLine("I'll tell them, sir.", userText: text)
            }
            guard !Task.isCancelled else { return }
            afterTurn()
            return
        }

        spokenSoFar = ""
        utteranceBeingSpoken = ""
        turnAssistantStored = false
        let recordedUser = recordUser(text)

        if await resolveBriefChoice(text) { return }
        if await handleBriefedCall(text) { return }

        if let delegation = AgentStore.shared.delegation(in: text) {
            let agent = delegation.agent
            let goal = delegation.goal
            let ack: String
            if agent.id == "agent_jarvis" {
                ack = await AgentStore.shared.startMission(goal: goal)
            } else {
                ack = "\(agent.name) is on that."
                Task { await AgentStore.shared.delegate(agent: agent, goal: goal) }
            }
            recordAssistant(ack)
            saveForWidget(transcript: text, reply: ack)
            await say(ResponsesClient.spokenText(ack), voiceID: agent.voiceID)
            guard !Task.isCancelled else { return }
            afterTurn()
            return
        }

        if await handleShopAround(text) { return }
        if await resolveCallChoice(text) { return }
        if await handleLocalCall(text) { return }
        callChoices = []

        if agent {
            await deliverAgentChat(userText: text)
            guard !Task.isCancelled else { return }
            afterTurn()
            return
        }

        if wantsCloudTool(text) && CloudMonitor.shared.hasRunningWork {
            cloudExecuting = true
        }
        let liveQuestion = WebKnowledge.needsLiveFacts(text) || NewsPulse.wants(text)
        if liveQuestion, !Self.needsTools(text), !wantsCloudTool(text), !isBriefingRequest(text),
           !DeepResearch.wants(text), !ImageStudio.wants(text) {
            if await deliverLiveAnswer(userText: text) { return }
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

        let facts = JarvisStore.allFacts()
        let prior = recordedUser ? Array(conversation.dropLast()) : conversation
        let history = Array(prior.suffix(16))
        var cloudSystem = settings.voicePrompt(facts: facts, question: text)
        if !sharedPersona.isEmpty {
            cloudSystem = sharedPersona + "\n" + cloudSystem
        }
        do {
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
            sessionLog.error("turn failed: \(error.localizedDescription, privacy: .public)")
            await deliverCloudOrFallback(userText: text, system: cloudSystem, history: history, user: text)
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
            let answer = try await ResponsesClient.answer(
                input: history + [user],
                instructions: system + "\n\nSearch the web when the answer may have changed recently. "
                    + "Reply with the answer itself in one or two spoken sentences. "
                    + "Do not say you will search or look it up. No URLs, no markdown, no list of links.",
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
        let spokenBrief = Self.spokenBrief(brief)
        let who = name == number ? number : name
        let line = "I'll call \(who) and tell them \(spokenBrief). I'll introduce myself as JARVIS, Master Hadi's assistant. Say yes, sir, or no to cancel."
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
        statusLine = "Placing the call, Sir."
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
        case .failed:
            CallLogStore.add(StoredCall.local(
                name: brief.contactName, number: brief.number, brief: brief.brief,
                status: "failed", detail: "The call could not be placed.", spoken: true))
            callLogTick += 1
            await speakLine("I couldn't place that call, sir. I'll try again when you ask.", userText: userText)
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

    /// The approval line stays one sentence. A long brief is cut on a word, never with an ellipsis.
    private static func spokenBrief(_ brief: String) -> String {
        let clean = brief.replacingOccurrences(of: "…", with: " ").replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if clean.count <= 280 { return clean }
        let cut = String(clean.prefix(280))
        guard let space = cut.lastIndex(of: " "), cut.distance(from: cut.startIndex, to: space) > 40 else { return cut }
        var base = String(cut[..<space])
        if let last = base.last, ",:;".contains(last) { base.removeLast() }
        return base
    }

    private func placeBrief(_ brief: PendingCallBrief) async -> CallPlaceResult {
        guard JarvisCloud.isConfigured else { return .notSetUp }
        do {
            let client = try JarvisCloudAPI.client()
            return await client.placeOutboundCall(to: brief.number, contactName: brief.contactName, brief: brief.brief)
        } catch {
            return .failed(JarvisLines.explain(error))
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

    func noteGrok(_ connected: Bool) {
        grokConnected = connected
    }

    /// Opens one saved call and reads the butler line aloud. A notification tap uses this.
    func openCallMessage(_ id: String) {
        let clean = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard clean.hasPrefix("cmsg_") else { return }
        focusedCallMessageID = clean
        if CallMessageLink.pendingID == clean { CallMessageLink.pendingID = nil }
        guard openingCallMessageID != clean else { return }
        openingCallMessageID = clean
        heardCallMessageIDs.insert(clean)
        Task {
            await self.presentFocusedCallMessage(clean)
            if self.openingCallMessageID == clean { self.openingCallMessageID = nil }
        }
    }

    /// Shows the full card without reading it again. The Calls list uses this.
    func showCallMessage(_ id: String) {
        guard id.hasPrefix("cmsg_") else { return }
        focusedCallMessageID = id
    }

    func dismissFocusedCallMessage() {
        focusedCallMessageID = nil
    }

    /// Unread call notes. Speaks each one, shows the card, then marks it read.
    func deliverCallMessages() {
        guard appInForeground, !deliveringCallMessages else { return }
        deliveringCallMessages = true
        Task {
            defer { self.deliveringCallMessages = false }
            await self.speakUnreadCallMessages()
        }
    }

    func refreshCallMessages() {
        Task { await self.loadRecentCallMessages() }
    }

    func startScreenWatch() {
        guard screenWatch == nil else { return }
        screenWatch = Task { [weak self] in
            while !Task.isCancelled {
                await self?.pullInbound()
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }

    func decideDesk(_ id: String, choice: String) {
        Task { await self.sendDecision(id, choice: choice) }
    }

    func chooseHunt(_ huntID: String, quoteID: String) {
        Task { await self.sendHuntChoice(huntID, quoteID) }
    }

    func startShop(_ huntID: String) {
        Task { await self.sendShopStart(huntID) }
    }

    func removeShopQuote(_ huntID: String, quoteID: String) {
        Task { await self.sendShopRemoval(huntID, quoteID) }
    }

    func refreshPairing() {
        Task { await self.loadPairing(refresh: true) }
    }

    func setBusyMode(_ on: Bool) {
        busyMode = on
        VoiceMeter.shared.interceptor = interceptor
    }

    func playRecording(_ id: String) {
        Task { await self.playCallRecording(id) }
    }

    private func refreshDesk() {
        let now = Date()
        let rows = CallLogStore.entries().filter { call in
            let stage = CallDeskStage.of(call)
            if stage != .ended { return true }
            if call.delegationStatus == "awaiting_decision" || call.callbackNeeded == true { return true }
            return now.timeIntervalSince(call.updatedAt) < 60 * 60
        }
        let live = rows.filter { CallDeskStage.of($0) != .ended }
        let held = rows.filter { CallDeskStage.of($0) == .ended && ($0.callbackNeeded == true || $0.delegationStatus == "awaiting_decision") }
        let recent = rows.filter { call in
            CallDeskStage.of(call) == .ended && call.callbackNeeded != true && call.delegationStatus != "awaiting_decision"
        }
        deskCalls = Array((live + held + recent).prefix(3))
        VoiceMeter.shared.interceptor = interceptor
    }

    private func applyAway(_ text: String) async {
        let active = (try? await JarvisCloudAPI.client().setAway(text)) ?? false
        awayActive = active
        VoiceMeter.shared.interceptor = interceptor
        let line = active ? "I'll answer your calls, Sir." : "I'll leave the phone to you, Sir."
        recordAssistant(line)
        await speakLine(line, userText: text)
        guard !Task.isCancelled else { return }
        afterTurn()
    }

    private func loadPairing(refresh: Bool) async {
        guard let client = try? JarvisCloudAPI.client() else { return }
        guard let ticket = try? await client.pairingTicket(refresh: refresh) else { return }
        pairCode = ticket.code
        pairNumber = ticket.number
        pairLinked = ticket.paired
    }

    private func sendHuntChoice(_ huntID: String, _ quoteID: String) async {
        guard let client = try? JarvisCloudAPI.client() else { return }
        statusLine = await client.chooseHunt(huntID: huntID, quoteID: quoteID) ?? "I couldn't hold that one, Sir."
        if let rows = try? await client.callHunts() {
            hunts = rows
        }
    }

    private func sendShopStart(_ huntID: String) async {
        guard let client = try? JarvisCloudAPI.client() else { return }
        statusLine = (try? await client.startShop(huntID: huntID)) ?? "I couldn't start those calls, Sir."
        if let rows = try? await client.callHunts() {
            hunts = rows
        }
    }

    private func sendShopRemoval(_ huntID: String, _ quoteID: String) async {
        guard let client = try? JarvisCloudAPI.client() else { return }
        guard let hunt = hunts.first(where: { $0.id == huntID }) else { return }
        let providers = hunt.quotes.filter { $0.id != quoteID }.map { ["business": $0.business, "phone": $0.phone] }
        statusLine = (try? await client.replaceShop(huntID: huntID, providers: providers)) ?? "I couldn't change that list, Sir."
        if let rows = try? await client.callHunts() {
            hunts = rows
        }
    }

    /// Quotes from chat use the same worker list as a text. Nothing is rung until the list is started.
    private func handleShopAround(_ text: String) async -> Bool {
        if ShopAround.approves(text), let hunt = hunts.first(where: { $0.status == "comparing" }) {
            let quote = hunt.quotes.first { $0.id == hunt.recommendedId && $0.status == "quoted" }
                ?? hunt.quotes.first { $0.status == "quoted" }
            guard let quote else { return false }
            guard let client = try? JarvisCloudAPI.client() else {
                await sayShop("The JARVIS cloud isn't configured. Add the backend URL and app token in Settings, JARVIS Cloud.", userText: text)
                return true
            }
            let message = await client.chooseHunt(huntID: hunt.id, quoteID: quote.id) ?? "I couldn't hold that one, Sir."
            if let rows = try? await client.callHunts() { hunts = rows }
            await sayShop(message, userText: text)
            return true
        }
        let draft = hunts.first { $0.status == "draft" }
        let editing = draft != nil && (ShopAround.confirms(text) || (!ShopAround.phones(in: text).isEmpty && !ShopAround.matches(text)))
        guard ShopAround.matches(text) || editing else { return false }
        guard let client = try? JarvisCloudAPI.client() else {
            await sayShop("The JARVIS cloud isn't configured. Add the backend URL and app token in Settings, JARVIS Cloud.", userText: text)
            return true
        }
        let message: String
        if let draft, ShopAround.confirms(text) {
            message = (try? await client.startShop(huntID: draft.id)) ?? "I couldn't start those calls, Sir."
        } else if let draft, !ShopAround.phones(in: text).isEmpty, !ShopAround.matches(text) {
            message = (try? await client.replaceShop(huntID: draft.id, providers: ShopAround.providers(in: text))) ?? "I couldn't change that list, Sir."
        } else {
            let providers = shopContacts(text) + ShopAround.providers(in: text)
            message = (try? await client.createShop(goal: text, providers: providers)) ?? "I couldn't start that comparison, Sir."
        }
        if let rows = try? await client.callHunts() { hunts = rows }
        await sayShop(message, userText: text)
        return true
    }

    private func shopContacts(_ goal: String) -> [[String: String]] {
        var rows: [[String: String]] = []
        for hit in ContactDirectory.shared.hits(matching: goal).prefix(5) {
            guard let phone = hit.bestPhone, !phone.isEmpty, !BriefedCall.isEmergency(phone) else { continue }
            rows.append(["business": hit.name, "phone": phone])
            if rows.count >= 5 { break }
        }
        return rows
    }

    private func sayShop(_ line: String, userText: String) async {
        recordAssistant(line)
        await speakLine(line, userText: userText)
        guard !Task.isCancelled else { return }
        afterTurn()
    }

    private func sendDecision(_ id: String, choice: String) async {
        guard let client = try? JarvisCloudAPI.client() else { return }
        if let call = deskCalls.first(where: { $0.id == id }), call.delegationStatus != "awaiting_decision" {
            let result = await client.placeOutboundCall(to: call.number, contactName: call.displayName, brief: call.brief)
            if case .placed(let record) = result {
                absorb(record, announce: false)
                Task { await self.pollCall(id: record.id) }
            }
            return
        }
        guard await client.decideCall(id: id, choice: choice) else { return }
        if let record = try? await client.outboundCall(id: id) {
            absorb(record, announce: false)
        }
    }

    private func playCallRecording(_ id: String) async {
        guard let client = try? JarvisCloudAPI.client(), let data = try? await client.recordingData(id: id) else {
            statusLine = "The recording isn't ready yet, Sir."
            return
        }
        if !CallPlayback.shared.play(data) {
            statusLine = "I couldn't play that recording, Sir."
        }
    }

    func answerPendingQuestion(_ text: String) {
        guard let question = pendingQuestion, !relayingAnswer else { return }
        let answer = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !answer.isEmpty else { return }
        relayingAnswer = true
        Task { await self.sendCallAnswer(question, answer) }
    }

    private func sendCallAnswer(_ question: CallQuestion, _ text: String) async {
        defer { relayingAnswer = false }
        guard let client = try? JarvisCloudAPI.client() else {
            errorMessage = "Calling isn't set up yet, sir."
            return
        }
        let result = await client.answerCallQuestion(callId: question.callId, questionId: question.id, text: text)
        switch result {
        case .failed(let message), .notSetUp(let message):
            statusLine = message
            errorMessage = message
            if pendingQuestion == nil { pendingQuestion = question }
        case .done:
            if pendingQuestion?.id == question.id { pendingQuestion = nil }
            errorMessage = nil
        }
    }

    private func pullQuestions(_ client: CloudClient) async {
        guard let questions = try? await client.callQuestions() else { return }
        if let pending = questions.first(where: { $0.status == "pending" }) {
            if pendingQuestion?.id != pending.id {
                pendingQuestion = pending
            }
            if !heardQuestions.contains(pending.id), await announceQuestion(pending.question) {
                heardQuestions.insert(pending.id)
            }
        } else {
            pendingQuestion = nil
        }
        for row in questions where row.status == "timed_out" {
            let known = CallLogStore.entries().first { $0.id == row.callId }
            if known?.callbackNeeded != true, let record = try? await client.outboundCall(id: row.callId, refresh: false) {
                absorb(record, announce: false)
            }
            if !remindedQuestions.contains(row.id), await remindFollowUp(row.question) {
                remindedQuestions.insert(row.id)
            }
        }
    }

    private func pullOwnerAlerts(_ client: CloudClient) async {
        guard let alerts = try? await client.ownerAlerts() else { return }
        ownerAlert = alerts.first { alert in
            guard let parsed = CloudTime.date(alert.createdAt) else { return false }
            return Date().timeIntervalSince(parsed) < 12 * 60 * 60
        }
    }

    private func announceQuestion(_ question: String) async -> Bool {
        guard phase == .idle || phase == .listening else { return false }
        let line = "Sir, they asked: \(question). What should I tell them?"
        recordAssistant(line)
        await say(line)
        guard !Task.isCancelled else { return true }
        afterTurn()
        return true
    }

    private func remindFollowUp(_ question: String) async -> Bool {
        guard phase == .idle || phase == .listening else { return false }
        let line = "They asked \(question). I said you would get back to them, sir."
        recordAssistant(line)
        await say(line)
        guard !Task.isCancelled else { return true }
        afterTurn()
        return true
    }

    func decideInbound(_ action: String) {
        guard let id = inboundCall?.id else { return }
        Task { await self.sendScreen(id: id, action: action) }
    }

    func allowInboundPersonal(_ allow: Bool) {
        guard let id = inboundCall?.id else { return }
        let note = CallPrivacyStore.note(matching: inboundCall)
        Task { await self.sendPersonal(id: id, allow: allow, note: note) }
    }

    private func speakUnreadCallMessages() async {
        guard appInForeground else { return }
        guard JarvisCloud.isConfigured, let client = try? JarvisCloudAPI.client() else { return }
        var spoke = false
        var passes = 0
        while appInForeground, passes < 3 {
            passes += 1
            guard let unread = try? await client.unreadCallMessages() else { return }
            let fresh = unread.filter { !heardCallMessageIDs.contains($0.id) }
            if fresh.isEmpty { break }
            for message in fresh where !callMessages.contains(where: { $0.id == message.id }) {
                callMessages.insert(message, at: 0)
            }
            for message in fresh {
                guard !heardCallMessageIDs.contains(message.id) else { continue }
                guard appInForeground, !Task.isCancelled else { return }
                await waitToSpeak()
                guard appInForeground, !Task.isCancelled else { return }
                let line = message.spoken.trimmingCharacters(in: .whitespacesAndNewlines)
                let spoken = line.isEmpty ? "Sir, you have a message." : line
                await speakLine(spoken, userText: "")
                errorMessage = nil
                spoke = true
                heardCallMessageIDs.insert(message.id)
                let saved = await client.markCallMessageRead(id: message.id)
                if !saved { heardCallMessageIDs.remove(message.id) }
            }
        }
        guard spoke, !Task.isCancelled else { return }
        afterTurn()
    }

    private func presentFocusedCallMessage(_ id: String) async {
        guard JarvisCloud.isConfigured, let client = try? JarvisCloudAPI.client() else {
            heardCallMessageIDs.remove(id)
            return
        }
        let direct = try? await client.callMessage(id: id)
        let cached = callMessages.first(where: { $0.id == id })
        let recent = (try? await client.recentCallMessages())?.first(where: { $0.id == id })
        guard let message = direct ?? cached ?? recent else {
            heardCallMessageIDs.remove(id)
            return
        }
        if let index = callMessages.firstIndex(where: { $0.id == message.id }) {
            callMessages[index] = message
        } else {
            callMessages.insert(message, at: 0)
        }
        focusedCallMessageID = message.id
        let deadline = Date().addingTimeInterval(8)
        while !appInForeground, Date() < deadline {
            try? await Task.sleep(for: .milliseconds(150))
        }
        guard appInForeground, !Task.isCancelled else { return }
        await waitToSpeak()
        guard !Task.isCancelled else { return }
        let line = message.spoken.trimmingCharacters(in: .whitespacesAndNewlines)
        await speakLine(line.isEmpty ? "Sir, you have a message." : line, userText: "")
        errorMessage = nil
        let saved = await client.markCallMessageRead(id: message.id)
        if !saved { heardCallMessageIDs.remove(message.id) }
        guard !Task.isCancelled else { return }
        afterTurn()
    }

    private func loadRecentCallMessages() async {
        guard let client = try? JarvisCloudAPI.client() else { return }
        guard let rows = try? await client.recentCallMessages() else { return }
        var merged = rows
        for local in callMessages where !merged.contains(where: { $0.id == local.id }) {
            merged.insert(local, at: 0)
        }
        callMessages = merged
    }

    private func waitToSpeak() async {
        let deadline = Date().addingTimeInterval(12)
        while Date() < deadline {
            if phase == .idle || phase == .listening { return }
            try? await Task.sleep(for: .milliseconds(300))
        }
    }

    private func pullInbound() async {
        guard JarvisCloud.isConfigured, let client = try? JarvisCloudAPI.client() else { return }
        await CallPrivacyStore.syncIfNeeded()
        await CallDevice.uploadIfNeeded()
        await pullQuestions(client)
        await pullOwnerAlerts(client)
        if let rows = try? await client.callHunts() {
            hunts = rows
        }
        await loadPairing(refresh: false)
        if let config = try? await client.callingConfig() {
            grokConnected = config.assistantWebhook ?? false
        }
        if let gate = try? await client.interceptorState() {
            busyMode = gate.busy
        }
        if let away = try? await client.awayStatus() {
            awayActive = away.active
        }
        VoiceMeter.shared.interceptor = interceptor
        await DevicePresence.shared.postIfDue()
        guard let calls = try? await client.activeInboundCalls() else { return }
        let seen = Set(calls.map(\.id))
        for record in calls {
            absorb(record, announce: false)
            if !inboundIDs.contains(record.id) {
                inboundIDs.insert(record.id)
                let name = record.callerName?.isEmpty == false ? (record.callerName ?? "someone") : "someone"
                Task { await self.announceScreen(name) }
            }
        }
        let gone = inboundIDs.subtracting(seen)
        for id in gone {
            inboundIDs.remove(id)
            if let record = try? await client.outboundCall(id: id) {
                absorb(record, announce: true)
            }
        }
        inboundCall = calls.first
        refreshDesk()
        refreshCallActivity()
    }

    private func announceScreen(_ name: String) async {
        guard phase == .idle || phase == .listening else { return }
        let line = "Sir, \(name) is calling. I'm screening it."
        recordAssistant(line)
        saveForWidget(transcript: name, reply: line)
        await say(line)
        guard !Task.isCancelled else { return }
        afterTurn()
    }

    private func sendScreen(id: String, action: String) async {
        guard let client = try? JarvisCloudAPI.client() else {
            errorMessage = "Calling isn't set up yet, sir."
            return
        }
        let result = await client.screenCall(id: id, action: action)
        await pullInbound()
        switch result {
        case .notSetUp(let message), .failed(let message):
            statusLine = message
            errorMessage = message
        case .done:
            errorMessage = nil
            if action == "listen" {
                statusLine = "Live transcript is on this iPhone. Take over rings your mobile."
            }
        }
    }

    private func sendPersonal(id: String, allow: Bool, note: String) async {
        guard let client = try? JarvisCloudAPI.client() else { return }
        _ = await client.setCallPersonal(id: id, allow: allow, note: allow ? note : "")
        await pullInbound()
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
        refreshDesk()
        refreshCallActivity()
        guard shouldSpeak else { return }
        let name = stored.displayName
        let summary = stored.summary.isEmpty ? stored.detail : stored.summary
        let status = stored.status
        let inbound = stored.direction == "inbound"
        Task { await self.speakCallReport(name: name, summary: summary, status: status, inbound: inbound) }
    }

    private func speakCallReport(name: String, summary: String, status: String, inbound: Bool = false) async {
        let line = inbound
            ? CallReport.inbound(name: name, summary: summary, status: status)
            : CallReport.spoken(name: name, summary: summary, status: status)
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
        if !usingGeminiLive {
            listener.stop()
        }
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
        if usingGeminiLive, let client = try? JarvisCloudAPI.client(), let rows = try? await client.callHunts() {
            hunts = rows
        }
        recordAssistant(result)
        await say(result)
        guard !Task.isCancelled else { return }
        afterTurn()
    }

    func shortcutReturned(_ status: String) {
        statusLine = status == "shortcut-done" ? "Shortcut finished." : "Shortcut didn't complete."
    }

    /// Speaks a finished agent result in that agent's ElevenLabs voice when a session is listening.
    func speakAgentLine(_ text: String, voiceID: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard phase == .listening else {
            postAgentUpdate(trimmed)
            return
        }
        Task { @MainActor in
            self.recordAssistant(trimmed)
            self.saveForWidget(transcript: "Agent", reply: trimmed)
            await self.say(trimmed, voiceID: voiceID)
            self.afterTurn()
        }
    }

    private func say(_ text: String, voiceID: String = "") async {
        guard !Task.isCancelled else { return }
        utteranceBeingSpoken = text
        output.preparePlayback()
        phase = .speaking
        pushActivity()
        await speak(text, voiceID: voiceID)
        if !Task.isCancelled {
            spokenSoFar = Self.joinSpoken(spokenSoFar, text)
            utteranceBeingSpoken = ""
        }
    }

    private func speak(_ text: String, voiceID: String = "") async {
        let monitor = !listener.isEngineRunning && !microphoneMuted
        listener.refreshVoiceProcessing()
        listener.gate.turn.setEchoCancelled(listener.voiceProcessingEnabled)
        let mic = microphoneMuted ? "mic-muted" : "mic-open"
        VoiceDebugLog.note("tts-start", "george \(mic)")
        defer { VoiceDebugLog.note("tts-stop", "george \(mic)") }
        if listener.isEngineRunning, !microphoneMuted, !usingGeminiLive {
            listener.setBargeMonitor(true)
        }
        defer { listener.setBargeMonitor(false) }
        let s = AppSettings.shared
        guard let key = KeychainStore.get(.elevenLabs) else {
            await output.speakDevice(text)
            return
        }
        let voice = voiceID.isEmpty ? s.voiceID : voiceID
        var last: Error?
        for attempt in 0..<2 {
            do {
                try await output.speakElevenLabs(text: text, voiceID: voice, apiKey: key,
                                                 stability: s.stability, similarity: s.similarity,
                                                 monitorMicrophone: monitor)
                errorMessage = nil
                return
            } catch {
                if Task.isCancelled { return }
                last = error
                if attempt == 0 {
                    try? await Task.sleep(for: .milliseconds(400))
                }
            }
        }
        sessionLog.error("ElevenLabs failed: \(last?.localizedDescription ?? "", privacy: .public)")
        await output.speakDevice(text)
    }

    /// Covers a slow model or a slow voice stream. Cancelled as soon as reply audio starts.
    private func armReplyFiller() {
        fillerTask?.cancel()
        fillerTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(SemanticTurn.fillerAfterMs))
            guard let self, !Task.isCancelled else { return }
            guard !LatencyLog.replyAudioHeard else { return }
            guard self.phase == .thinking || self.phase == .speaking else { return }
            LatencyLog.noteFiller()
            await self.output.speakFiller(self.nextFiller())
        }
    }

    private func nextFiller() -> String {
        let lines = ["Right.", "One moment.", "Yes."]
        let line = lines[fillerIndex % lines.count]
        fillerIndex += 1
        return line
    }

    func voiceDebugSnapshot() -> (latency: LatencySnapshot, meter: VoiceTurnSnapshot) {
        (LatencyLog.snapshot(), listener.gate.turn.snapshot())
    }

    private func handleTurn(_ event: VoiceTurnEvent) {
        switch event {
        case .speechBegan:
            guard phase == .listening else { return }
            userIsSpeaking = true
            if utteranceStarted == nil { utteranceStarted = Date() }
            silenceTask?.cancel()
            endpointArmed = false
            VoiceDebugLog.note("speech-began", listener.voiceProcessingEnabled ? "aec on" : "aec off")
            pushActivity()
        case .endOfTurn:
            guard phase == .listening, !manualTurn else { return }
            LatencyLog.noteSpeechEnd()
            finishUtterance()
        case .barge:
            bargeIn()
        case .ignoredBurst:
            LatencyLog.noteFalseTrigger()
            VoiceDebugLog.note("ignored-burst", "short")
            if phase == .listening {
                userIsSpeaking = false
            }
        }
    }

    private func noteBarge(_ value: Double) {
        // Barge-in is the turn meter's 150ms speech decision. Loudness here used to trip on the television.
        _ = value
    }

    /// Mic energy during playback: stop the voice immediately and listen.
    private func bargeIn() {
        if usingGeminiLive { return }
        guard phase == .speaking else { return }
        guard listener.voiceProcessingEnabled else {
            VoiceDebugLog.note("barge-blocked", "echo cancellation is off")
            return
        }
        sessionLog.info("barge-in")
        VoiceDebugLog.note("barge", "stopped playback")
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
        let outcome = await NewsPulse.run(question: userText, persona: persona) { _ in }
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
        var spoken = JarvisLines.briefingFailed
        for attempt in 0..<2 {
            do {
                let briefing = try await JarvisCloudAPI.client().briefing()
                spoken = CloudSpeech.briefing(briefing)
                await CloudMonitor.shared.refresh()
                errorMessage = nil
                break
            } catch {
                if Task.isCancelled { return }
                sessionLog.error("briefing failed: \(error.localizedDescription, privacy: .public)")
                errorMessage = JarvisLines.briefingFailed
                if attempt == 0 {
                    try? await Task.sleep(for: .milliseconds(400))
                }
            }
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
        let date = Date.now.formatted(date: .complete, time: .shortened)
        var brief = system + " Today is \(date). Answer now in one or two spoken sentences. Give the fact itself. "
            + "Do not say you will search, look it up, or check. Do not read URLs or list links."
        if WebKnowledge.needsHere(user.content) {
            if let here = await DeviceLocation.shared.fix() {
                brief += " The user is nearby latitude \(String(format: "%.3f", here.lat)), longitude \(String(format: "%.3f", here.lon)). Do not read the coordinates aloud."
                if let weather = await DeviceLocation.weatherLine(latitude: here.lat, longitude: here.lon) {
                    brief += " Observed weather: \(weather)."
                }
            } else {
                brief += " Location is not available. If the question needs where the user is, say so in one sentence. Do not invent a city."
            }
        }
        if let key = KeychainStore.get(.gemini), !key.isEmpty {
            let models = Self.groundModels()
            var index: Int = 0
            while index < models.count {
                let model = models[index]
                do {
                    let streamed = try await streamedGrounded(model: model, apiKey: key, system: brief,
                                                             history: history, user: user)
                    let trimmed = streamed.text.trimmingCharacters(in: .whitespacesAndNewlines)
                    if trimmed.isEmpty || Self.isSearchPromise(trimmed) { throw LLMError.emptyReply(provider: "Gemini") }
                    return Produced(text: trimmed, spoken: streamed.spoken)
                } catch {
                    if Task.isCancelled { throw error }
                    let retryOther = Self.groundingRejected(error)
                    if !retryOther { break }
                    index += 1
                }
            }
        }
        let notes = await FreeWebSearch.gather(query: user.content)
        let noteBlock = notes.context.isEmpty
            ? "No live notes arrived. If the fact may have changed, say you could not confirm it."
            : "Live notes:\n\(notes.context)\nUse these notes. Do not invent newer numbers."
        let informed = brief + "\n\n" + noteBlock
            + "\nReply with the answer only. Do not say you will search. Do not list links."
        let speaker = AppSettings.shared.fastGroqEndpoint()
            ?? AppSettings.shared.conversationalEndpoint(from: endpoint)
        let streamed = try await streamedChat(system: informed, history: history, user: user, endpoint: speaker)
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
            let isBreak: Bool = ch == "." || ch == "!" || ch == "?"
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
        output.yieldMicrophone()
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
        let enrolled = AppSettings.shared.voiceMatchEnabled && VoiceProfileStore.hasProfile
        let floor: Double = enrolled ? 0.30 : 0.12
        let bandFloor: Double = enrolled ? 0.35 : 0.18
        let band: Double = listener.speechBandRatio
        let speakerOK: Bool = listener.allowsUtterance
        let speaking = captureMeter > floor && band >= bandFloor && speakerOK
        if speaking {
            if utteranceStarted == nil { utteranceStarted = Date() }
            loudFrames += 1
            // The first loud frame is not the end of the sentence.
            guard loudFrames >= 2 else { return }
            heardVoice = true
            userIsSpeaking = true
            silenceTask?.cancel()
            endpointArmed = false
            return
        }
        guard heardVoice else {
            loudFrames = 0
            return
        }
        let age = Date().timeIntervalSince(utteranceStarted ?? Date())
        guard age >= minimumUtteranceSeconds, !endpointArmed else { return }
        LatencyLog.noteSpeechEnd()
        armEndpoint()
    }

    func applyLiveActivityPreference() {
        if !AppSettings.shared.liveActivityEnabled {
            Task { await LiveActivityManager.shared.end(finalState: self.activityState) }
            return
        }
        if isSessionActive {
            _ = beginLiveActivity()
            pushActivity()
        } else {
            refreshCallActivity()
        }
    }

    private func beginLiveActivity() -> Bool {
        guard AppSettings.shared.liveActivityEnabled else { return false }
        return LiveActivityManager.shared.start(state: activityState)
    }

    private var activityState: JarvisActivityAttributes.ContentState {
        .init(phase: phase, transcript: String(transcript.suffix(90)), reply: String(reply.prefix(140)), callStatus: callActivityLine())
    }

    private func activeCallID() -> String? {
        if let inboundCall { return inboundCall.id }
        return CallLogStore.openCalls().first?.id
    }

    private func callActivityLine() -> String {
        if let call = inboundCall {
            let name = call.callerName?.isEmpty == false ? (call.callerName ?? "Incoming call") : "Incoming call"
            return "\(name) · \(Self.callPhaseLabel(call.status))"
        }
        guard let open = CallLogStore.openCalls().first else { return "" }
        return "\(open.displayName) · \(open.titleStatus)"
    }

    private static func callPhaseLabel(_ status: String) -> String {
        switch status {
        case "screening": "Screening"
        case "listening": "Listening"
        case "handling": "JARVIS handling"
        case "message": "Taking a message"
        case "connecting": "Connecting you"
        case "placing": "Placing"
        case "ringing": "Ringing"
        case "in_progress": "On the call"
        case "wrapping": "Finishing"
        default: "On the call"
        }
    }

    /// Shows an active call on the Lock Screen when a voice session is not already up.
    private func refreshCallActivity() {
        guard AppSettings.shared.liveActivityEnabled else { return }
        let id = activeCallID()
        if id == nil { dismissedCallActivityID = nil }
        if let id, id == dismissedCallActivityID { return }
        if isSessionActive {
            pushActivity()
            return
        }
        let line = callActivityLine()
        if line.isEmpty {
            guard LiveActivityManager.shared.isRunning else { return }
            let state = activityState
            Task { await LiveActivityManager.shared.end(finalState: state) }
            return
        }
        let state = JarvisActivityAttributes.ContentState(phase: .idle, transcript: "", reply: "", callStatus: line)
        if LiveActivityManager.shared.isRunning {
            Task { await LiveActivityManager.shared.update(state) }
        } else {
            _ = LiveActivityManager.shared.start(state: state)
        }
    }

    private func pushActivity() {
        guard AppSettings.shared.liveActivityEnabled, isSessionActive else { return }
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
