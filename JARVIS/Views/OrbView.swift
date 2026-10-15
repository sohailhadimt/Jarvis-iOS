import SwiftUI
import UIKit

/// Particle orb: several noise-deformed filament bands around a small glowing core.
/// Audio level (0...1) is the smoothed RMS already produced by the mic tap and the TTS player tap.
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
            Canvas { ctx, size in
                drawField(ctx: &ctx, size: size, time: t, drive: drive)
            }
        }
        .accessibilityLabel("JARVIS is \(phase.label.lowercased())")
    }

    private func drawField(ctx: inout GraphicsContext, size: CGSize, time: Double,
                           drive: OrbDrive) {
        let w = size.width
        let h = size.height
        guard w > 2, h > 2 else { return }
        let unit = min(w, h)
        let cx = w / 2
        let cy = h / 2
        let rgb = Self.components(primary)
        let accentRGB = Self.components(accent)

        let glowR = unit * (0.34 + drive.glow * 0.06)
        ctx.drawLayer { layer in
            layer.addFilter(.blur(radius: unit * 0.08))
            layer.fill(
                Path(ellipseIn: CGRect(x: cx - glowR, y: cy - glowR, width: glowR * 2, height: glowR * 2)),
                with: .color(Color(red: rgb.0, green: rgb.1, blue: rgb.2, opacity: 0.22 + drive.glow * 0.18))
            )
        }

        var ring = Array(repeating: Path(), count: 7)
        var core = Array(repeating: Path(), count: 7)
        let breathe = 1 + sin(time * 0.85) * (phase == .idle ? 0.02 : 0.008)
        let ringR = unit * 0.31 * breathe
        let amp = unit * (0.012 + drive.amp * 0.055)
        let flow = time * 0.23 * drive.turb

        for p in FilamentField.particles {
            let along = Double(p.along)
            let jitter = Double(p.jitter)
            let band = Int(p.band)
            let x: Double
            let y: Double
            let dot: Double
            let bright: Double

            if band < 3 {
                let dir = band == 1 ? -1.0 : 1.0
                let spin = time * drive.speed * dir * (0.55 + 0.18 * Double(band))
                let theta = along * 2 * .pi + spin
                let c = cos(theta)
                let s = sin(theta)
                let n1 = SimplexNoise.noise(c * 1.35 + Double(band) * 2.2, s * 1.35, flow + Double(band) * 1.7)
                let n2 = SimplexNoise.noise(c * 2.7 + 6.0, s * 2.7, flow * 0.72 + 3.0 + jitter)
                let base: Double = band == 0 ? 0.78 : (band == 1 ? 0.94 : 1.08)
                let radius = ringR * base + (n1 * 0.72 + n2 * 0.38) * amp
                let twist = n2 * drive.amp * 0.55
                x = cx + cos(theta + twist) * radius
                y = cy + sin(theta + twist) * radius * 0.96
                dot = unit * 0.0062 * Double(p.scale)
                bright = 0.45 + 0.55 * (0.5 + 0.5 * n1)
            } else if band == 3 {
                let theta = along * 2 * .pi * 3 + jitter * 12 + time * drive.speed * 0.35
                let n = SimplexNoise.noise(cos(theta) + jitter * 4, sin(theta), flow * 0.8)
                let radius = unit * 0.075 * (0.2 + abs(n) * (0.85 + drive.amp))
                x = cx + cos(theta) * radius
                y = cy + sin(theta) * radius
                dot = unit * 0.007 * Double(p.scale)
                bright = 0.75 + 0.25 * abs(n)
            } else {
                let theta = along * 2 * .pi + time * 0.04 + jitter
                let n = SimplexNoise.noise(cos(theta) * 0.6, sin(theta) * 0.6, flow * 0.4)
                let radius = ringR * (1.15 + jitter * 0.28) + n * amp * 0.4
                x = cx + cos(theta) * radius
                y = cy + sin(theta) * radius * 0.96
                dot = unit * 0.004 * Double(p.scale)
                bright = 0.18 + 0.15 * abs(n)
            }

            let alpha = min(1, (0.25 + bright * drive.glow) * Double(p.gain))
            let bucket = min(6, max(0, Int(alpha * 7)))
            let rect = CGRect(x: x - dot, y: y - dot, width: dot * 2, height: dot * 2)
            if band == 3 {
                core[bucket].addEllipse(in: rect)
            } else {
                ring[bucket].addEllipse(in: rect)
            }
        }

        ctx.drawLayer { layer in
            layer.blendMode = .plusLighter
            for i in 0..<7 {
                let a = 0.08 + Double(i) * 0.09
                if !ring[i].isEmpty {
                    layer.fill(ring[i], with: .color(Color(red: rgb.0, green: rgb.1, blue: rgb.2, opacity: a)))
                }
                if !core[i].isEmpty {
                    let cr = rgb.0 + (1 - rgb.0) * 0.72
                    let cg = rgb.1 + (1 - rgb.1) * 0.55
                    let cb = min(1, rgb.2 + (1 - rgb.2) * 0.35 + accentRGB.2 * 0.05)
                    layer.fill(core[i], with: .color(Color(red: cr, green: cg, blue: cb, opacity: min(1, a + 0.18))))
                }
            }
        }
    }

    private static func components(_ color: Color) -> (Double, Double, Double) {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        if UIColor(color).getRed(&r, green: &g, blue: &b, alpha: &a) {
            return (Double(r), Double(g), Double(b))
        }
        return (0.373, 0.902, 1.0)
    }
}

