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
    @State private var clockOrigin = Date()
    @State private var closeScale: CGFloat = 1
    @State private var closeOpacity: Double = 1

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: false)) { timeline in
            orbBody(date: timeline.date)
        }
        .scaleEffect(closing ? closeScale : CGFloat(1))
        .opacity(closing ? closeOpacity : 1.0)
        .onChange(of: closing) { _, isClosing in
            guard isClosing else { return }
            withAnimation(.easeIn(duration: 0.14)) {
                closeScale = 0.05
                closeOpacity = 0
            }
        }
        .accessibilityLabel("Voice orb")
    }

    /// Values are computed here, then one view is returned. The timeline closure stays a single call.
    private func orbBody(date: Date) -> some View {
        let crisp: Bool = crispEdge ?? (colorScheme != .light)
        let feather: Float = crisp ? 0.0 : 0.1
        // Seconds since this view appeared. A raw reference-date does not fit in
        // the shader's 32-bit clock, so sin/cos freeze and the disc looks still.
        let t: Double = max(0.0, date.timeIntervalSince(clockOrigin))
        let speaking: Bool = state == .aiSpeaking
        let clamped: Double = min(1.0, max(0.0, level))
        let target: Double = speaking ? clamped : 0.0
        let envelope: Double = meter.push(target, at: date)
        let phase: Double = t * (2.0 * Double.pi / 4.0)
        let breathe: Double = 1.0 + 0.02 * sin(phase)
        let pulse: Double = 1.0 + 0.12 * envelope
        let chosen: Double = envelope > 0.02 ? pulse : breathe
        let scale: CGFloat = CGFloat(chosen)
        return SkyCloudDisc(
            time: Float(t),
            scale: scale,
            tint: Self.rgb(tint),
            tintAmount: Float(tintAmount),
            feather: feather
        )
    }

    private static func rgb(_ color: Color) -> SIMD3<Float> {
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        let ui = UIColor(color)
        if ui.getRed(&red, green: &green, blue: &blue, alpha: &alpha) {
            return SIMD3<Float>(Float(red), Float(green), Float(blue))
        }
        let converted = ui.cgColor.converted(to: CGColorSpaceCreateDeviceRGB(), intent: .defaultIntent, options: nil)
        if let comps = converted?.components, comps.count >= 3 {
            return SIMD3<Float>(Float(comps[0]), Float(comps[1]), Float(comps[2]))
        }
        return SIMD3<Float>(0.1, 0.65, 1.0)
    }
}

/// The drawn disc. GeometryReader only forwards the size into `painted`.
private struct SkyCloudDisc: View {
    var time: Float
    var scale: CGFloat
    var tint: SIMD3<Float>
    var tintAmount: Float
    var feather: Float

    var body: some View {
        GeometryReader { geo in
            painted(width: Float(geo.size.width), height: Float(geo.size.height))
        }
        .clipShape(Circle())
        .scaleEffect(scale)
    }

    /// Matches `skyClouds(position, color, time, size, tint, tintAmount, feather)`.
    /// SwiftUI supplies position and color; the rest are explicit Float arguments.
    private func painted(width: Float, height: Float) -> some View {
        let side: CGFloat = CGFloat(min(width, height))
        return ZStack {
            LinearGradient(
                colors: [
                    Color(red: 0.0, green: 0.22, blue: 0.72),
                    Color(red: 0.15, green: 0.55, blue: 0.95),
                ],
                startPoint: .bottom,
                endPoint: .top
            )
            fallbackCloud(side: side, phase: 0.2, widthScale: 0.72, heightScale: 0.40)
            fallbackCloud(side: side, phase: 2.4, widthScale: 0.5, heightScale: 0.28)
            fallbackCloud(side: side, phase: 4.1, widthScale: 0.34, heightScale: 0.22)
        }
        .colorEffect(
            ShaderLibrary.default.skyClouds(
                .float(time),
                .float2(width, height),
                .float3(tint.x, tint.y, tint.z),
                .float(tintAmount),
                .float(feather)
            )
        )
    }

    /// Shown only if the stitchable shader does not replace the view.
    private func fallbackCloud(side: CGFloat, phase: Double, widthScale: CGFloat, heightScale: CGFloat) -> some View {
        let seconds: Double = Double(time)
        let angle: Double = seconds * 0.35 + phase
        let x: CGFloat = CGFloat(sin(angle)) * side * 0.14
        let y: CGFloat = CGFloat(cos(angle * 0.8)) * side * 0.1
        let blobW: CGFloat = side * widthScale
        let blobH: CGFloat = side * heightScale
        return Ellipse()
            .fill(Color.white.opacity(0.88))
            .frame(width: blobW, height: blobH)
            .blur(radius: 10)
            .offset(x: x, y: y)
    }
}

/// Attack 30ms, release 120ms, used only for the assistant's speech scale.
private final class LevelSmooth {
    var value: Double = 0.0
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
