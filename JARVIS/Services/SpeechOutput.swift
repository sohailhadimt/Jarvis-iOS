import AVFoundation
import Foundation

/// Speaks replies with ElevenLabs streaming PCM through AVAudioEngine. There is no system-voice fallback.
@MainActor
final class SpeechOutput: NSObject {
    var onLevel: ((Double) -> Void)?
    var onBargeIn: (() -> Void)?

    private var engine: AVAudioEngine?
    private var player: AVAudioPlayerNode?
    private var playbackSignal: OnceSignal?
    private var mixerTapInstalled = false
    private var inputTapInstalled = false
    private var bargeSince: Date?
    private var engineMonitorsMic = false
    private var playbackAnchor: Date?
    private var scheduledFrames = 0
    private let pcmFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                          sampleRate: ElevenLabsClient.pcmSampleRate,
                                          channels: 1, interleaved: false)!

    override init() {
        super.init()
    }

    // MARK: ElevenLabs (streaming)

    /// Fraction of the current utterance that has been heard. Read this before `stop()`.
    var playbackFraction: Double {
        guard scheduledFrames > 0, let playbackAnchor else { return 0.0 }
        let played: Double = Date().timeIntervalSince(playbackAnchor) * pcmFormat.sampleRate
        let frames: Double = Double(scheduledFrames)
        let fraction: Double = played / frames
        return min(1.0, max(0.0, fraction))
    }

    func preparePlayback() {
        playbackAnchor = nil
        scheduledFrames = 0
    }

    /// Opens the playback engine while listening so the first sentence does not pay startup cost.
    func prewarm() {
        guard engine == nil else { return }
        if (try? openEngine(monitorMicrophone: false)) != nil {
            engineMonitorsMic = false
        }
    }

    func speakElevenLabs(text: String, voiceID: String, apiKey: String,
                         stability: Double, similarity: Double, monitorMicrophone: Bool) async throws {
        playbackSignal?.fire()
        playbackSignal = nil
        player?.stop()
        preparePlayback()
        let bytes = try await ElevenLabsClient.streamSpeech(
            text: text, voiceID: voiceID, apiKey: apiKey, stability: stability, similarity: similarity)
        try Task.checkCancellation()

        let player = try ensureEngine(monitorMicrophone: monitorMicrophone)

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
        engineMonitorsMic = monitoring
        bargeSince = nil
        return player
    }

    private func ensureEngine(monitorMicrophone: Bool) throws -> AVAudioPlayerNode {
        if let engine, engine.isRunning, let player, engineMonitorsMic == monitorMicrophone {
            if !player.isPlaying { player.play() }
            return player
        }
        stopEngine()
        return try openEngine(monitorMicrophone: monitorMicrophone)
    }

    private func noteBarge(_ value: Double) {
        guard player != nil else { return }
        if value > 0.36 {
            let start = bargeSince ?? Date()
            bargeSince = start
            if Date().timeIntervalSince(start) >= 0.25 {
                bargeSince = nil
                onBargeIn?()
            }
        } else if value < 0.18 {
            bargeSince = nil
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
        engineMonitorsMic = false
        bargeSince = nil
        onLevel?(0)
    }

    func stop() {
        stopEngine()
    }
}
