import SwiftUI

/// Non-animated orb used in widgets, Live Activities and the reply card.
/// WidgetKit can't run the home screen's particle field, so this is the still version of it.
struct StaticOrb: View {
    var phase: JarvisPhase = .idle
    var primary: Color = Color(hex: SharedConfig.defaults.string(forKey: SharedConfig.Key.primaryHex) ?? Theme.defaultPrimaryHex)
    var accent: Color = Color(hex: SharedConfig.defaults.string(forKey: SharedConfig.Key.accentHex) ?? Theme.defaultAccentHex)

    var body: some View {
        GeometryReader { geo in
            let d = min(geo.size.width, geo.size.height)
            ZStack {
                Circle()
                    .fill(RadialGradient(colors: [primary.opacity(0.45), .clear],
                                         center: .center, startRadius: 0, endRadius: d * 0.5))
                Circle()
                    .stroke(primary.opacity(0.35), lineWidth: max(0.5, d * 0.015))
                    .frame(width: d * 0.86, height: d * 0.86)
                Circle()
                    .stroke(primary.opacity(phase == .idle ? 0.75 : 1), lineWidth: max(1, d * 0.035))
                    .frame(width: d * 0.68, height: d * 0.68)
                Circle()
                    .fill(RadialGradient(colors: [.white, primary.opacity(0.9), primary.opacity(0.15)],
                                         center: .center, startRadius: 0, endRadius: d * 0.16))
                    .frame(width: d * 0.28, height: d * 0.28)
                Circle()
                    .stroke(accent.opacity(0.8), lineWidth: max(0.5, d * 0.012))
                    .frame(width: d * 0.34, height: d * 0.34)
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .aspectRatio(1, contentMode: .fit)
    }
}
