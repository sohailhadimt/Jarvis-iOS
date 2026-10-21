import AudioToolbox
import AVFoundation
import Foundation
import Speech

/// Closures handed to AVFoundation / Speech are invoked on background threads.
/// Under Swift 6, a closure *written inside* a @MainActor type inherits main-actor isolation and
/// traps at runtime when called off-main. So every such closure is built here, in nonisolated code.
enum AudioTaps {
    nonisolated static func levelTap(_ level: @escaping @Sendable (Float) -> Void)
        -> @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void {
        return { buffer, _ in level(rms(buffer)) }
    }

    /// Keeps the input node pulling buffers so a background recording session is not suspended.
    nonisolated static func silentTap() -> @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void {
        return { _, _ in }
    }

    nonisolated static func speechAuthorizationStatus() -> SFSpeechRecognizerAuthorizationStatus {
        SFSpeechRecognizer.authorizationStatus()
    }

    nonisolated static func recognitionTap(request: SFSpeechAudioBufferRecognitionRequest,
                                           gate: SpeakerGate,
                                           level: @escaping @Sendable (Float) -> Void)
        -> @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void {
        nonisolated(unsafe) let request = request
        return { buffer, _ in
            let chunks = gate.observe(buffer)
            if chunks.isEmpty {
                // Voice ID rejected this buffer. Zeros keep the request alive without transcribing it.
                // A normal pause is not this path: the gate forwards the real samples.
                if let silent = silentBuffer(buffer) {
                    request.append(silent)
                }
            } else {
                for chunk in chunks {
                    request.append(chunk)
                }
            }
            level(rms(buffer))
        }
    }

    /// Mic level during playback. Also feeds the voice gate so barge-in can require the enrolled speaker.
    nonisolated static func bargeTap(gate: SpeakerGate, level: @escaping @Sendable (Float) -> Void)
        -> @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void {
        return { buffer, _ in
            _ = gate.observe(buffer)
            level(rms(buffer))
        }
    }

    nonisolated static func captureTap(_ body: @escaping @Sendable (AVAudioPCMBuffer) -> Void)
        -> @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void {
        return { buffer, _ in body(buffer) }
    }

    nonisolated static func recognitionHandler(_ handler: @escaping @Sendable (String?, Bool, (any Error)?) -> Void)
        -> @Sendable (SFSpeechRecognitionResult?, (any Error)?) -> Void {
        return { result, error in
            handler(result?.bestTranscription.formattedString, result?.isFinal ?? false, error)
        }
    }

    /// Final-only callback for transcribing a recorded file. Built here so it is not main-actor isolated.
    nonisolated static func finalRecognitionHandler(_ handler: @escaping @Sendable (String?, (any Error)?) -> Void)
        -> @Sendable (SFSpeechRecognitionResult?, (any Error)?) -> Void {
        return { result, error in
            if let result, result.isFinal {
                handler(result.bestTranscription.formattedString, nil)
            } else if let error {
                handler(nil, error)
            }
        }
    }

    nonisolated static func fileTap(writer: PCMFileWriter, gate: SpeakerGate,
                                   level: @escaping @Sendable (Float) -> Void)
        -> @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void {
        return { buffer, _ in
            let chunks = gate.observe(buffer)
            var loudest: Float = rms(buffer)
            for chunk in chunks {
                writer.append(chunk)
                let chunkLevel: Float = rms(chunk)
                if chunkLevel > loudest { loudest = chunkLevel }
            }
            level(loudest)
        }
    }

    nonisolated static func playbackFinished(_ signal: OnceSignal)
        -> @Sendable (AVAudioPlayerNodeCompletionCallbackType) -> Void {
        return { _ in signal.fire() }
    }

