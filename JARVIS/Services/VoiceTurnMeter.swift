import Foundation
import os

/// Edge events from the on-device turn meter. Fired only when the state changes, not every buffer.
enum VoiceTurnEvent: Equatable, Sendable {
    case speechBegan
    case endOfTurn
    case barge
    case ignoredBurst
}

struct VoiceTurnDecision: Sendable {
    var forwardsAudio: Bool
    /// True when the frame sounds like close speech, even if it is not the enrolled speaker yet.
    var hearsSpeech: Bool
    var event: VoiceTurnEvent?
    var probability: Float
}

struct VoiceTurnSnapshot: Sendable {
    var probability: Float
    var noiseFloor: Float
    var calibrated: Bool
    var falseTriggers: Int
    var forwarding: Bool
    /// Nil until a transcript arrives. 1 means the words look finished.
    var endProbability: Float?
}

/// Recurrent speech detector for the live microphone.
///
/// A Silero Core ML package is not in this build. This is a fixed one-unit recurrent net on
/// signal-to-noise, speech-band energy, spectral flatness, and level. It is the same job as Silero:
/// a probability that updates every frame, not a raw loudness threshold. The audio thread calls `push`.
final class VoiceTurnMeter: @unchecked Sendable {
    static let calibrationMs = 300
    static let minimumSpeechMs = 250
    /// A cough or a speaker reflection is shorter than this. Real barge-in has to last.
    static let bargeMs = 300
    static let nearFieldSNR: Float = 3.2
    static let bargeSNR: Float = 6.2
    static let bargeOpen: Float = 0.80
    static let bargeBand: Float = 0.55
    static let minimumBand: Float = 0.45
    /// A finished sentence still waits this long, so a breath is not the end of the turn.
    static let minimumHangoverMs = 600

    private let log = Logger(subsystem: "com.sohail.jarvis", category: "vad")
    private let lock = NSLock()
    private var hidden: Float = 0.15
    private var noiseFloor: Float = 0.01
    private var heardMs = 0
    private var speechMs = 0
    private var silenceMs = 0
    private var bargeRunMs = 0
    /// One interrupt per stretch of user speech. Continued talking must not fire again 300 ms later.
    private var bargeLatched = false
    /// Hardware echo cancellation. Barge-in stays off until this is true, so speaker playback cannot stop itself.
    private var echoCancelled = false
    private var triggered = false
    private var calibrated = false
    private var forwarding = false
    private var hearing = false
    private var probability: Float = 0
    private var falseTriggers = 0
    private var pauseSeconds: Double = 0.65
    private var sensitivity: Double = 0.5
    private var assistantSpeaking = false
    /// Nil until speech recognition has words. A missing transcript is unfinished, so a breath does not close the turn.
    private var endProbability: Float?
    private var eagerness: TurnEagerness = .medium
    /// Characters in the latest transcript. Growth means the user is still being heard.
    private var lastTranscriptCount = 0
    private var onEvent: (@Sendable (VoiceTurnEvent) -> Void)?

    func setHandler(_ handler: (@Sendable (VoiceTurnEvent) -> Void)?) {
        lock.lock()
        onEvent = handler
        lock.unlock()
    }

    func setPause(_ seconds: Double) {
        lock.lock()
        pauseSeconds = min(1.2, max(0.55, seconds))
        lock.unlock()
    }

    /// The listener sets this only after `setVoiceProcessingEnabled` succeeds.
    func setEchoCancelled(_ enabled: Bool) {
        lock.lock()
        if echoCancelled != enabled {
            echoCancelled = enabled
            bargeRunMs = 0
            bargeLatched = false
        }
        lock.unlock()
    }

    func setSensitivity(_ value: Double) {
        lock.lock()
        sensitivity = min(1, max(0, value))
        lock.unlock()
    }

