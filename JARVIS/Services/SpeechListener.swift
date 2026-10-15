import AVFoundation
import Foundation
import Speech

enum ListenerError: LocalizedError {
    case unavailable, noInput
    var errorDescription: String? {
        switch self {
        case .unavailable: "Speech recognition isn't available right now."
        case .noInput: "No microphone input is available."
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
    private var generation = 0

    var isOnDevice: Bool { recognizer?.supportsOnDeviceRecognition ?? false }

    func start() throws {
        stop()
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

    func stop() {
        generation += 1 // ignore late callbacks from the old task
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        request?.endAudio()
        task?.cancel()
        engine = nil
        request = nil
        task = nil
    }
}
