import SwiftUI
import UIKit

/// Still frame of the geodesic orb for widgets, Live Activities and the reply card.
/// WidgetKit does not run the home screen's 60 fps timeline.
struct StaticOrb: View {
    var phase: JarvisPhase = .idle
    var primary: Color = Color(hex: SharedConfig.defaults.string(forKey: SharedConfig.Key.primaryHex) ?? Theme.defaultPrimaryHex)
    var accent: Color = Color(hex: SharedConfig.defaults.string(forKey: SharedConfig.Key.accentHex) ?? Theme.defaultAccentHex)

    var body: some View {
        Canvas { context, size in
            paint(context: &context, size: size)
        }
        .aspectRatio(1, contentMode: .fit)
        .accessibilityLabel("JARVIS")
    }

    private func paint(context: inout GraphicsContext, size: CGSize) {
        let stored: Double = SharedConfig.defaults.object(forKey: SharedConfig.Key.orbTintAmount) as? Double ?? 0.0
        let mix: Double = stored >= 0.5 ? 0.85 : 0.18
        let amplitude: Double = Self.amp(phase)
        let loudness: Double = Self.level(phase)
        let palette = OrbPalette.reference.tinted(with: Self.components(primary), amount: mix)
        OrbRenderer.draw(ctx: &context, size: size, time: 9.2,
                         amp: amplitude, glow: 0.6, level: loudness, flow: 0.35,
                         palette: palette, detailed: false)
    }

    private static func amp(_ phase: JarvisPhase) -> Double {
        switch phase {
        case .idle: 0.12
        case .listening: 0.45
        case .thinking: 0.32
        case .speaking: 0.55
        }
    }

    private static func level(_ phase: JarvisPhase) -> Double {
        switch phase {
        case .listening, .speaking: 0.55
        case .idle, .thinking: 0.0
        }
    }

    private static func components(_ color: Color) -> (Double, Double, Double) {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        if UIColor(color).getRed(&r, green: &g, blue: &b, alpha: &a) {
            return (Double(r), Double(g), Double(b))
        }
        return (0.247, 0.847, 0.878)
    }
}