    func setAssistantSpeaking(_ speaking: Bool) {
        lock.lock()
        let changed = assistantSpeaking != speaking
        assistantSpeaking = speaking
        if changed || !speaking {
            bargeRunMs = 0
            bargeLatched = false
        }
        lock.unlock()
    }

    func setEagerness(_ value: TurnEagerness) {
        lock.lock()
        eagerness = value
        lock.unlock()
    }

    /// Latest transcript. The audio thread reads the score; it does not parse text.
    func noteTranscript(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let score: Float? = trimmed.isEmpty ? nil : SemanticTurn.probability(trimmed)
        lock.lock()
        endProbability = score
        if trimmed.isEmpty {
            lastTranscriptCount = 0
            lock.unlock()
            return
        }
        // The energy gate can miss a quiet voice. Words from the recogniser still open the turn,
        // and a longer partial means he has not finished, so the hangover starts again.
        let grew = trimmed.count > lastTranscriptCount
        lastTranscriptCount = trimmed.count
        if grew && !assistantSpeaking {
            if !triggered {
                triggered = true
                forwarding = true
            }
            silenceMs = 0
        }
        lock.unlock()
    }

    func reset() {
        lock.lock()
        hidden = 0.15
        noiseFloor = 0.01
        heardMs = 0
        speechMs = 0
        silenceMs = 0
        bargeRunMs = 0
        bargeLatched = false
        triggered = false
        calibrated = false
        forwarding = false
        hearing = false
        probability = 0
        falseTriggers = 0
        endProbability = nil
        lastTranscriptCount = 0
        lock.unlock()
    }

    func snapshot() -> VoiceTurnSnapshot {
        lock.lock()
        defer { lock.unlock() }
        return VoiceTurnSnapshot(
            probability: probability,
            noiseFloor: noiseFloor,
            calibrated: calibrated,
            falseTriggers: falseTriggers,
            forwarding: forwarding,
            endProbability: endProbability
        )
    }

    /// One microphone frame. `level` is the 0...1 loudness used by the ring, not a speech decision.
    func push(rms: Float, speechBand: Float, flatness: Float, level: Float, frameMs: Int, speakerOK: Bool) -> VoiceTurnDecision {
        let step = max(frameMs, 1)
        lock.lock()
        let event = advanceLocked(
            rms: max(rms, 0),
            speechBand: speechBand,
            flatness: flatness,
            level: level,
            step: step,
            speakerOK: speakerOK
        )
        let decision = VoiceTurnDecision(forwardsAudio: forwarding, hearsSpeech: hearing, event: event, probability: probability)
        let handler = onEvent
        lock.unlock()
        if let event {
            handler?(event)
        }
        return decision
    }

