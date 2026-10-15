import SwiftUI

/// Animated glowing orb. Gentle breathing when idle; reacts to `level` (0...1) when listening/speaking.
struct OrbView: View {
    var level: Double
    var phase: JarvisPhase
    var primary: Color
    var accent: Color

    var body: some View {
        TimelineView(.animation) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            Canvas { ctx, size in
                let center = CGPoint(x: size.width / 2, y: size.height / 2)
                let base = min(size.width, size.height) * 0.28
                let breathe = 0.04 * sin(t * 1.6)
                let reactive = (phase == .listening || phase == .speaking) ? level * 0.35 : 0
                let think = phase == .thinking ? 0.05 * sin(t * 7) : 0
                let r = base * (1 + breathe + reactive + think)

                func circle(_ radius: Double) -> Path {
                    Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius,
                                           width: radius * 2, height: radius * 2))
                }

                // Outer glow
                ctx.drawLayer { layer in
                    layer.addFilter(.blur(radius: base * 0.35))
                    layer.fill(circle(r * 1.35), with: .color(primary.opacity(0.45 + reactive)))
                }
                // Core
                ctx.fill(circle(r), with: .radialGradient(
                    Gradient(colors: [.white, primary, primary.opacity(0.25)]),
                    center: center, startRadius: 0, endRadius: r))
                // Gold ring
                ctx.stroke(circle(r * 1.18), with: .color(accent.opacity(0.85)), lineWidth: 2)
                // Rotating arcs
                let speed = phase == .thinking ? 3.0 : (phase == .idle ? 0.4 : 1.2)
                for i in 0..<3 {
                    var arc = Path()
                    let start = t * speed + Double(i) * (2 * .pi / 3)
                    arc.addArc(center: center, radius: r * (1.32 + 0.06 * Double(i)),
                               startAngle: .radians(start), endAngle: .radians(start + 0.9),
                               clockwise: false)
                    ctx.stroke(arc, with: .color(accent.opacity(0.55 - 0.12 * Double(i))),
                               style: StrokeStyle(lineWidth: 3, lineCap: .round))
                }
            }
        }
        .accessibilityLabel("JARVIS is \(phase.label.lowercased())")
    }
}
