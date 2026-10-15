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
    private(set) var lastCaptureFailure: String?

    var isOnDevice: Bool { recognizer?.supportsOnDeviceRecognition ?? false }

    func start() throws {
        stop()
        lastCaptureFailure = nil
        guard let recognizer, recognizer.isAvailable else { throw ListenerError.unavailable }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.addsPunctuation = true
        if recognizer.supportsOnDeviceRecognition {
            request.requiresOnDeviceRecognition = true
        }

        let engine = AVAudioEngine()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw ListenerError.noInput }

        let levelHandler: @Sendable (Float) -> Void = { [weak self] rms in
            let value = AudioTaps.normalized(rms)
            Task { @MainActor in self?.onLevel?(value) }
        }
        input.installTap(onBus: 0, bufferSize: 1024, format: format,
                         block: AudioTaps.recognitionTap(request: request, level: levelHandler))
        engine.prepare()
        try engine.start()

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
        self.engine = engine
        self.request = request
    }

    /// Record mic audio to a 16 kHz WAV file for Groq Whisper. Levels still flow through `onLevel`.
    func startFileCapture() throws {
        stop()
        lastCaptureFailure = nil
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("jarvis-\(UUID().uuidString).wav")
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw ListenerError.noInput }
        let writer = try PCMFileWriter(source: format, url: url)
        let levelHandler: @Sendable (Float) -> Void = { [weak self] rms in
            let value = AudioTaps.normalized(rms)
            Task { @MainActor in self?.onLevel?(value) }
        }
        input.installTap(onBus: 0, bufferSize: 4096, format: format,
                         block: AudioTaps.fileTap(writer: writer, level: levelHandler))
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            try? FileManager.default.removeItem(at: url)
            throw error
        }
        self.engine = engine
        self.writer = writer
    }

    /// Stops the recording and returns the WAV when it contains audio. The caller deletes the file.
    func stopFileCapture() -> URL? {
        generation += 1
        let writer = self.writer
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
        self.writer = nil
        guard let writer else { return nil }
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

    func stop() {
        generation += 1 // ignore late callbacks from the old task
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        request?.endAudio()
        task?.cancel()
        engine = nil
        request = nil
        task = nil
        if let writer {
            try? FileManager.default.removeItem(at: writer.url)
        }
        self.writer = nil
    }
}
