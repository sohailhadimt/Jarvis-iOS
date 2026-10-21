import Accelerate
import AVFoundation
import Foundation
import os

/// Decides whether a mic buffer is the enrolled speaker. The audio thread calls `observe`.
final class SpeakerGate: @unchecked Sendable {
    private let log = Logger(subsystem: "com.sohail.jarvis", category: "voice-id")
    private let lock = NSLock()
    private let analysis = DispatchQueue(label: "com.sohail.jarvis.voiceid")
    private var enabled = false
    private var profile: VoiceProfile?
    private var openThreshold: Float = 0.74
    private var closeThreshold: Float = 0.67
    private var matchedAt: TimeInterval = 0
    private var speechBand: Float = 0
    private var speechBandHeldUntil: TimeInterval = 0
    private var ring: [Float] = []
    private var ringStart: Int = 0
    private var sampleRate: Double = 48_000
    private var backlog: [AVAudioPCMBuffer] = []
    private var backlogFrames: Int = 0
    private var analysisPending = false
    private var lastKick: TimeInterval = 0
    private var latched = false
    let turn = VoiceTurnMeter()

    func update(enabled: Bool, profile: VoiceProfile?, threshold: Double) {
        lock.lock()
        self.enabled = enabled
        self.profile = profile
        let open: Float = Float(threshold)
        openThreshold = open
        let margin: Float = 0.07
        closeThreshold = open - margin
        if !enabled || profile == nil {
            matchedAt = 0
            latched = false
            backlog.removeAll()
            backlogFrames = 0
            ring.removeAll(keepingCapacity: false)
            ringStart = 0
            speechBand = 0
            speechBandHeldUntil = 0
        }
        lock.unlock()
    }

    var allowsUtterance: Bool {
        lock.lock()
        defer { lock.unlock() }
        if !enabled || profile == nil { return true }
        return freshLocked(Date().timeIntervalSinceReferenceDate)
    }

    var speechBandRatio: Double {
        lock.lock()
        defer { lock.unlock() }
        return Double(speechBand)
    }

