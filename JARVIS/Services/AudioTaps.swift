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

    nonisolated static func recognitionTap(request: SFSpeechAudioBufferRecognitionRequest,
                                           level: @escaping @Sendable (Float) -> Void)
        -> @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void {
        nonisolated(unsafe) let request = request
        return { buffer, _ in
            request.append(buffer)
            level(rms(buffer))
        }
    }

    nonisolated static func recognitionHandler(_ handler: @escaping @Sendable (String?, Bool, (any Error)?) -> Void)
        -> @Sendable (SFSpeechRecognitionResult?, (any Error)?) -> Void {
        return { result, error in
            handler(result?.bestTranscription.formattedString, result?.isFinal ?? false, error)
        }
    }

    nonisolated static func playbackFinished(_ signal: OnceSignal)
        -> @Sendable (AVAudioPlayerNodeCompletionCallbackType) -> Void {
        return { _ in signal.fire() }
    }

    nonisolated static func rms(_ buffer: AVAudioPCMBuffer) -> Float {
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
