import simd
import SwiftUI
import UIKit

/// Sky circle. Cloud motion is constant. Only assistant speech scales the whole orb.
struct SkyCloudOrbView: View {
    var level: Double
    var state: VoiceState
    var closing: Bool = false
    var tint: Color = Color(red: 0.1, green: 0.65, blue: 1)
    var tintAmount: Double = 0
    /// Black screenshots stay crisp. Pass false on a light background for a soft rim.
    var crispEdge: Bool? = nil

    @Environment(\.colorScheme) private var colorScheme
    @State private var meter = LevelSmooth()
    @State private var closeScale: CGFloat = 1
    @State private var closeOpacity: Double = 1

    var body: some View {
        let crisp: Bool = crispEdge ?? (colorScheme != .light)
        let feather: Float = crisp ? 0.0 : 0.1
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
            let date: Date = timeline.date
            let t: Double = date.timeIntervalSinceReferenceDate
            let speaking: Bool = state == .aiSpeaking
            let clamped: Double = min(1.0, max(0.0, level))
            let target: Double = speaking ? clamped : 0.0
            let envelope: Double = meter.push(target, at: date)
            let phase: Double = t * (2.0 * Double.pi / 4.0)
            let breathe: Double = 1.0 + 0.02 * sin(phase)
            let pulse: Double = 1.0 + 0.12 * envelope
            let chosen: Double = envelope > 0.02 ? pulse : breathe
            let scale: CGFloat = CGFloat(chosen)
            GeometryReader { geo in
                let sideW: Float = Float(geo.size.width)
                let sideH: Float = Float(geo.size.height)
                Rectangle()
                    .fill(Color(red: 0.0, green: 0.35, blue: 0.9))
                    .colorEffect(
                        ShaderLibrary.default.skyClouds(
                            .float(Float(t)),
                            .float2(SIMD2(sideW, sideH)),
                            .float3(Self.rgb(tint)),
                            .float(Float(tintAmount)),
                            .float(feather)
                        )
                    )
            }
            .clipShape(Circle())
            .scaleEffect(scale)
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

    private static func rgb(_ color: Color) -> SIMD3<Float> {
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        let ui = UIColor(color)
        if ui.getRed(&red, green: &green, blue: &blue, alpha: &alpha) {
            return SIMD3(Float(red), Float(green), Float(blue))
        }
        let converted = ui.cgColor.converted(to: CGColorSpaceCreateDeviceRGB(), intent: .defaultIntent, options: nil)
        if let comps = converted?.components, comps.count >= 3 {
            return SIMD3(Float(comps[0]), Float(comps[1]), Float(comps[2]))
        }
        return SIMD3(0.1, 0.65, 1)
    }

}

/// Attack 30ms, release 120ms, used only for the assistant's speech scale.
private final class LevelSmooth {
    var value = 0.0
    var last: Date?

    func push(_ target: Double, at date: Date) -> Double {
        let dt: Double = last.map { date.timeIntervalSince($0) } ?? 0.0
        last = date
        let tau: Double = target > value ? 0.030 : 0.120
        let floor: Double = max(tau, 0.0001)
        let step: Double = min(1.0, dt / floor)
        value += (target - value) * step
        return value
    }
}
