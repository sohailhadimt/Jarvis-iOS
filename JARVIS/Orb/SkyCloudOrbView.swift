import simd
import SwiftUI

/// Hard-edged sky circle. The cloud field is the stitchable Metal shader `skyClouds`.
struct SkyCloudOrbView: View {
    var level: Double
    var state: VoiceState

    var body: some View {
        let motion = Self.motion(state: state, level: level)
        GeometryReader { geo in
            TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
                let time = Float(timeline.date.timeIntervalSinceReferenceDate)
                Rectangle()
                    .fill(Color(red: 0.294, green: 0.659, blue: 0.933))
                    .colorEffect(
                        ShaderLibrary.default.skyClouds(
                            .float(time),
                            .float(motion.speed),
                            .float(motion.swell),
                            .float(Float(min(1, max(0, level)))),
                            .float2(SIMD2(Float(geo.size.width), Float(geo.size.height)))
                        )
                    )
            }
        }
        .clipShape(Circle())
        .scaleEffect(motion.scale)
        .accessibilityLabel("Voice orb")
    }

    private static func motion(state: VoiceState, level: Double) -> (speed: Float, swell: Float, scale: CGFloat) {
        let loud = min(1, max(0, level))
        switch state {
        case .aiSpeaking:
            return (Float(0.42 + loud * 0.7), Float(0.28 + loud * 0.72), 1 + 0.05 * loud)
        case .userSpeaking:
            return (Float(0.16 + loud * 0.14), Float(loud * 0.18), 1 + 0.02 * loud)
        case .listening:
            return (Float(0.14 + loud * 0.08), Float(loud * 0.08), 1 + 0.012 * loud)
        case .thinking:
            return (Float(0.22), Float(0.12), 1.015)
        case .connecting:
            return (Float(0.18), Float(0.05), 1)
        case .muted, .off, .ended, .error:
            return (Float(0.055), Float(0), 1)
        }
    }
}