    private func advanceLocked(rms: Float, speechBand: Float, flatness: Float, level: Float, step: Int, speakerOK: Bool) -> VoiceTurnEvent? {
        if !calibrated {
            heardMs += step
            let sample = max(rms, 0.000_1)
            if heardMs == step {
                noiseFloor = sample
            } else if sample < noiseFloor {
                // Fall quickly so speech during the opening window does not become the noise floor.
                noiseFloor = noiseFloor * 0.45 + sample * 0.55
            } else {
                noiseFloor = noiseFloor * 0.97 + sample * 0.03
            }
            if heardMs >= Self.calibrationMs {
                calibrated = true
            }
            forwarding = false
            hearing = false
            probability = hidden
            return nil
        }

        let snr: Float = rms / max(noiseFloor, 0.000_1)
        let open: Float = Float(0.68 - sensitivity * 0.20)
        let instant = Self.instant(snr: snr, speechBand: speechBand, flatness: flatness, level: level)
        hidden = Self.recur(hidden, snr: snr, speechBand: speechBand, flatness: flatness, level: level)
        probability = hidden
        let shaped = hidden >= open && speechBand >= Self.minimumBand && snr >= Self.nearFieldSNR
        // A close voice still counts when the floor was learned from that same voice.
        let closeVoice = rms >= 0.04 && speechBand >= Self.minimumBand && flatness <= 0.45 && speakerOK
        let userSpeech = (shaped && speakerOK) || closeVoice
        // The leaky state lags the first syllable. Feed that audio to the recogniser without ending the turn on it.
        let onset = userSpeech || (instant >= open && speechBand >= Self.minimumBand && snr >= Self.nearFieldSNR && speakerOK)

        hearing = shaped
        if assistantSpeaking {
            forwarding = false
            // Speaker audio leaks into the mic whenever echo cancellation is off. That must not be an interruption.
            guard echoCancelled else {
                bargeRunMs = 0
                return nil
            }
            let interrupt = instant >= Self.bargeOpen && speechBand >= Self.bargeBand && snr >= Self.bargeSNR && speakerOK
            if interrupt {
                if bargeLatched { return nil }
                bargeRunMs += step
                if bargeRunMs >= Self.bargeMs {
                    bargeRunMs = 0
                    bargeLatched = true
                    speechMs = 0
                    silenceMs = 0
                    triggered = false
                    log.info("barge")
                    return .barge
                }
            } else {
                bargeRunMs = 0
                bargeLatched = false
            }
            return nil
        }

        if !userSpeech && !onset {
            noiseFloor = noiseFloor * 0.985 + max(rms, 0.000_1) * 0.015
        }

        if userSpeech || onset {
            if userSpeech {
                speechMs += step
            }
            silenceMs = 0
            forwarding = true
            hearing = true
            if userSpeech, !triggered, speechMs >= Self.minimumSpeechMs {
                triggered = true
                log.info("speech")
                return .speechBegan
            }
            return nil
        }

        hearing = shaped
        if !triggered {
            // A dip inside the first word is not a rejected blip. Keep the real samples flowing.
            if speechMs > 0 {
                silenceMs += step
                if silenceMs < Self.bargeMs {
                    forwarding = true
                    return nil
                }
                forwarding = false
                speechMs = 0
                silenceMs = 0
                falseTriggers += 1
                log.info("ignored burst")
                return .ignoredBurst
            }
            forwarding = false
            return nil
        }

        // Keep the recogniser on real audio through the hangover. A gap of digital silence makes it finalise early.
        forwarding = true
        silenceMs += step
        let hangover = Self.endpointDelayMs(minSeconds: pauseSeconds, eagerness: eagerness, endProbability: endProbability)
        if silenceMs >= hangover {
            triggered = false
            forwarding = false
            speechMs = 0
            silenceMs = 0
            log.info("end of turn")
            return .endOfTurn
        }
        return nil
    }

    /// Silence required before the turn ends.
    ///
    /// A finished sentence still waits at least 600 ms. A missing transcript is unfinished,
    /// so a breath or a slow recogniser cannot close the turn. Below the eagerness threshold
    /// the wait stretches toward that setting's maximum: 2s high, 4s medium, 8s low.
    static func endpointDelayMs(minSeconds: Double, eagerness: TurnEagerness, endProbability: Float?) -> Int {
        let requested = Int((min(1.2, max(0.55, minSeconds)) * 1000).rounded())
        let minMs = max(Self.minimumHangoverMs, requested)
        let probability = endProbability ?? 0.15
        if probability >= eagerness.unlikelyThreshold { return minMs }
        let maxMs = eagerness.maxTimeoutMs
        let shortfall = (eagerness.unlikelyThreshold - probability) / eagerness.unlikelyThreshold
        let extra = Float(max(0, maxMs - minMs)) * min(1, max(0, shortfall))
        return minMs + Int(extra.rounded())
    }

    /// Instant speech score, before the recurrent state. Barge-in uses a higher bar than this score alone.
    static func instant(snr: Float, speechBand: Float, flatness: Float, level: Float) -> Float {
        let snrNorm = min(1, max(0, log2(max(snr, 1)) / 3.5))
        let tonal = 1 - min(1, max(0, flatness))
        let evidence = 2.1 * snrNorm + 1.6 * speechBand + 1.3 * tonal + 0.8 * level - 2.55
        return 1 / (1 + exp(-evidence))
    }

