import AVFoundation
import Foundation
import os
import Speech

enum ListenerError: LocalizedError, Equatable {
    case unavailable, noInput, timedOut
    var errorDescription: String? {
        switch self {
        case .unavailable: "Speech recognition isn't available right now."
        case .noInput: "No microphone input is available."
        case .timedOut: "On-device speech recognition took too long."
        }
    }
}

enum SpeechLocales {
    /// First recogniser that can run: saved locale, British English, US English, then the phone locale.
    nonisolated static func recognizer(preferred: String) -> SFSpeechRecognizer? {
        var seen = Set<String>()
        let identifiers = [preferred, "en-GB", "en-US", Locale.current.identifier]
        for identifier in identifiers where seen.insert(identifier).inserted {
            if let recognizer = SFSpeechRecognizer(locale: Locale(identifier: identifier)), recognizer.isAvailable {
                return recognizer
            }
        }
        if let recognizer = SFSpeechRecognizer(), recognizer.isAvailable {
            return recognizer
        }
        return nil
    }

    /// True when an on-device model is missing or rejected. "No speech" stays on device.
    nonisolated static func shouldLeaveOnDevice(_ error: any Error) -> Bool {
        let ns = error as NSError
        if ns.code == 1110 || ns.code == 203 { return false }
        let lower = ns.localizedDescription.lowercased()
        if lower.contains("no speech") || lower.contains("cancel") { return false }
        return true
    }
}

/// Microphone capture + Apple Speech recognition (on-device when the device supports it).
@MainActor
final class SpeechListener {
    var onLevel: ((Double) -> Void)?
    var onBargeLevel: ((Double) -> Void)?
    var onTurn: ((VoiceTurnEvent) -> Void)?
    var onTranscript: ((String, Bool) -> Void)?
    var onError: ((any Error) -> Void)?

    let gate = SpeakerGate()
    private let log = Logger(subsystem: "com.sohail.jarvis", category: "speech")
    private let levels = LevelCoalescer()
    private var allowServerRecognition = false
    private var recognizer: SFSpeechRecognizer? = SFSpeechRecognizer(locale: Locale(identifier: "en-GB")) ?? SFSpeechRecognizer()
    private var engine: AVAudioEngine?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var writer: PCMFileWriter?
    private var generation = 0
    private var tapInstalled = false
    private var voiceProcessingAttempted = false
    private var bargeMonitor = false
    private var liveFeed = false
    private(set) var voiceProcessingEnabled = false
    var inputSampleRate: Double {
        engine?.inputNode.outputFormat(forBus: 0).sampleRate ?? 0
    }

    /// Reads the hardware flag after the engine is running. A failed or bypassed canceller must not barge in.
    func refreshVoiceProcessing() {
        guard let engine else {
            voiceProcessingEnabled = false
            return
        }
        voiceProcessingEnabled = engine.inputNode.isVoiceProcessingEnabled && !engine.inputNode.isVoiceProcessingBypassed
    }
    private(set) var lastCaptureFailure: String?
    private var playbackPlayer: AVAudioPlayerNode?
    var speechBandRatio: Double { gate.speechBandRatio }
    var allowsUtterance: Bool { gate.allowsUtterance }
    var sharedPlayback: AVAudioPlayerNode? { playbackPlayer }
    /// While a hands-free session is up, `stop` leaves the engine running so iOS does not suspend the process.
    var holdEngine = false

    var isOnDevice: Bool { recognizer?.supportsOnDeviceRecognition ?? false }
    var isEngineRunning: Bool { engine?.isRunning ?? false }

    /// Starts a silent input tap when recognition could not, so the process is not suspended.
    func keepEngineAlive() throws {
        if isEngineRunning, tapInstalled { return }
        try installTap(AudioTaps.silentTap(), bufferSize: 1024)
    }

    /// Next listen tries the on-device model again. A failed model stays on the server for this session.
    func resetOnDevicePreference() {
        allowServerRecognition = false
    }

