import SwiftUI

/// Metal orb used on the home screen, in StandBy and in the appearance preview.
/// `level` is the smoothed RMS from the mic tap (listening) or the speech player (speaking).
struct OrbView: View {
    var level: Double
    var phase: JarvisPhase
    var primary: Color
    var accent: Color
    var sessionActive: Bool = false
    var executing: Bool = false
    var hasError: Bool = false
    var reply: String = ""

    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        MetalOrbView(level: level, phase: phase, sessionActive: sessionActive,
                     executing: executing, hasError: hasError, reply: reply,
                     paused: scenePhase != .active)
            .accessibilityLabel("JARVIS is \(phase.label.lowercased())")
    }
}

/// Thin HUD rings and crosshair drawn over the orb on the home screen.
struct OrbReticle: View {
    var color: Color

    var body: some View {
        GeometryReader { geo in
            let s = min(geo.size.width, geo.size.height)
            ZStack {
                Circle()
                    .stroke(color.opacity(0.18), lineWidth: 1)
                    .frame(width: s * 0.72, height: s * 0.72)
                Circle()
                    .stroke(color.opacity(0.28), style: StrokeStyle(lineWidth: 1, dash: [2, 5]))
                    .frame(width: s * 0.9, height: s * 0.9)
                ForEach(0..<4, id: \.self) { i in
                    Circle()
                        .trim(from: 0.04, to: 0.2)
                        .stroke(color.opacity(0.7), style: StrokeStyle(lineWidth: 1.4, lineCap: .round))
                        .rotationEffect(.degrees(Double(i) * 90 + 18))
                        .frame(width: s * 0.98, height: s * 0.98)
                }
                Path { p in
                    let c = CGPoint(x: geo.size.width / 2, y: geo.size.height / 2)
                    let gap = s * 0.56
                    let len = s * 0.07
                    p.move(to: CGPoint(x: c.x - gap / 2 - len, y: c.y))
                    p.addLine(to: CGPoint(x: c.x - gap / 2, y: c.y))
                    p.move(to: CGPoint(x: c.x + gap / 2, y: c.y))
                    p.addLine(to: CGPoint(x: c.x + gap / 2 + len, y: c.y))
                    p.move(to: CGPoint(x: c.x, y: c.y - gap / 2 - len))
                    p.addLine(to: CGPoint(x: c.x, y: c.y - gap / 2))
                    p.move(to: CGPoint(x: c.x, y: c.y + gap / 2))
                    p.addLine(to: CGPoint(x: c.x, y: c.y + gap / 2 + len))
                }
                .stroke(color.opacity(0.4), lineWidth: 1)
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .allowsHitTesting(false)
    }
}
