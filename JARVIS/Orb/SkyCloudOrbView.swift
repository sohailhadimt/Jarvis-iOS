import simd
import SwiftUI

/// Hard-edged sky circle. `boost` speeds the shader clock and the swirl.
struct SkyCloudOrbView: View {
    var level: Double
    var state: VoiceState
    var closing: Bool = false

    @State private var meter = LevelSmooth()
    @State private var closeScale: CGFloat = 1
    @State private var closeOpacity: Double = 1

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
            let date = timeline.date
            let time = date.timeIntervalSinceReferenceDate
            let smoothed = meter.push(min(1, max(0, level)), at: date)
            let boost = Self.boost(state: state, level: smoothed)
            let bob = sin(time * 2 * .pi / 3) * 10
            let breathe = 1 + 0.025 * (1 + sin(time * 2 * .pi / 4))
            GeometryReader { geo in
                Rectangle()
                    .fill(Color(red: 0.0, green: 0.35, blue: 0.9))
                    .colorEffect(
                        ShaderLibrary.default.skyClouds(
                            .float(Float(time)),
                            .float(boost),
                            .float2(SIMD2(Float(geo.size.width), Float(geo.size.height)))
                        )
                    )
            }
            .clipShape(Circle())
            .scaleEffect(breathe)
            .offset(y: bob)
        }
        .scaleEffect(closing ? closeScale : 1)
        .opacity(closing ? closeOpacity : 1)
        .onChange(of: closing) { _, isClosing in
            guard isClosing else { return }
            withAnimation(.easeIn(duration: 0.14)) {
                closeScale = 0.05
                closeOpacity = 0
            }
        }
        .accessibilityLabel("Voice orb")
    }

    /// Speaking maps the smoothed voice level onto 0...2. Listening only nudges it.
    private static func boost(state: VoiceState, level: Double) -> Float {
        switch state {
        case .aiSpeaking:
            return Float(level * 2)
        case .userSpeaking:
            return Float(level * 0.45)
        case .listening:
            return Float(level * 0.22)
        case .thinking:
            return 0.12
        case .connecting:
            return 0.06
        case .muted, .off, .ended, .error:
            return 0
        }
    }
}

/// Attack 0.05s, release 0.25s, so the boost follows the voice instead of the raw samples.
private final class LevelSmooth {
    var value = 0.0
    var last: Date?

    func push(_ target: Double, at date: Date) -> Double {
        let dt = last.map { date.timeIntervalSince($0) } ?? 0
        last = date
        let tau = target > value ? 0.05 : 0.25
        let step = min(1, dt / max(tau, 0.0001))
        value += (target - value) * step
        return value
    }
}