    func start() throws {
        endRecognition()
        discardWriter()
        lastCaptureFailure = nil
        recognizer = SpeechLocales.recognizer(preferred: AppSettings.shared.speechLocale)
        guard let recognizer else { throw ListenerError.unavailable }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.addsPunctuation = true
        // Search-style recognition finalises on a short pause and drops the rest of the sentence.
        request.taskHint = .dictation
        let forcedOnDevice = !allowServerRecognition && recognizer.supportsOnDeviceRecognition
        if forcedOnDevice {
            request.requiresOnDeviceRecognition = true
        }

        let levelHandler = listeningLevel()
        applyVoicePolicy()
        try installTap(AudioTaps.recognitionTap(request: request, gate: gate, level: levelHandler), bufferSize: 1024)

        generation += 1
        let gen = generation
        let handler: @Sendable (String?, Bool, (any Error)?) -> Void = { [weak self] text, isFinal, error in
            Task { @MainActor in
                guard let self, self.generation == gen else { return }
                if let error, text == nil, forcedOnDevice, SpeechLocales.shouldLeaveOnDevice(error) {
                    self.allowServerRecognition = true
                    self.log.error("on-device speech failed; leaving it for this session")
                }
                if let text { self.onTranscript?(text, isFinal) }
                if let error, text == nil { self.onError?(error) }
            }
        }
        task = recognizer.recognitionTask(with: request, resultHandler: AudioTaps.recognitionHandler(handler))
        self.request = request
    }

