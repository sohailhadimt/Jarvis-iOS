import AVFoundation
import Foundation

/// Speaks replies: ElevenLabs streaming PCM through AVAudioEngine, or AVSpeechSynthesizer as a fallback.
@MainActor
final class SpeechOutput: NSObject {
    var onLevel: ((Double) -> Void)?
    var onBargeIn: (() -> Void)?

    private let synth = AVSpeechSynthesizer()
    private var synthContinuation: CheckedContinuation<Void, Never>?
    private var fakeLevelTask: Task<Void, Never>?

    private var engine: AVAudioEngine?
    private var player: AVAudioPlayerNode?
    private var playbackSignal: OnceSignal?
    private var mixerTapInstalled = false
    private var inputTapInstalled = false
    private var bargeFrames = 0
    private var playbackAnchor: Date?
    private var scheduledFrames = 0
    private let pcmFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                          sampleRate: ElevenLabsClient.pcmSampleRate,
                                          channels: 1, interleaved: false)!

    override init() {
        super.init()
        synth.delegate = self
    }

    // MARK: ElevenLabs (streaming)

    /// Fraction of the current utterance that has been heard. Read this before `stop()`.
    var playbackFraction: Double {
        guard scheduledFrames > 0, let playbackAnchor else { return 0 }
        let played = Date().timeIntervalSince(playbackAnchor) * pcmFormat.sampleRate
        return min(1, max(0, played / Double(scheduledFrames)))
    }

    func preparePlayback() {
        playbackAnchor = nil
        scheduledFrames = 0
    }

    func speakElevenLabs(text: String, voiceID: String, apiKey: String,
                         stability: Double, similarity: Double, monitorMicrophone: Bool) async throws {
        stop()
        preparePlayback()
        let bytes = try await ElevenLabsClient.streamSpeech(
            text: text, voiceID: voiceID, apiKey: apiKey, stability: stability, similarity: similarity)
        try Task.checkCancellation()

        let player = try openEngine(monitorMicrophone: monitorMicrophone)
        defer { stopEngine() }

        var primed = false
        var pending = Data()
        pending.reserveCapacity(4_800 * 2)
        for try await byte in bytes {
            pending.append(byte)
            let needed = primed ? 4_800 * 2 : 2_400 * 2
            if pending.count >= needed {
                try Task.checkCancellation()
                if let buffer = makeBuffer(pending) {
                    track(buffer)
                    player.scheduleBuffer(buffer, completionHandler: nil)
                }
                pending.removeAll(keepingCapacity: true)
                primed = true
            }
        }
        try Task.checkCancellation()

        let signal = OnceSignal()
        playbackSignal = signal
        if let tail = makeBuffer(pending) {
            track(tail)
            player.scheduleBuffer(tail, completionCallbackType: .dataPlayedBack,
                                  completionHandler: AudioTaps.playbackFinished(signal))
        } else if let marker = makeBuffer(Data(count: 480)) {
            player.scheduleBuffer(marker, completionCallbackType: .dataPlayedBack,
                                  completionHandler: AudioTaps.playbackFinished(signal))
        } else {
            signal.fire()
        }
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

    private func track(_ buffer: AVAudioPCMBuffer) {
        if playbackAnchor == nil { playbackAnchor = Date() }
        scheduledFrames += Int(buffer.frameLength)
    }

    /// Playback engine. Voice processing and a mic tap are attached only when the listener
    /// engine is not already holding the microphone.
    private func openEngine(monitorMicrophone: Bool) throws -> AVAudioPlayerNode {
        let engine = AVAudioEngine()
        var monitoring = false
        if monitorMicrophone {
            do {
                try engine.inputNode.setVoiceProcessingEnabled(true)
                monitoring = true
            } catch {
                monitoring = false
            }
        }
        let player = AVAudioPlayerNode()
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: pcmFormat)
        let levelHandler: @Sendable (Float) -> Void = { [weak self] rms in
            let value = AudioTaps.normalized(rms)
            Task { @MainActor in self?.onLevel?(value) }
        }
        engine.mainMixerNode.installTap(onBus: 0, bufferSize: 1024, format: nil,
                                        block: AudioTaps.levelTap(levelHandler))
        mixerTapInstalled = true
        if monitoring {
            let bargeHandler: @Sendable (Float) -> Void = { [weak self] rms in
                let value = AudioTaps.normalized(rms)
                Task { @MainActor in self?.noteBarge(value) }
            }
            let format = engine.inputNode.outputFormat(forBus: 0)
            if format.sampleRate > 0, format.channelCount > 0 {
                engine.inputNode.installTap(onBus: 0, bufferSize: 1024, format: format,
                                            block: AudioTaps.levelTap(bargeHandler))
                inputTapInstalled = true
            }
        }
        do {
            try engine.start()
        } catch {
            engine.mainMixerNode.removeTap(onBus: 0)
            if inputTapInstalled { engine.inputNode.removeTap(onBus: 0) }
            mixerTapInstalled = false
            inputTapInstalled = false
            if monitorMicrophone {
                return try openEngine(monitorMicrophone: false)
            }
            throw error
        }
        player.play()
        self.engine = engine
        self.player = player
        bargeFrames = 0
        return player
    }

    private func noteBarge(_ value: Double) {
        guard player != nil else { return }
        if value > 0.36 {
            bargeFrames += 1
            if bargeFrames >= 4 {
                bargeFrames = 0
                onBargeIn?()
            }
        } else if value < 0.18 {
            bargeFrames = 0
        }
    }

    private func stopEngine() {
        playbackSignal?.fire()
        playbackSignal = nil
        player?.stop()
        if mixerTapInstalled {
            engine?.mainMixerNode.removeTap(onBus: 0)
            mixerTapInstalled = false
        }
        if inputTapInstalled {
            engine?.inputNode.removeTap(onBus: 0)
            inputTapInstalled = false
        }
        engine?.stop()
        player = nil
        engine = nil
        bargeFrames = 0
        onLevel?(0)
    }

    // MARK: System voice fallback

    func speakSystem(_ text: String) async {
        stop()
        preparePlayback()
        let seconds = max(0.35, Double(text.count) / 13.5)
        playbackAnchor = Date()
        scheduledFrames = max(1, Int(seconds * pcmFormat.sampleRate))
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
