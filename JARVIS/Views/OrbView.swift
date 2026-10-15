import SwiftUI
import UIKit

/// Reference orb: a tilted geodesic wireframe, a steel-blue segment ring, and teal particle halos.
/// `level` is the smoothed RMS from the mic tap (listening) or the speech player (speaking).
struct OrbView: View {
    var level: Double
    var phase: JarvisPhase
    var primary: Color
    var accent: Color

    @StateObject private var motion = OrbMotion()

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60.0)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            let drive = motion.step(phase: phase, level: level, time: t)
            let palette = OrbPalette.reference.tinted(with: Self.components(primary))
            Canvas { ctx, size in
                OrbRenderer.draw(ctx: &ctx, size: size, time: t,
                                 amp: drive.amp, glow: drive.glow, level: level, flow: drive.speed,
                                 palette: palette, detailed: true)
            }
        }
        .accessibilityLabel("JARVIS is \(phase.label.lowercased())")
    }

    private static func components(_ color: Color) -> (Double, Double, Double) {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        if UIColor(color).getRed(&r, green: &g, blue: &b, alpha: &a) {
            return (Double(r), Double(g), Double(b))
        }
        return (0.247, 0.847, 0.878)
    }
}

struct OrbDrive {
    var amp: Double
    var speed: Double
    var glow: Double
}

private final class OrbMotion: ObservableObject {
    var amp = 0.12
    var speed = 0.25
    var glow = 0.5
    var lastTime = 0.0

    func step(phase: JarvisPhase, level: Double, time: Double) -> OrbDrive {
        let dt = lastTime == 0 ? 1.0 / 60.0 : min(0.05, max(0, time - lastTime))
        lastTime = time
        // Slow enough that the rings spread and settle instead of snapping to the RMS.
        let k = 1 - exp(-dt * 3.6)
        let clamped = min(1, max(0, level))
        let target: OrbDrive
        switch phase {
        case .idle:
            target = OrbDrive(amp: 0.12, speed: 0.22, glow: 0.48)
        case .listening:
            target = OrbDrive(amp: 0.18 + clamped * 0.95, speed: 0.35 + clamped * 0.7, glow: 0.58 + clamped * 0.4)
        case .thinking:
            target = OrbDrive(amp: 0.36, speed: 0.5, glow: 0.66)
        case .speaking:
            target = OrbDrive(amp: 0.2 + clamped * 1.05, speed: 0.4 + clamped * 0.85, glow: 0.6 + clamped * 0.42)
        }
        amp += (target.amp - amp) * k
        speed += (target.speed - speed) * k
        glow += (target.glow - glow) * k
        return OrbDrive(amp: amp, speed: speed, glow: glow)
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