    /// Buffers that should be forwarded to speech recognition, oldest first.
    func observe(_ buffer: AVAudioPCMBuffer) -> [AVAudioPCMBuffer] {
        guard let samples = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return [] }
        let frames: Int = Int(buffer.frameLength)
        let raw: Float = Self.rawRMS(samples, count: frames)
        let level: Float = Float(AudioTaps.normalized(raw))
        let rate: Float = Float(buffer.format.sampleRate)
        let measured = SpeechBandMeter.shared.measure(samples: samples, count: frames, sampleRate: rate)
        let ms = Int((Double(frames) / max(buffer.format.sampleRate, 1) * 1000).rounded())
        lock.lock()
        let smoothed: Float = speechBand * 0.55 + measured.speechBand * 0.45
        let now: TimeInterval = Date().timeIntervalSinceReferenceDate
        let lockOn: Bool = enabled && profile != nil
        let speakerOK: Bool = !lockOn || freshLocked(now)
        lock.unlock()
        let decision = turn.push(
            rms: raw,
            speechBand: measured.speechBand,
            flatness: measured.flatness,
            level: level,
            frameMs: ms,
            speakerOK: speakerOK
        )
        let speechLike: Bool = decision.hearsSpeech
        let pass: Bool = decision.forwardsAudio
        lock.lock()
        if speechLike {
            speechBand = smoothed
            speechBandHeldUntil = now + 0.35
        } else if now >= speechBandHeldUntil {
            speechBand = smoothed
        }
        if !lockOn {
            lock.unlock()
            // The recogniser hears the real microphone, including a quiet syllable and a short pause.
            // A buffer of zeros makes Apple Speech finalise and drop the rest of the sentence.
            // The meter still decides when the turn ends. Voice ID, below, is what rejects another speaker.
            return [buffer]
        }
        if speechLike {
            appendLocked(samples, count: frames, rate: buffer.format.sampleRate)
            scheduleLocked()
        }
        let fresh: Bool = freshLocked(now)
        // A short word can finish before the score returns. Flush what was held even on silence.
        if fresh {
            var pending = backlog
            backlog.removeAll()
            backlogFrames = 0
            lock.unlock()
            if speechLike || pass {
                pending.append(buffer)
            }
            return pending
        }
        if pass {
            lock.unlock()
            return [buffer]
        }
        if speechLike, let copy = Self.copy(buffer) {
            backlog.append(copy)
            backlogFrames += frames
            trimLocked()
        }
        lock.unlock()
        return []
    }

    private func freshLocked(_ now: TimeInterval) -> Bool {
        if matchedAt <= 0 { return false }
        let age: Double = now - matchedAt
        return age < 1.2
    }

    private func appendLocked(_ samples: UnsafePointer<Float>, count: Int, rate: Double) {
        if rate > 1_000 { sampleRate = rate }
        ring.append(contentsOf: UnsafeBufferPointer(start: samples, count: count))
        let limit: Int = max(Int(sampleRate), 16_000)
        let live: Int = ring.count - ringStart
        if live > limit {
            ringStart = ring.count - limit
        }
        if ringStart > 24_000 {
            ring.removeFirst(ringStart)
            ringStart = 0
        }
    }

    private func trimLocked() {
        let cap: Int = max(Int(sampleRate * 1.2), 16_000)
        while backlogFrames > cap, !backlog.isEmpty {
            let dropped: Int = Int(backlog.removeFirst().frameLength)
            backlogFrames -= dropped
        }
        if backlogFrames < 0 { backlogFrames = 0 }
    }

    private func scheduleLocked() {
        let now: TimeInterval = Date().timeIntervalSinceReferenceDate
        if now - lastKick < 0.25 { return }
        let live: Int = ring.count - ringStart
        let need: Int = Int(sampleRate * 0.40)
        if live < need || analysisPending { return }
        guard let enrolled = profile else { return }
        analysisPending = true
        lastKick = now
        let chunk = Array(ring[ringStart..<ring.count])
        let rate: Double = sampleRate
        let open: Float = openThreshold
        let close: Float = closeThreshold
        analysis.async { [weak self] in
            self?.analyze(chunk, rate: rate, enrolled: enrolled, open: open, close: close)
        }
    }

    private func analyze(_ chunk: [Float], rate: Double, enrolled: VoiceProfile, open: Float, close: Float) {
        defer {
            lock.lock()
            analysisPending = false
            lock.unlock()
        }
        guard let print = SpeakerEmbedding.makePrint(samples: chunk, sampleRate: rate, minimumFrames: 18) else { return }
        var score: Float = SpeakerEmbedding.similarity(print.embedding, enrolled.embedding)
        if enrolled.pitchHz > 60, print.pitchHz > 60 {
            let ratio: Float = print.pitchHz / enrolled.pitchHz
            if ratio < 0.55 || ratio > 1.80 {
                score -= 0.12
            }
        }
        let now: TimeInterval = Date().timeIntervalSinceReferenceDate
        lock.lock()
        let wasFresh: Bool = freshLocked(now)
        if score >= open {
            matchedAt = now
        } else if score < close {
            matchedAt = 0
            backlog.removeAll()
            backlogFrames = 0
        }
        let fresh: Bool = freshLocked(now)
        let changed: Bool = fresh != wasFresh || fresh != latched
        latched = fresh
        lock.unlock()
        if changed {
            let shown: Int = Int((Double(score) * 100.0).rounded())
            if fresh {
                log.info("voice match \(shown, privacy: .public)")
            } else {
                log.info("voice ignore \(shown, privacy: .public)")
            }
        }
    }

    private static func rawRMS(_ samples: UnsafePointer<Float>, count: Int) -> Float {
        guard count > 0 else { return 0 }
        var sum: Float = 0
        vDSP_svesq(samples, 1, &sum, vDSP_Length(count))
        let mean: Float = sum / Float(count)
        return mean.squareRoot()
    }

    private static func copy(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let clone = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameLength) else { return nil }
        clone.frameLength = buffer.frameLength
        guard let source = buffer.floatChannelData, let dest = clone.floatChannelData else { return nil }
        let channels: Int = Int(buffer.format.channelCount)
        let frames: Int = Int(buffer.frameLength)
        var channel: Int = 0
        while channel < channels {
            dest[channel].update(from: source[channel], count: frames)
            channel += 1
        }
        return clone
    }
}