    /// Record mic audio to a 16 kHz WAV file for Groq Whisper. Levels still flow through `onLevel`.
    func startFileCapture() throws {
        endRecognition()
        discardWriter()
        lastCaptureFailure = nil
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("jarvis-\(UUID().uuidString).wav")
        let engine = try makeEngine()
        let format = engine.inputNode.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw ListenerError.noInput }
        let writer = try PCMFileWriter(source: format, url: url)
        let levelHandler = listeningLevel()
        do {
            applyVoicePolicy()
            try installTap(AudioTaps.fileTap(writer: writer, gate: gate, level: levelHandler), bufferSize: 4096)
        } catch {
            try? FileManager.default.removeItem(at: url)
            throw error
        }
        self.writer = writer
    }

    /// Stops the recording and returns the WAV when it contains audio. The caller deletes the file.
    func stopFileCapture() -> URL? {
        park()
    }

    /// Raw microphone for Gemini Live. Voice processing stays on. The samples are not gated.
    func startLiveFeed(_ onPCM: @escaping @Sendable (Data) -> Void) throws {
        endRecognition()
        discardWriter()
        bargeMonitor = false
        try installTap(AudioTaps.liveFeedTap(onPCM: onPCM, level: listeningLevel()), bufferSize: 480)
        liveFeed = true
        refreshVoiceProcessing()
    }

    func stop() {
        bargeMonitor = false
        liveFeed = false
        _ = park()
    }

    /// While speech is playing, the held engine reports mic level so the user can interrupt.
    func setBargeMonitor(_ enabled: Bool) {
        if liveFeed { return }
        guard enabled != bargeMonitor else { return }
        bargeMonitor = enabled
        guard holdEngine, request == nil, writer == nil else { return }
        if enabled {
            let handler: @Sendable (Float) -> Void = { _ in }
            try? installTap(AudioTaps.bargeTap(gate: gate, level: handler), bufferSize: 1024)
        } else {
            try? installTap(AudioTaps.silentTap(), bufferSize: 1024)
        }
    }

    /// Ends the current recogniser or WAV file. A held engine stays running on a silent tap.
    private func park() -> URL? {
        endRecognition()
        removeTapIfInstalled()
        let url = finalizeWriter()
        if holdEngine {
            try? installTap(AudioTaps.silentTap(), bufferSize: 1024)
        } else {
            teardownEngine()
        }
        return url
    }

    private func endRecognition() {
        generation += 1
        request?.endAudio()
        task?.cancel()
        request = nil
        task = nil
    }

    private func listeningLevel() -> @Sendable (Float) -> Void {
        let levels = self.levels
        return { [weak self] rms in
            let value = AudioTaps.normalized(rms)
            VoiceMeter.shared.level = value
            guard levels.allow() else { return }
            Task { @MainActor in self?.onLevel?(value) }
        }
    }

    private func makeEngine() throws -> AVAudioEngine {
        if let engine { return engine }
        let engine = AVAudioEngine()
        self.engine = engine
        return engine
    }

    private func installTap(_ block: @escaping @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void,
                            bufferSize: AVAudioFrameCount) throws {
        let engine = try makeEngine()
        enableVoiceProcessing(engine)
        removeTapIfInstalled()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw ListenerError.noInput }
        input.installTap(onBus: 0, bufferSize: bufferSize, format: format, block: block)
        tapInstalled = true
        // Attach before start so voice processing's echo reference includes TTS.
        attachPlayback(engine)
        if !engine.isRunning {
            engine.prepare()
            try engine.start()
        }
        refreshVoiceProcessing()
    }

    func applyVoicePolicy() {
        let settings = AppSettings.shared
        let profile = VoiceProfileStore.load()
        let enabled = settings.voiceMatchEnabled && profile != nil
        gate.update(enabled: enabled, profile: profile, threshold: settings.voiceMatchSensitivity.cosineMinimum)
    }

    /// Plays TTS on this engine so voice processing can cancel it from the microphone.
    private func attachPlayback(_ engine: AVAudioEngine) {
        guard playbackPlayer == nil else { return }
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                         sampleRate: 24_000,
                                         channels: 1,
                                         interleaved: false) else { return }
        let player = AVAudioPlayerNode()
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
        playbackPlayer = player
    }

    private func removeTapIfInstalled() {
        guard tapInstalled, let engine else {
            tapInstalled = false
            return
        }
        engine.inputNode.removeTap(onBus: 0)
        tapInstalled = false
    }

    /// Echo cancellation on the long-lived capture engine. Must run before the engine starts.
    private func enableVoiceProcessing(_ engine: AVAudioEngine) {
        guard !voiceProcessingAttempted, !engine.isRunning else { return }
        voiceProcessingAttempted = true
        do {
            try engine.inputNode.setVoiceProcessingEnabled(true)
            engine.inputNode.isVoiceProcessingAGCEnabled = true
            engine.inputNode.isVoiceProcessingBypassed = false
            voiceProcessingEnabled = engine.inputNode.isVoiceProcessingEnabled && !engine.inputNode.isVoiceProcessingBypassed
            LatencyLog.noteVoiceProcessing(voiceProcessingEnabled)
        } catch {
            voiceProcessingEnabled = false
            LatencyLog.noteVoiceProcessing(false)
        }
    }

    private func teardownEngine() {
        removeTapIfInstalled()
        playbackPlayer?.stop()
        if let engine, let playbackPlayer {
            engine.detach(playbackPlayer)
        }
        playbackPlayer = nil
        engine?.stop()
        engine = nil
        voiceProcessingAttempted = false
        voiceProcessingEnabled = false
        bargeMonitor = false
    }

    private func discardWriter() {
        if let writer {
            try? FileManager.default.removeItem(at: writer.url)
        }
        writer = nil
    }

    private func finalizeWriter() -> URL? {
        guard let writer else { return nil }
        self.writer = nil
        let snap = writer.snapshot()
        writer.close()
        if snap.failed && snap.frames == 0 {
            lastCaptureFailure = "Couldn't encode speech as WAV for Groq. JARVIS will use on-device speech."
            try? FileManager.default.removeItem(at: writer.url)
            return nil
        }
        guard snap.frames > 0 else {
            try? FileManager.default.removeItem(at: writer.url)
            return nil
        }
        return writer.url
    }
}
