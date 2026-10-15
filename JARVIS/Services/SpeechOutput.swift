import AVFoundation
import Foundation

/// Speaks replies: ElevenLabs streaming PCM through AVAudioEngine, or AVSpeechSynthesizer as a fallback.
@MainActor
final class SpeechOutput: NSObject {
    var onLevel: ((Double) -> Void)?

    private let synth = AVSpeechSynthesizer()
    private var synthContinuation: CheckedContinuation<Void, Never>?
    private var fakeLevelTask: Task<Void, Never>?

    private var engine: AVAudioEngine?
    private var player: AVAudioPlayerNode?
    private var playbackSignal: OnceSignal?
    private let pcmFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                          sampleRate: ElevenLabsClient.pcmSampleRate,
                                          channels: 1, interleaved: false)!

    override init() {
        super.init()
        synth.delegate = self
    }

    // MARK: ElevenLabs (streaming)

    func speakElevenLabs(text: String, voiceID: String, apiKey: String,
                         stability: Double, similarity: Double) async throws {
        stop()
        let bytes = try await ElevenLabsClient.streamSpeech(
            text: text, voiceID: voiceID, apiKey: apiKey, stability: stability, similarity: similarity)
        try Task.checkCancellation()

        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: pcmFormat)
        let levelHandler: @Sendable (Float) -> Void = { [weak self] rms in
            let value = AudioTaps.normalized(rms)
            Task { @MainActor in self?.onLevel?(value) }
        }
        engine.mainMixerNode.installTap(onBus: 0, bufferSize: 1024, format: nil,
                                        block: AudioTaps.levelTap(levelHandler))
        try engine.start()
        player.play()
        self.engine = engine
        self.player = player
        defer { stopEngine() }

        let chunkBytes = 4_800 * 2 // 0.2 s of 16-bit audio
        var pending = Data()
        pending.reserveCapacity(chunkBytes)
        for try await byte in bytes {
            pending.append(byte)
            if pending.count >= chunkBytes {
                try Task.checkCancellation()
                if let buffer = makeBuffer(pending) { player.scheduleBuffer(buffer, completionHandler: nil) }
                pending.removeAll(keepingCapacity: true)
            }
        }
        try Task.checkCancellation()

        let tail = makeBuffer(pending) ?? makeBuffer(Data(count: 480))! // 10 ms silence as an end marker
        let signal = OnceSignal()
        playbackSignal = signal
        player.scheduleBuffer(tail, completionCallbackType: .dataPlayedBack,
                              completionHandler: AudioTaps.playbackFinished(signal))
        await signal.wait()
    }

    private func makeBuffer(_ data: Data) -> AVAudioPCMBuffer? {
        let count = data.count / 2
        guard count > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: pcmFormat, frameCapacity: AVAudioFrameCount(count)),
              let out = buffer.floatChannelData?[0] else { return nil }
        buffer.frameLength = AVAudioFrameCount(count)
        data.withUnsafeBytes { raw in
            for i in 0..<count {
                let sample = Int16(littleEndian: raw.loadUnaligned(fromByteOffset: i * 2, as: Int16.self))
                out[i] = Float(sample) / 32_768
            }
        }
        return buffer
    }

    private func stopEngine() {
        playbackSignal?.fire()
        playbackSignal = nil
        player?.stop()
        engine?.mainMixerNode.removeTap(onBus: 0)
        engine?.stop()
        player = nil
        engine = nil
        onLevel?(0)
    }

    // MARK: System voice fallback

    func speakSystem(_ text: String) async {
        stop()
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: "en-GB")
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        startFakeLevel()
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            synthContinuation = cont
            synth.speak(utterance)
        }
        fakeLevelTask?.cancel()
        onLevel?(0)
    }

    /// AVSpeechSynthesizer doesn't expose output levels, so animate a plausible speaking envelope.
    private func startFakeLevel() {
        fakeLevelTask?.cancel()
        fakeLevelTask = Task { [weak self] in
            var t = 0.0
            while !Task.isCancelled {
                t += 0.05
                let v = 0.35 + 0.3 * abs(sin(t * 7)) + 0.15 * abs(sin(t * 13))
                self?.onLevel?(v)
                try? await Task.sleep(for: .milliseconds(50))
            }
        }
    }

    fileprivate func finishSynth() {
        synthContinuation?.resume()
        synthContinuation = nil
    }

    func stop() {
        if synth.isSpeaking { synth.stopSpeaking(at: .immediate) }
        fakeLevelTask?.cancel()
        finishSynth()
        stopEngine()
    }
}

extension SpeechOutput: AVSpeechSynthesizerDelegate {
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in self.finishSynth() }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in self.finishSynth() }
    }
}
