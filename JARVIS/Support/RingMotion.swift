import Foundation

/// Eased follow of playback level, microphone level, or a slow idle breath.
/// The display link calls `sample` once per frame. It allocates nothing.
final class RingMotion {
    private(set) var value = 0.22
    private var stamp: TimeInterval = 0

    func sample(level: Double, phase: JarvisPhase, now: TimeInterval) -> Double {
        let dt = stamp == 0 ? 1.0 / 120.0 : min(0.05, max(0.001, now - stamp))
        stamp = now
        let clamped = min(1, max(0, level))
        let target: Double
        let tau: Double
        switch phase {
        case .speaking:
            target = 0.34 + clamped * 0.66
            tau = 0.055
        case .listening:
            target = 0.18 + clamped * 0.28
            tau = 0.14
        case .thinking:
            target = 0.28 + 0.05 * (0.5 + 0.5 * sin(now * 2.2))
            tau = 0.18
        case .idle:
            target = 0.18 + 0.07 * (0.5 + 0.5 * sin(now * 0.85))
            tau = 0.45
        }
        let alpha = 1 - exp(-dt / tau)
        value += (target - value) * alpha
        if value < 0 { value = 0 }
        if value > 1.15 { value = 1.15 }
        return value
    }
}

/// Latest level and phase for the ring. The audio callback writes it; the display link reads it.
/// SwiftUI does not observe this, so a meter tick does not rebuild the home screen.
final class VoiceMeter: @unchecked Sendable {
    static let shared = VoiceMeter()

    private let lock = NSLock()
    private var storedLevel = 0.0
    private var storedPhase: JarvisPhase = .idle

    var level: Double {
        get {
            lock.lock()
            defer { lock.unlock() }
            return storedLevel
        }
        set {
            lock.lock()
            storedLevel = newValue
            lock.unlock()
        }
    }

    var phase: JarvisPhase {
        get {
            lock.lock()
            defer { lock.unlock() }
            return storedPhase
        }
        set {
            lock.lock()
            storedPhase = newValue
            lock.unlock()
        }
    }
}