    /// One recurrent step. Weights are fixed so noise and clicks stay quiet and a close voice rises.
    static func recur(_ previous: Float, snr: Float, speechBand: Float, flatness: Float, level: Float) -> Float {
        let instant = instant(snr: snr, speechBand: speechBand, flatness: flatness, level: level)
        return 0.64 * previous + 0.36 * instant
    }
}

/// Synthetic frames used by the simulator test and the in-app timing screen.
enum VoiceTurnFixtures {
    struct Report: Equatable {
        var passed: Bool
        var lines: [String]
    }

    static func run() -> Report {
        var lines: [String] = []
        var passed = true
        func check(_ name: String, _ ok: Bool, _ detail: String) {
            lines.append("\(ok ? "pass" : "fail") \(name): \(detail)")
            if !ok { passed = false }
        }

        let noise = VoiceTurnMeter()
        noise.setPause(0.65)
        var noiseEvents: [VoiceTurnEvent] = []
        for _ in 0..<40 {
            let decision = noise.push(rms: 0.01, speechBand: 0.22, flatness: 0.72, level: 0.08, frameMs: 20, speakerOK: true)
            if let event = decision.event { noiseEvents.append(event) }
        }
        check("room noise", noiseEvents.isEmpty && !noise.snapshot().forwarding, "events \(noiseEvents.count)")

        let click = VoiceTurnMeter()
        click.setPause(0.65)
        for _ in 0..<15 {
            _ = click.push(rms: 0.01, speechBand: 0.22, flatness: 0.72, level: 0.08, frameMs: 20, speakerOK: true)
        }
        var clickEvents: [VoiceTurnEvent] = []
        for _ in 0..<2 {
            let decision = click.push(rms: 0.2, speechBand: 0.18, flatness: 0.82, level: 0.9, frameMs: 20, speakerOK: true)
            if let event = decision.event { clickEvents.append(event) }
        }
        check("click", !clickEvents.contains(.speechBegan) && !clickEvents.contains(.endOfTurn), "events \(clickEvents)")

        let blip = VoiceTurnMeter()
        blip.setPause(0.65)
        for _ in 0..<15 {
            _ = blip.push(rms: 0.01, speechBand: 0.22, flatness: 0.72, level: 0.08, frameMs: 20, speakerOK: true)
        }
        var blipEvents: [VoiceTurnEvent] = []
        for _ in 0..<6 {
            let decision = blip.push(rms: 0.08, speechBand: 0.64, flatness: 0.24, level: 0.42, frameMs: 20, speakerOK: true)
            if let event = decision.event { blipEvents.append(event) }
        }
        // A short burst is rejected only after it has been quiet for the barge window.
        var blipAt: Int?
        for index in 0..<20 {
            let decision = blip.push(rms: 0.01, speechBand: 0.22, flatness: 0.72, level: 0.08, frameMs: 20, speakerOK: true)
            if let event = decision.event {
                blipEvents.append(event)
                if event == .ignoredBurst, blipAt == nil { blipAt = (index + 1) * 20 }
            }
        }
        check("short voice", blipEvents == [.ignoredBurst] && blipAt == 300, "events \(blipEvents) at \(blipAt ?? -1)ms")

        let talk = VoiceTurnMeter()
        talk.setPause(0.65)
        for _ in 0..<15 {
            _ = talk.push(rms: 0.01, speechBand: 0.22, flatness: 0.72, level: 0.08, frameMs: 20, speakerOK: true)
        }
        var beganAt: Int?
        for index in 0..<30 {
            let decision = talk.push(rms: 0.08, speechBand: 0.64, flatness: 0.24, level: 0.42, frameMs: 20, speakerOK: true)
            if decision.event == .speechBegan { beganAt = (index + 1) * 20 }
        }
        let began = beganAt ?? -1
        check("speech starts after 250ms", began >= 250 && began <= 400, "began at \(began)ms")
        var earlyEnd: Int?
        for index in 0..<40 {
            let decision = talk.push(rms: 0.01, speechBand: 0.22, flatness: 0.72, level: 0.08, frameMs: 20, speakerOK: true)
            if decision.event == .endOfTurn { earlyEnd = (index + 1) * 20 }
        }
        check("brief pause stays open", earlyEnd == nil && talk.snapshot().forwarding, "ended \(earlyEnd ?? -1)ms")
        var endedAt: Int?
        for index in 0..<160 {
            let decision = talk.push(rms: 0.01, speechBand: 0.22, flatness: 0.72, level: 0.08, frameMs: 20, speakerOK: true)
            if decision.event == .endOfTurn { endedAt = (40 + index + 1) * 20 }
        }
        let expectedPause = VoiceTurnMeter.endpointDelayMs(minSeconds: 0.65, eagerness: .medium, endProbability: nil)
        let pauseGap = abs((endedAt ?? -1_000) - expectedPause)
        check("mid-sentence hangover", pauseGap <= 20 && expectedPause > 800, "silence \(endedAt ?? -1)ms, expected \(expectedPause)ms")

        let sentence = VoiceTurnMeter()
        sentence.setPause(0.65)
        sentence.setEagerness(.medium)
        sentence.noteTranscript("That is all.")
        for _ in 0..<15 {
            _ = sentence.push(rms: 0.01, speechBand: 0.22, flatness: 0.72, level: 0.08, frameMs: 20, speakerOK: true)
        }
        for _ in 0..<30 {
            _ = sentence.push(rms: 0.08, speechBand: 0.64, flatness: 0.24, level: 0.42, frameMs: 20, speakerOK: true)
        }
        var sentenceEnd: Int?
        for index in 0..<40 {
            let decision = sentence.push(rms: 0.01, speechBand: 0.22, flatness: 0.72, level: 0.08, frameMs: 20, speakerOK: true)
            if decision.event == .endOfTurn { sentenceEnd = (index + 1) * 20 }
        }
        let expectedSentence = VoiceTurnMeter.endpointDelayMs(
            minSeconds: 0.65, eagerness: .medium, endProbability: SemanticTurn.probability("That is all."))
        let sentenceGap = abs((sentenceEnd ?? -1_000) - expectedSentence)
        check("finished sentence", sentenceGap <= 20, "silence \(sentenceEnd ?? -1)ms, expected \(expectedSentence)ms")

        let unfinished = VoiceTurnMeter.endpointDelayMs(
            minSeconds: 0.65, eagerness: .medium, endProbability: SemanticTurn.probability("and then"))
        let eager = VoiceTurnMeter.endpointDelayMs(
            minSeconds: 0.65, eagerness: .high, endProbability: SemanticTurn.probability("and then"))
        let patient = VoiceTurnMeter.endpointDelayMs(
            minSeconds: 0.65, eagerness: .low, endProbability: SemanticTurn.probability("and then"))
        check("unfinished waits", unfinished > expectedSentence && unfinished <= TurnEagerness.medium.maxTimeoutMs,
              "unfinished \(unfinished)ms")
        check("eagerness", eager < unfinished && patient > unfinished && eager <= TurnEagerness.high.maxTimeoutMs
              && patient <= TurnEagerness.low.maxTimeoutMs,
              "high \(eager)ms medium \(unfinished)ms low \(patient)ms")

        let other = VoiceTurnMeter()
        other.setPause(0.65)
        for _ in 0..<15 {
            _ = other.push(rms: 0.01, speechBand: 0.22, flatness: 0.72, level: 0.08, frameMs: 20, speakerOK: true)
        }
        var otherEvents: [VoiceTurnEvent] = []
        for _ in 0..<30 {
            let decision = other.push(rms: 0.08, speechBand: 0.64, flatness: 0.24, level: 0.42, frameMs: 20, speakerOK: false)
            if let event = decision.event { otherEvents.append(event) }
            if decision.forwardsAudio { otherEvents.append(.speechBegan) }
        }
        check("other speaker", !otherEvents.contains(.speechBegan), "events \(otherEvents.count)")

        let far = VoiceTurnMeter()
        far.setPause(0.65)
        for _ in 0..<15 {
            _ = far.push(rms: 0.01, speechBand: 0.22, flatness: 0.72, level: 0.08, frameMs: 20, speakerOK: true)
        }
        var farForward = false
        for _ in 0..<30 {
            let decision = far.push(rms: 0.016, speechBand: 0.55, flatness: 0.4, level: 0.2, frameMs: 20, speakerOK: true)
            if decision.forwardsAudio { farForward = true }
        }
        check("far-field", !farForward, "forwarded \(farForward)")

        let barge = VoiceTurnMeter()
        barge.setEchoCancelled(true)
        barge.setAssistantSpeaking(true)
        for _ in 0..<15 {
            _ = barge.push(rms: 0.01, speechBand: 0.22, flatness: 0.72, level: 0.08, frameMs: 20, speakerOK: true)
        }
        var bargeAt: Int?
        var bargeCount = 0
        for index in 0..<20 {
            let decision = barge.push(rms: 0.09, speechBand: 0.66, flatness: 0.22, level: 0.5, frameMs: 20, speakerOK: true)
            if decision.event == .barge {
                bargeCount += 1
                if bargeAt == nil { bargeAt = (index + 1) * 20 }
            }
        }
        check("barge-in", bargeCount == 1 && (bargeAt == 300 || bargeAt == 280 || bargeAt == 320), "at \(bargeAt ?? -1)ms")

        let leaked = VoiceTurnMeter()
        leaked.setEchoCancelled(false)
        leaked.setAssistantSpeaking(true)
        for _ in 0..<15 {
            _ = leaked.push(rms: 0.01, speechBand: 0.22, flatness: 0.72, level: 0.08, frameMs: 20, speakerOK: true)
        }
        var leakedEvents: [VoiceTurnEvent] = []
        for _ in 0..<20 {
            let decision = leaked.push(rms: 0.09, speechBand: 0.66, flatness: 0.22, level: 0.5, frameMs: 20, speakerOK: true)
            if let event = decision.event { leakedEvents.append(event) }
        }
        check("barge without echo cancellation", leakedEvents.isEmpty, "events \(leakedEvents)")

        let echo = VoiceTurnMeter()
        echo.setEchoCancelled(true)
        echo.setAssistantSpeaking(true)
        for _ in 0..<15 {
            _ = echo.push(rms: 0.01, speechBand: 0.22, flatness: 0.72, level: 0.08, frameMs: 20, speakerOK: true)
        }
        var echoEvents: [VoiceTurnEvent] = []
        for _ in 0..<20 {
            let decision = echo.push(rms: 0.02, speechBand: 0.5, flatness: 0.4, level: 0.25, frameMs: 20, speakerOK: true)
            if let event = decision.event { echoEvents.append(event) }
        }
        check("echo", !echoEvents.contains(.barge), "events \(echoEvents)")

        lines.insert("Before this meter: energy gate, 800ms minimum, 1750ms silence, barge at 250ms without an echo-cancellation gate.", at: 0)
        lines.insert(passed ? "Voice turn fixtures passed." : "Voice turn fixtures failed.", at: 0)
        return Report(passed: passed, lines: lines)
    }
}

/// Limits main-thread level updates to about 20 times a second. The ring reads VoiceMeter directly.
final class LevelCoalescer: @unchecked Sendable {
    private let lock = NSLock()
    private var last = 0.0

    func allow(interval: TimeInterval = 0.05) -> Bool {
        let now = Date().timeIntervalSinceReferenceDate
        lock.lock()
        defer { lock.unlock() }
        if now - last < interval { return false }
        last = now
        return true
    }
}