struct OrbDrive {
    var amp: Double
    var speed: Double
    var turb: Double
    var glow: Double
}

private final class OrbMotion: ObservableObject {
    var amp = 0.22
    var speed = 0.16
    var turb = 0.85
    var glow = 0.6
    var lastTime = 0.0

    func step(phase: JarvisPhase, level: Double, time: Double) -> OrbDrive {
        let dt = lastTime == 0 ? 1.0 / 60.0 : min(0.05, max(0, time - lastTime))
        lastTime = time
        let k = 1 - exp(-dt * 6.5)
        let clamped = min(1, max(0, level))
        let target: OrbDrive
        switch phase {
        case .idle:
            target = OrbDrive(amp: 0.22, speed: 0.16, turb: 0.8, glow: 0.58)
        case .listening:
            target = OrbDrive(amp: 0.32 + clamped * 0.85, speed: 0.28 + clamped * 0.7,
                              turb: 1.05 + clamped * 1.1, glow: 0.7 + clamped * 0.45)
        case .thinking:
            target = OrbDrive(amp: 0.4, speed: 1.15, turb: 1.65, glow: 0.82)
        case .speaking:
            target = OrbDrive(amp: 0.34 + clamped * 0.95, speed: 0.34 + clamped * 0.9,
                              turb: 1.15 + clamped * 1.25, glow: 0.74 + clamped * 0.5)
        }
        amp += (target.amp - amp) * k
        speed += (target.speed - speed) * k
        turb += (target.turb - turb) * k
        glow += (target.glow - glow) * k
        return OrbDrive(amp: amp, speed: speed, turb: turb, glow: glow)
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

private struct FilamentParticle {
    var band: Int16
    var along: Float
    var jitter: Float
    var scale: Float
    var gain: Float
}

private enum FilamentField {
    static let particles: [FilamentParticle] = {
        var rng: UInt32 = 0x1A2B3C4D
        func unit() -> Float {
            rng = rng &* 1664525 &+ 1013904223
            return Float(rng % 10_000) / 10_000
        }
        var list: [FilamentParticle] = []
        list.reserveCapacity(2800)
        for band in 0..<3 {
            for i in 0..<720 {
                let along = (Float(i) + unit() * 0.65) / 720
                list.append(FilamentParticle(band: Int16(band), along: along, jitter: unit(),
                                              scale: 0.85 + unit() * 0.9, gain: 0.55 + unit() * 0.45))
            }
        }
        for i in 0..<380 {
            list.append(FilamentParticle(band: 3, along: Float(i) / 380, jitter: unit(),
                                          scale: 0.7 + unit() * 1.1, gain: 0.7 + unit() * 0.3))
        }
        for _ in 0..<220 {
            list.append(FilamentParticle(band: 4, along: unit(), jitter: unit(),
                                          scale: 0.6 + unit() * 0.8, gain: 0.25 + unit() * 0.35))
        }
        return list
    }()
}

/// 3D simplex noise, output roughly in -1...1. Used to bend the filament bands.
private enum SimplexNoise {
    private static let grad3: [(Double, Double, Double)] = [
        (1, 1, 0), (-1, 1, 0), (1, -1, 0), (-1, -1, 0),
        (1, 0, 1), (-1, 0, 1), (1, 0, -1), (-1, 0, -1),
        (0, 1, 1), (0, -1, 1), (0, 1, -1), (0, -1, -1)
    ]

    private static let perm: [Int] = {
        let p = [
            151, 160, 137, 91, 90, 15, 131, 13, 201, 95, 96, 53, 194, 233, 7, 225, 140, 36, 103, 30, 69, 142, 8, 99, 37, 240, 21, 10, 23,
            190, 6, 148, 247, 120, 234, 75, 0, 26, 197, 62, 94, 252, 219, 203, 117, 35, 11, 32, 57, 177, 33, 88, 237, 149, 56, 87, 174, 20, 125, 136, 171, 168, 68, 175, 74, 165, 71, 134, 139, 48, 27, 166,
            77, 146, 158, 231, 83, 111, 229, 122, 60, 211, 133, 230, 220, 105, 92, 41, 55, 46, 245, 40, 244, 102, 143, 54, 65, 25, 63, 161, 1, 216, 80, 73, 209, 76, 132, 187, 208, 89, 18, 169, 200, 196,
            135, 130, 116, 188, 159, 86, 164, 100, 109, 198, 173, 186, 3, 64, 52, 217, 226, 250, 124, 123, 5, 202, 38, 147, 118, 126, 255, 82, 85, 212, 207, 206, 59, 227, 47, 16, 58, 17, 182, 189, 28, 42,
            223, 183, 170, 213, 119, 248, 152, 2, 44, 154, 163, 70, 221, 153, 101, 155, 167, 43, 172, 9, 129, 22, 39, 253, 19, 98, 108, 110, 79, 113, 224, 232, 178, 185, 112, 104, 218, 246, 97, 228,
            251, 34, 242, 193, 238, 210, 144, 12, 191, 179, 162, 241, 81, 51, 145, 235, 249, 14, 239, 107, 49, 192, 214, 31, 181, 199, 106, 157, 184, 84, 204, 176, 115, 121, 50, 45, 127, 4, 150, 254,
            138, 236, 205, 93, 222, 114, 67, 29, 24, 72, 243, 141, 128, 195, 78, 66, 215, 61, 156, 180
        ]
        return p + p
    }()

    static func noise(_ xin: Double, _ yin: Double, _ zin: Double) -> Double {
        let f3 = 1.0 / 3.0
        let g3 = 1.0 / 6.0
        let s = (xin + yin + zin) * f3
        let i = fastFloor(xin + s)
        let j = fastFloor(yin + s)
        let k = fastFloor(zin + s)
        let t = Double(i + j + k) * g3
        let x0 = xin - (Double(i) - t)
        let y0 = yin - (Double(j) - t)
        let z0 = zin - (Double(k) - t)

        let i1: Int, j1: Int, k1: Int, i2: Int, j2: Int, k2: Int
        if x0 >= y0 {
            if y0 >= z0 { i1 = 1; j1 = 0; k1 = 0; i2 = 1; j2 = 1; k2 = 0 }
            else if x0 >= z0 { i1 = 1; j1 = 0; k1 = 0; i2 = 1; j2 = 0; k2 = 1 }
            else { i1 = 0; j1 = 0; k1 = 1; i2 = 1; j2 = 0; k2 = 1 }
        } else {
            if y0 < z0 { i1 = 0; j1 = 0; k1 = 1; i2 = 0; j2 = 1; k2 = 1 }
            else if x0 < z0 { i1 = 0; j1 = 1; k1 = 0; i2 = 0; j2 = 1; k2 = 1 }
            else { i1 = 0; j1 = 1; k1 = 0; i2 = 1; j2 = 1; k2 = 0 }
        }

        let x1 = x0 - Double(i1) + g3
        let y1 = y0 - Double(j1) + g3
        let z1 = z0 - Double(k1) + g3
        let x2 = x0 - Double(i2) + 2 * g3
        let y2 = y0 - Double(j2) + 2 * g3
        let z2 = z0 - Double(k2) + 2 * g3
        let x3 = x0 - 1 + 3 * g3
        let y3 = y0 - 1 + 3 * g3
        let z3 = z0 - 1 + 3 * g3

        let ii = i & 255
        let jj = j & 255
        let kk = k & 255
        let gi0 = perm[ii + perm[jj + perm[kk]]] % 12
        let gi1 = perm[ii + i1 + perm[jj + j1 + perm[kk + k1]]] % 12
        let gi2 = perm[ii + i2 + perm[jj + j2 + perm[kk + k2]]] % 12
        let gi3 = perm[ii + 1 + perm[jj + 1 + perm[kk + 1]]] % 12

        let n0 = contrib(x0, y0, z0, gi0)
        let n1 = contrib(x1, y1, z1, gi1)
        let n2 = contrib(x2, y2, z2, gi2)
        let n3 = contrib(x3, y3, z3, gi3)
        return 32 * (n0 + n1 + n2 + n3)
    }

    private static func contrib(_ x: Double, _ y: Double, _ z: Double, _ gi: Int) -> Double {
        var t = 0.6 - x * x - y * y - z * z
        if t < 0 { return 0 }
        t *= t
        let g = grad3[gi]
        return t * t * (g.0 * x + g.1 * y + g.2 * z)
    }

    private static func fastFloor(_ x: Double) -> Int {
        let i = Int(x)
        return x < Double(i) ? i - 1 : i
    }
}
