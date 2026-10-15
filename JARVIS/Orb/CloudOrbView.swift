import simd
import SwiftUI

enum VoiceLook {
    static let core = Color(red: 110.0 / 255.0, green: 123.0 / 255.0, blue: 1.0)
    static let mid = Color(red: 169.0 / 255.0, green: 184.0 / 255.0, blue: 1.0)
    static let mist = Color(red: 233.0 / 255.0, green: 238.0 / 255.0, blue: 1.0)
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
        let dt: Double = last.map { date.timeIntervalSince($0) } ?? 0.0
        last = date
        let tau: Double = level > smooth ? 0.05 : 0.25
        let step: Double = min(1.0, dt / tau)
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
        TimelineView(.animation(minimumInterval: frameInterval, paused: paused)) { timeline in
            voiceFrame(date: timeline.date)
        }
        .accessibilityLabel("Voice orb")
    }

    private var frameInterval: Double {
        if paused { return 1.0 }
        return 1.0 / 30.0
    }

    private func voiceFrame(date: Date) -> some View {
        let time: Double = date.timeIntervalSinceReferenceDate
        let smoothed: Double = meter.push(level, at: date)
        let advanced: Double = time * cloudSpeed
        let muted: Double = state == .muted ? 0.15 : 1.0
        let scaled: CGFloat = scale(time: time, level: smoothed)
        let fade: Double = opacity(time: time)
        let tilt: Double = hue(time: time)
        return orb(time: advanced)
            .scaleEffect(scaled)
            .opacity(fade)
            .saturation(muted)
            .hueRotation(.degrees(tilt))
    }

    private func orb(time: Double) -> some View {
        GeometryReader { geo in
            orbLayers(side: min(geo.size.width, geo.size.height), time: time)
                .frame(width: geo.size.width, height: geo.size.height)
        }
    }

    private func orbLayers(side: CGFloat, time: Double) -> some View {
        let bandW: CGFloat = side * 1.15
        let bandH: CGFloat = side * 0.45
        let bandY: CGFloat = side * 0.30
        return ZStack {
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
                        .frame(width: bandW, height: bandH)
                        .blur(radius: 10)
                        .offset(y: bandY)
                    clouds(side: side, time: time)
                }
                .clipShape(Circle())
        }
    }

    private func clouds(side: CGFloat, time: Double) -> some View {
        ZStack {
            ForEach(0..<Self.cloudSeeds.count, id: \.self) { index in
                cloudBlob(index: index, side: side, time: time)
            }
        }
    }

    private func cloudBlob(index: Int, side: CGFloat, time: Double) -> some View {
        let seed = Self.cloudSeeds[index]
        let turn: Double = 2.0 * Double.pi
        let xPhase: Double = time * turn / seed.0 + seed.1
        let yPeriod: Double = seed.0 + 1.3
        let yPhase: Double = time * turn / yPeriod + seed.1
        let x: CGFloat = CGFloat(sin(xPhase)) * side * 0.16
        let yWave: CGFloat = CGFloat(cos(yPhase)) * side * 0.08
        let y: CGFloat = yWave + side * 0.16
        let blob: CGFloat = side * seed.2
        let blobH: CGFloat = blob * 0.62
        return Ellipse()
            .fill(.white.opacity(0.9))
            .frame(width: blob, height: blobH)
            .blur(radius: seed.3)
            .offset(x: x, y: y)
    }

    private static let cloudSeeds: [(Double, Double, CGFloat, CGFloat)] = [
        (6.0, 0.2, 0.34, 8.0),
        (7.5, 1.4, 0.28, 10.0),
        (9.0, 2.2, 0.40, 12.0),
        (10.0, 3.1, 0.24, 14.0),
    ]

    private func scale(time: Double, level: Double) -> CGFloat {
        switch state {
        case .userSpeaking:
            let grown: Double = 1.0 + 0.08 * level
            return CGFloat(grown)
        case .thinking:
            let phase: Double = time * (2.0 * Double.pi / 1.2)
            let value: Double = 0.99 + 0.03 * sin(phase)
            return CGFloat(value)
        case .aiSpeaking:
            let grown: Double = 1.0 + 0.18 * level
            return CGFloat(grown)
        case .muted:
            return 0.92
        case .off, .ended, .error:
            return 1.0
        case .connecting, .listening:
            let phase: Double = time * (2.0 * Double.pi / 4.0)
            let value: Double = 1.0 + 0.02 * sin(phase)
            return CGFloat(value)
        }
    }

    private var cloudSpeed: Double {
        switch state {
        case .listening, .off, .ended, .error: return 0.3
        case .userSpeaking: return 0.6
        case .thinking: return 1.5
        case .aiSpeaking: return 1.0
        case .muted: return 0.2
        case .connecting: return 0.3
        }
    }

    private func hue(time: Double) -> Double {
        guard state == .thinking else { return 0.0 }
        let phase: Double = time * (2.0 * Double.pi / 1.2)
        return 10.0 * sin(phase)
    }

    private func opacity(time: Double) -> Double {
        guard state == .connecting else { return 1.0 }
        let wave: Double = abs(sin(time * Double.pi))
        return 0.55 + 0.45 * wave
    }
}
