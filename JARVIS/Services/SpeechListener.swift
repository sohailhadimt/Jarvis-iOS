import AVFoundation
import Foundation
import Speech

enum ListenerError: LocalizedError {
    case unavailable, noInput, timedOut
    var errorDescription: String? {
        switch self {
        case .unavailable: "Speech recognition isn't available right now."
        case .noInput: "No microphone input is available."
        case .timedOut: "On-device speech recognition took too long."
        }
    }
}

/// Microphone capture + Apple Speech recognition (on-device when the device supports it).
@MainActor
final class SpeechListener {
    var onLevel: ((Double) -> Void)?
    var onTranscript: ((String, Bool) -> Void)?
    var onError: ((any Error) -> Void)?

    private let recognizer: SFSpeechRecognizer? = SFSpeechRecognizer(locale: Locale(identifier: "en-GB")) ?? SFSpeechRecognizer()
    private var engine: AVAudioEngine?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var writer: PCMFileWriter?
    private var generation = 0
    private var tapInstalled = false
    private(set) var lastCaptureFailure: String?
    /// While a hands-free session is up, `stop` leaves the engine running so iOS does not suspend the process.
    var holdEngine = false

    var isOnDevice: Bool { recognizer?.supportsOnDeviceRecognition ?? false }
    var isEngineRunning: Bool { engine?.isRunning ?? false }

    /// Starts a silent input tap when recognition could not, so the process is not suspended.
    func keepEngineAlive() throws {
        if isEngineRunning, tapInstalled { return }
        try installTap(AudioTaps.silentTap(), bufferSize: 1024)
    }

    func start() throws {
        endRecognition()
        discardWriter()
        lastCaptureFailure = nil
        guard let recognizer, recognizer.isAvailable else { throw ListenerError.unavailable }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.addsPunctuation = true
        if recognizer.supportsOnDeviceRecognition {
            request.requiresOnDeviceRecognition = true
        }

        let levelHandler: @Sendable (Float) -> Void = { [weak self] rms in
            let value = AudioTaps.normalized(rms)
            Task { @MainActor in self?.onLevel?(value) }
        }
        try installTap(AudioTaps.recognitionTap(request: request, level: levelHandler), bufferSize: 1024)

        generation += 1
        let gen = generation
        let handler: @Sendable (String?, Bool, (any Error)?) -> Void = { [weak self] text, isFinal, error in
            Task { @MainActor in
                guard let self, self.generation == gen else { return }
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
        let levelHandler: @Sendable (Float) -> Void = { [weak self] rms in
            let value = AudioTaps.normalized(rms)
            Task { @MainActor in self?.onLevel?(value) }
        }
        do {
            try installTap(AudioTaps.fileTap(writer: writer, level: levelHandler), bufferSize: 4096)
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

    func stop() {
        _ = park()
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

    private func makeEngine() throws -> AVAudioEngine {
        if let engine { return engine }
        let engine = AVAudioEngine()
        self.engine = engine
        return engine
    }

    private func installTap(_ block: @escaping @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void,
                            bufferSize: AVAudioFrameCount) throws {
        let engine = try makeEngine()
        removeTapIfInstalled()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw ListenerError.noInput }
        input.installTap(onBus: 0, bufferSize: bufferSize, format: format, block: block)
        tapInstalled = true
        if !engine.isRunning {
            engine.prepare()
            try engine.start()
        }
    }

    private func removeTapIfInstalled() {
        guard tapInstalled, let engine else {
            tapInstalled = false
            return
        }
        engine.inputNode.removeTap(onBus: 0)
        tapInstalled = false
    }

    private func teardownEngine() {
        removeTapIfInstalled()
        engine?.stop()
        engine = nil
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