    /// A zeroed copy so a rejected mic buffer cannot be transcribed.
    nonisolated static func silentBuffer(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        let frames = Int(buffer.frameLength)
        guard frames > 0,
              let clone = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameLength),
              let dest = clone.floatChannelData else { return nil }
        clone.frameLength = buffer.frameLength
        let channels: Int = Int(buffer.format.channelCount)
        var channel: Int = 0
        while channel < channels {
            dest[channel].update(repeating: 0, count: frames)
            channel += 1
        }
        return clone
    }

    nonisolated static func rms(_ buffer: AVAudioPCMBuffer) -> Float {
        SpectrumMeter.shared.push(buffer)
        guard let data = buffer.floatChannelData?[0] else { return 0 }
        let n = Int(buffer.frameLength)
        guard n > 0 else { return 0 }
        var sum: Float = 0
        for i in 0..<n { sum += data[i] * data[i] }
        return (sum / Float(n)).squareRoot()
    }

    /// Maps RMS to 0...1 using a -55 dB ... -10 dB window.
    nonisolated static func normalized(_ rms: Float) -> Double {
        let db = 20 * log10(max(rms, 0.000_001))
        return Double(min(max((db + 55) / 45, 0), 1))
    }

    nonisolated static func requestSpeechAuthorization() async -> SFSpeechRecognizerAuthorizationStatus {
        await withCheckedContinuation { cont in
            SFSpeechRecognizer.requestAuthorization { cont.resume(returning: $0) }
        }
    }
}

/// Writes mic buffers as 16-bit mono 16 kHz WAV. The tap thread is the only caller of `append`.
final class PCMFileWriter: @unchecked Sendable {
    let url: URL
    private let converter: AVAudioConverter
    private let dest: AVAudioFormat
    private var file: AVAudioFile?
    private let lock = NSLock()
    private var framesWritten = 0
    private var writeFailed = false

    init(source: AVAudioFormat, url: URL) throws {
        guard let dest = AVAudioFormat(commonFormat: .pcmFormatInt16,
                                       sampleRate: 16_000,
                                       channels: 1,
                                       interleaved: true),
              let converter = AVAudioConverter(from: source, to: dest) else {
            throw ListenerError.noInput
        }
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatLinearPCM),
            AVSampleRateKey: 16_000.0,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
        let file = try AVAudioFile(forWriting: url, settings: settings,
                                   commonFormat: .pcmFormatInt16, interleaved: true)
        self.url = url
        self.dest = dest
        self.converter = converter
        self.file = file
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        guard buffer.frameLength > 0 else { return }
        lock.lock()
        defer { lock.unlock() }
        guard !writeFailed, let file else { return }
        let ratio = dest.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 256
        guard capacity > 0, let output = AVAudioPCMBuffer(pcmFormat: dest, frameCapacity: max(capacity, 256)) else {
            writeFailed = true
            return
        }
        var error: NSError?
        var consumed = false
        let status = converter.convert(to: output, error: &error) { _, outStatus in
            if consumed {
                outStatus.pointee = .noDataNow
                return nil
            }
            consumed = true
            outStatus.pointee = .haveData
            return buffer
        }
        guard error == nil, status != .error else {
            writeFailed = true
            return
        }
        guard output.frameLength > 0 else { return }
        do {
            try file.write(from: output)
            framesWritten += Int(output.frameLength)
        } catch {
            writeFailed = true
        }
    }

    func snapshot() -> (frames: Int, failed: Bool) {
        lock.lock()
        defer { lock.unlock() }
        return (framesWritten, writeFailed)
    }

    /// Finishes the WAV header before the caller reads the file.
    func close() {
        lock.lock()
        file = nil
        lock.unlock()
    }
}

/// Thread-safe one-shot signal bridging an audio callback to async/await.
final class OnceSignal: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Never>?
    private var fired = false

    func wait() async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            lock.lock()
            if fired {
                lock.unlock()
                cont.resume()
            } else {
                continuation = cont
                lock.unlock()
            }
        }
    }

    func fire() {
        lock.lock()
        let cont = continuation
        continuation = nil
        fired = true
        lock.unlock()
        cont?.resume()
    }
}
