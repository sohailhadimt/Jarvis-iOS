import SwiftUI

/// Non-animated orb used in widgets / Live Activities (WidgetKit can't run continuous animations).
struct StaticOrb: View {
    var phase: JarvisPhase = .idle
    var primary: Color = Color(hex: SharedConfig.defaults.string(forKey: SharedConfig.Key.primaryHex) ?? Theme.defaultPrimaryHex)
    var accent: Color = Color(hex: SharedConfig.defaults.string(forKey: SharedConfig.Key.accentHex) ?? Theme.defaultAccentHex)

    var body: some View {
        GeometryReader { geo in
            let d = min(geo.size.width, geo.size.height)
            ZStack {
                Circle()
                    .fill(RadialGradient(colors: [primary.opacity(0.55), .clear],
                                         center: .center, startRadius: 0, endRadius: d * 0.5))
                Circle()
                    .fill(RadialGradient(colors: [.white, primary, primary.opacity(0.3)],
                                         center: .center, startRadius: 0, endRadius: d * 0.3))
                    .frame(width: d * 0.62, height: d * 0.62)
                Circle()
                    .stroke(accent.opacity(phase == .idle ? 0.5 : 0.95), lineWidth: max(1, d * 0.04))
                    .frame(width: d * 0.78, height: d * 0.78)
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .aspectRatio(1, contentMode: .fit)
    }
}
