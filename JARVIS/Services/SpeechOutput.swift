import AVFoundation
import Foundation

/// Speaks replies with ElevenLabs streaming PCM. The British device voice is the fallback when that cannot start.
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
    private var loggedFirstAudio = false
    private var prefetchTasks: [String: Task<Data, Error>] = [:]
    private var sharedPlayer: AVAudioPlayerNode?
    private var usingSharedPlayback = false
    private var sharedTapInstalled = false
    private var voiceGate: SpeakerGate?
    private let levels = LevelCoalescer()
    private let deviceSpeech = DeviceSpeech()
    private var fillerActive = false
    private var fillerGeneration = 0
    /// 50 ms at 24 kHz, 16-bit mono, so the first buffer starts as soon as speech arrives.
    private static let primeBytes: Int = 2_400
    /// 200 ms follow-on buffers.
    private static let followBytes: Int = 9_600
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
        loggedFirstAudio = false
    }

    /// Starts the next sentence's download while the current one is still playing.
    func prefetch(text: String, voiceID: String, apiKey: String, stability: Double, similarity: Double) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, prefetchTasks[trimmed] == nil else { return }
        let voice = voiceID
        let key = apiKey
        let stable = stability
        let similar = similarity
        prefetchTasks[trimmed] = Task.detached {
            try await ElevenLabsClient.collectSpeech(
                text: trimmed, voiceID: voice, apiKey: key, stability: stable, similarity: similar)
        }
    }

    func bindVoiceGate(_ gate: SpeakerGate) {
        voiceGate = gate
    }

    /// The listener engine plays TTS when it is up, so echo cancellation hears the same output.
    func bindSharedPlayer(_ player: AVAudioPlayerNode?) {
        if sharedTapInstalled, player !== sharedPlayer {
            removeSharedLevelTap()
        }
        sharedPlayer = player
    }

    /// Stops playback taps before the listener installs its own. The ring reads VoiceMeter and never taps the mic.
    func yieldMicrophone() {
        removeSharedLevelTap()
        releasePrivateEngine()
    }

    /// Opens the playback engine while listening so the first sentence does not pay startup cost.
    func prewarm() {
        if sharedPlayer?.engine?.isRunning == true {
            releasePrivateEngine()
            return
        }
        guard engine == nil else { return }
        if (try? openEngine(monitorMicrophone: false)) != nil {
            engineMonitorsMic = false
        }
    }

    func speakElevenLabs(text: String, voiceID: String, apiKey: String,
                         stability: Double, similarity: Double, monitorMicrophone: Bool) async throws {
        preparePlayback()
        LatencyLog.event("tts-request")
        if let data = await takePrefetch(text) {
            try Task.checkCancellation()
            let player = try ensureEngine(monitorMicrophone: monitorMicrophone)
            try await play(data: data, player: player)
            return
        }
        try Task.checkCancellation()
        let bytes = try await ElevenLabsClient.streamSpeech(
            text: text, voiceID: voiceID, apiKey: apiKey, stability: stability, similarity: similarity)
        try Task.checkCancellation()

        let player = try ensureEngine(monitorMicrophone: monitorMicrophone)
        try await play(bytes: bytes, player: player)
    }

    private func takePrefetch(_ text: String) async -> Data? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let task = prefetchTasks.removeValue(forKey: trimmed) else { return nil }
        do {
            let data = try await task.value
            return data.isEmpty ? nil : data
        } catch {
            return nil
        }
    }

    private func play(bytes: URLSession.AsyncBytes, player: AVAudioPlayerNode) async throws {
        var primed = false
        var pending = Data()
        pending.reserveCapacity(Self.followBytes)
        for try await byte in bytes {
            pending.append(byte)
            let needed: Int = primed ? Self.followBytes : Self.primeBytes
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
        await finishPlayback(tail: pending, player: player)
    }

    private func play(data: Data, player: AVAudioPlayerNode) async throws {
        var buffers: [AVAudioPCMBuffer] = []
        var offset: Int = 0
        var primed = false
        let count: Int = data.count
        while offset < count {
            try Task.checkCancellation()
            let needed: Int = primed ? Self.followBytes : Self.primeBytes
            let remaining: Int = count - offset
            let take: Int = remaining < needed ? remaining : needed
            if take <= 0 { break }
            let end: Int = offset + take
            let slice = data.subdata(in: offset..<end)
            if let buffer = makeBuffer(slice) {
                buffers.append(buffer)
            }
            offset = end
            primed = true
        }
        await schedule(buffers, player: player, trackBuffers: true)
    }

    /// The last buffer carries the playback-finished callback. A silence marker covers an empty tail.
    private func finishPlayback(tail: Data, player: AVAudioPlayerNode) async {
        if let tailBuffer = makeBuffer(tail) {
            await schedule([tailBuffer], player: player, trackBuffers: true)
            return
        }
        if playbackAnchor != nil, let marker = makeBuffer(Data(count: 480)) {
            await schedule([marker], player: player, trackBuffers: false)
            return
        }
        let signal = OnceSignal()
        playbackSignal = signal
        signal.fire()
        await signal.wait()
    }

    private func schedule(_ buffers: [AVAudioPCMBuffer], player: AVAudioPlayerNode, trackBuffers: Bool) async {
        let signal = OnceSignal()
        playbackSignal = signal
        guard !buffers.isEmpty else {
            signal.fire()
            await signal.wait()
            return
        }
        let lastIndex: Int = buffers.count - 1
        for index in 0..<buffers.count {
            let buffer = buffers[index]
            if trackBuffers { track(buffer) }
            if index == lastIndex {
                player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack,
                                      completionHandler: AudioTaps.playbackFinished(signal))
            } else {
                player.scheduleBuffer(buffer, completionHandler: nil)
            }
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
        if playbackAnchor == nil {
            playbackAnchor = Date()
            markReplyAudio()
        }
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
                engine.inputNode.isVoiceProcessingAGCEnabled = true
                engine.inputNode.isVoiceProcessingBypassed = false
                monitoring = true
                LatencyLog.noteVoiceProcessing(true)
            } catch {
                monitoring = false
                LatencyLog.noteVoiceProcessing(false)
            }
        }
        let player = AVAudioPlayerNode()
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: pcmFormat)
        let levels = self.levels
        let levelHandler: @Sendable (Float) -> Void = { [weak self] rms in
            let value = AudioTaps.normalized(rms)
            VoiceMeter.shared.level = value
            guard levels.allow() else { return }
            Task { @MainActor in self?.onLevel?(value) }
        }
        engine.mainMixerNode.installTap(onBus: 0, bufferSize: 1024, format: nil,
                                        block: AudioTaps.levelTap(levelHandler))
        mixerTapInstalled = true
        // Input tap is barge-in only, and only on this playback engine when the listener is not running.
        if monitoring {
            let bargeHandler: @Sendable (Float) -> Void = { _ in }
            let format = engine.inputNode.outputFormat(forBus: 0)
            if format.sampleRate > 0, format.channelCount > 0 {
                if let voiceGate {
                    engine.inputNode.installTap(onBus: 0, bufferSize: 1024, format: format,
                                                block: AudioTaps.bargeTap(gate: voiceGate, level: bargeHandler))
                } else {
                    engine.inputNode.installTap(onBus: 0, bufferSize: 1024, format: format,
                                                block: AudioTaps.levelTap(bargeHandler))
                }
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
        if let sharedPlayer, sharedPlayer.engine?.isRunning == true {
            releasePrivateEngine()
            usingSharedPlayback = true
            if !sharedPlayer.isPlaying { sharedPlayer.play() }
            installSharedLevelTap()
            player = sharedPlayer
            return sharedPlayer
        }
        usingSharedPlayback = false
        if let engine, engine.isRunning, let player, engineMonitorsMic == monitorMicrophone {
            if !player.isPlaying { player.play() }
            return player
        }
        stopEngine()
        return try openEngine(monitorMicrophone: monitorMicrophone)
    }

    private func installSharedLevelTap() {
        guard !sharedTapInstalled, let mixer = sharedPlayer?.engine?.mainMixerNode else { return }
        let levels = self.levels
        let levelHandler: @Sendable (Float) -> Void = { [weak self] rms in
            let value = AudioTaps.normalized(rms)
            VoiceMeter.shared.level = value
            guard levels.allow() else { return }
            Task { @MainActor in self?.onLevel?(value) }
        }
        mixer.installTap(onBus: 0, bufferSize: 1024, format: nil, block: AudioTaps.levelTap(levelHandler))
        sharedTapInstalled = true
    }

    private func removeSharedLevelTap() {
        guard sharedTapInstalled else { return }
        sharedPlayer?.engine?.mainMixerNode.removeTap(onBus: 0)
        sharedTapInstalled = false
    }

    /// British device voice when ElevenLabs cannot start. Phone calls still fall back to Polly.
    func speakDevice(_ text: String) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        preparePlayback()
        LatencyLog.event("device-voice")
        let signal = OnceSignal()
        fillerGeneration += 1
        fillerActive = false
        deviceSpeech.play(trimmed, signal: signal) { [weak self] in
            Task { @MainActor in
                self?.markReplyAudio()
            }
        }
        await signal.wait()
    }

    /// Drops the fallback playback engine once TTS is playing on the capture engine.
    private func releasePrivateEngine() {
        guard engine != nil else { return }
        if mixerTapInstalled {
            engine?.mainMixerNode.removeTap(onBus: 0)
            mixerTapInstalled = false
        }
        if inputTapInstalled {
            engine?.inputNode.removeTap(onBus: 0)
            inputTapInstalled = false
        }
        if let active = player {
            let playingShared: Bool = sharedPlayer.map { node in node === active } ?? false
            if !playingShared {
                active.stop()
                self.player = nil
                playbackSignal?.fire()
                playbackSignal = nil
                bargeSince = nil
            }
        }
        engine?.stop()
        engine = nil
        engineMonitorsMic = false
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

    /// A short on-device acknowledgement. It does not count as the reply's first audio.
    func speakFiller(_ text: String) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        fillerGeneration += 1
        let generation = fillerGeneration
        fillerActive = true
        let signal = OnceSignal()
        deviceSpeech.play(trimmed, signal: signal) { }
        await signal.wait()
        if fillerGeneration == generation {
            fillerActive = false
        }
    }

    func stopFiller() {
        guard fillerActive else { return }
        fillerGeneration += 1
        fillerActive = false
        deviceSpeech.stop()
    }

    private func markReplyAudio() {
        if !loggedFirstAudio {
            loggedFirstAudio = true
            LatencyLog.event("tts-first-audio")
        }
        if fillerActive { stopFiller() }
    }

    func stop() {
        fillerActive = false
        deviceSpeech.stop()
        for task in prefetchTasks.values {
            task.cancel()
        }
        prefetchTasks.removeAll()
        removeSharedLevelTap()
        if usingSharedPlayback {
            playbackSignal?.fire()
            playbackSignal = nil
            sharedPlayer?.stop()
            usingSharedPlayback = false
            player = nil
            onLevel?(0)
            return
        }
        stopEngine()
    }
}

/// On-device British speech. The synthesizer callbacks are not isolated to the main actor.
final class DeviceSpeech: NSObject, AVSpeechSynthesizerDelegate, @unchecked Sendable {
    private let synth = AVSpeechSynthesizer()
    private let lock = NSLock()
    private var signal: OnceSignal?
    private var started: (@Sendable () -> Void)?

    override init() {
        super.init()
        synth.delegate = self
    }

    func play(_ text: String, signal: OnceSignal, started: @escaping @Sendable () -> Void) {
        lock.lock()
        self.signal?.fire()
        self.signal = signal
        self.started = started
        lock.unlock()
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: "en-GB")
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        synth.speak(utterance)
    }

    func stop() {
        synth.stopSpeaking(at: .immediate)
        lock.lock()
        let pending = signal
        signal = nil
        started = nil
        lock.unlock()
        pending?.fire()
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance) {
        lock.lock()
        let start = started
        started = nil
        lock.unlock()
        start?()
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        finish()
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        finish()
    }

    private func finish() {
        lock.lock()
        let pending = signal
        signal = nil
        lock.unlock()
        pending?.fire()
    }
}
