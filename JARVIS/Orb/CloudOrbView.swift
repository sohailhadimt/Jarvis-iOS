import simd
import SwiftUI

enum VoiceLook {
    static let core = Color(red: 110.0 / 255, green: 123.0 / 255, blue: 1)
    static let mid = Color(red: 169.0 / 255, green: 184.0 / 255, blue: 1)
    static let mist = Color(red: 233.0 / 255, green: 238.0 / 255, blue: 1)
    static let ink = Color.black
    /// Dock chrome. Kept so the home buttons stay readable on the black home screen.
    static let blue = Color(red: 0.22, green: 0.47, blue: 1)
    static let lavender = Color(red: 0.73, green: 0.62, blue: 1)
}

/// ChatGPT cloud. Home still uses this when Orb style is ChatGPT; classic keeps the Metal orb.
struct CloudOrbView: View {
    var level: Double
    var phase: JarvisPhase
    var sessionActive: Bool = false
    var executing: Bool = false
    var hasError: Bool = false
    var paused: Bool = false

    var body: some View {
        VoiceOrbView(level: level, state: mapped, paused: paused)
    }

    private var mapped: VoiceState {
        if hasError { return .error }
        if executing || phase == .thinking { return .thinking }
        switch phase {
        case .speaking: return .aiSpeaking
        case .listening: return sessionActive ? .userSpeaking : .listening
        case .idle: return .listening
        case .thinking: return .thinking
        }
    }
}

/// Attack 0.05s, release 0.25s. A class so the timeline can update it without invalidating the view.
private final class OrbMeter {
    var smooth = 0.0
    var last: Date?

    func push(_ level: Double, at date: Date) -> Double {
        let dt = last.map { date.timeIntervalSince($0) } ?? 0
        last = date
        let tau = level > smooth ? 0.05 : 0.25
        let step = min(1, dt / tau)
        smooth += (level - smooth) * step
        return smooth
    }
}

/// Circle cloud: blue mesh, a white layer in the lower 45%, and three or four drifting ellipses.
struct VoiceOrbView: View {
    var level: Double
    var state: VoiceState
    var paused: Bool = false

    @State private var meter = OrbMeter()

    var body: some View {
        TimelineView(.animation(minimumInterval: paused ? 1 : 1.0 / 30.0, paused: paused)) { timeline in
            let time = timeline.date.timeIntervalSinceReferenceDate
            let smoothed = meter.push(level, at: timeline.date)
            let speed = cloudSpeed
            orb(time: time * speed)
                .scaleEffect(scale(time: time, level: smoothed))
                .opacity(opacity(time: time))
                .saturation(state == .muted ? 0.15 : 1)
                .hueRotation(.degrees(hue(time: time)))
        }
        .accessibilityLabel("Voice orb")
    }

    private func orb(time: Double) -> some View {
        GeometryReader { geo in
            let side = min(geo.size.width, geo.size.height)
            ZStack {
                Circle()
                    .fill(VoiceLook.core)
                    .blur(radius: 20)
                    .opacity(0.25)
                    .scaleEffect(1.18)
                ZStack {
                    MeshGradient(
                        width: 3,
                        height: 3,
                        points: [
                            SIMD2(0, 0), SIMD2(0.5, 0), SIMD2(1, 0),
                            SIMD2(0, 0.45), SIMD2(0.5, 0.5), SIMD2(1, 0.45),
                            SIMD2(0, 1), SIMD2(0.5, 1), SIMD2(1, 1),
                        ],
                        colors: [
                            VoiceLook.core, VoiceLook.mid, VoiceLook.core,
                            VoiceLook.mid, VoiceLook.mist, VoiceLook.mid,
                            VoiceLook.mist, VoiceLook.mid, VoiceLook.core,
                        ]
                    )
                    Ellipse()
                        .fill(.white.opacity(0.72))
                        .frame(width: side * 1.15, height: side * 0.45)
                        .blur(radius: 10)
                        .offset(y: side * 0.30)
                    clouds(side: side, time: time)
                }
                .clipShape(Circle())
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
    }

    private func clouds(side: CGFloat, time: Double) -> some View {
        let seeds: [(Double, Double, CGFloat, CGFloat)] = [
            (6.0, 0.2, 0.34, 8),
            (7.5, 1.4, 0.28, 10),
            (9.0, 2.2, 0.40, 12),
            (10.0, 3.1, 0.24, 14),
        ]
        return ZStack {
            ForEach(0..<seeds.count, id: \.self) { index in
                let seed = seeds[index]
                let x = sin(time * (.pi * 2) / seed.0 + seed.1) * side * 0.16
                let y = cos(time * (.pi * 2) / (seed.0 + 1.3) + seed.1) * side * 0.08 + side * 0.16
                Ellipse()
                    .fill(.white.opacity(0.9))
                    .frame(width: side * seed.2, height: side * seed.2 * 0.62)
                    .blur(radius: seed.3)
                    .offset(x: x, y: y)
            }
        }
    }

    private func scale(time: Double, level: Double) -> CGFloat {
        switch state {
        case .userSpeaking:
            return 1 + 0.08 * level
        case .thinking:
            return 0.99 + 0.03 * sin(time * (.pi * 2) / 1.2)
        case .aiSpeaking:
            return 1 + 0.18 * level
        case .muted:
            return 0.92
        case .off, .ended, .error:
            return 1
        case .connecting, .listening:
            return 1 + 0.02 * sin(time * (.pi * 2) / 4)
        }
    }

    private var cloudSpeed: Double {
        switch state {
        case .listening, .off, .ended, .error: return 0.3
        case .userSpeaking: return 0.6
        case .thinking: return 1.5
        case .aiSpeaking: return 1
        case .muted: return 0.2
        case .connecting: return 0.3
        }
    }

    private func hue(time: Double) -> Double {
        guard state == .thinking else { return 0 }
        return 10 * sin(time * (.pi * 2) / 1.2)
    }

    private func opacity(time: Double) -> Double {
        guard state == .connecting else { return 1 }
        return 0.55 + 0.45 * abs(sin(time * .pi))
    }
}
