import SwiftUI

/// Colours taken from the reference orb. A little of the user's primary is mixed in
/// so the appearance picker still tints it, without washing the steel ring out to white.
struct OrbPalette: Sendable {
    var lineR: Double
    var lineG: Double
    var lineB: Double
    var segR: Double
    var segG: Double
    var segB: Double
    var partR: Double
    var partG: Double
    var partB: Double

    /// Simplified Canvas orb for widgets and the Dynamic Island.
    /// main #00BFCB, highlight #00E5F2, dim ring #0B3948.
    static let reference = OrbPalette(
        lineR: 0.00, lineG: 0.749, lineB: 0.796,
        segR: 0.043, segG: 0.224, segB: 0.282,
        partR: 0.00, partG: 0.898, partB: 0.949
    )

    func tinted(with primary: (Double, Double, Double), amount: Double = 0.18) -> OrbPalette {
        func mix(_ r: Double, _ g: Double, _ b: Double, _ t: Double) -> (Double, Double, Double) {
            (r + (primary.0 - r) * t, g + (primary.1 - g) * t, b + (primary.2 - b) * t)
        }
        let scale = min(1, max(0, amount)) / 0.18
        let line = mix(lineR, lineG, lineB, min(1, 0.18 * scale))
        let seg = mix(segR, segG, segB, min(1, 0.05 * scale))
        let part = mix(partR, partG, partB, min(1, 0.14 * scale))
        return OrbPalette(lineR: line.0, lineG: line.1, lineB: line.2,
                          segR: seg.0, segG: seg.1, segB: seg.2,
                          partR: part.0, partG: part.1, partB: part.2)
    }
}

/// Geodesic core, segmented ring and particle halo. Geometry is built once.
enum OrbRenderer {
    static func draw(ctx: inout GraphicsContext, size: CGSize, time: Double,
                     amp: Double, glow: Double, level: Double, flow: Double,
                     palette: OrbPalette, detailed: Bool) {
        let w = size.width
        let h = size.height
        guard w > 2, h > 2 else { return }
        let breath = 1 + 0.015 * sin(time * (2 * Double.pi / 5))
        let unit = min(w, h) * breath
        let cx = w / 2
        let cy = h / 2
        let tiny = unit < 32
        let energy = min(1, max(0, (amp - 0.08) / 0.95))
        let sphere = tiny ? Icosphere.small : Icosphere.full

        drawGlow(ctx: &ctx, cx: cx, cy: cy, unit: unit, palette: palette, energy: energy)
        drawParticles(ctx: &ctx, cx: cx, cy: cy, unit: unit, time: time,
                      amp: amp, glow: glow, energy: energy, flow: flow, palette: palette,
                      detailed: detailed && !tiny)
        drawSegments(ctx: &ctx, cx: cx, cy: cy, unit: unit, time: time,
                     energy: energy, level: level, palette: palette, count: tiny ? 24 : 60)
        drawSphere(ctx: &ctx, cx: cx, cy: cy, unit: unit, time: time, palette: palette, sphere: sphere)
    }

    // MARK: Layers

    private static func drawGlow(ctx: inout GraphicsContext, cx: Double, cy: Double, unit: Double,
                                 palette: OrbPalette, energy: Double) {
        let radius = unit * (0.50 + energy * 0.04)
        ctx.drawLayer { layer in
            layer.addFilter(.blur(radius: unit * 0.09))
            layer.fill(Path(ellipseIn: CGRect(x: cx - radius, y: cy - radius, width: radius * 2, height: radius * 2)),
                       with: .color(Color(.sRGB, red: palette.partR, green: palette.partG, blue: palette.partB,
                                         opacity: 0.10 + energy * 0.06)))
        }
    }

    private static func drawParticles(ctx: inout GraphicsContext, cx: Double, cy: Double, unit: Double,
                                      time: Double, amp: Double, glow: Double, energy: Double, flow: Double,
                                      palette: OrbPalette, detailed: Bool) {
        let strideBy = detailed ? 1 : 3
        var buckets = Array(repeating: Path(), count: 8)
        let particles = OrbField.particles
        var index = 0
        while index < particles.count {
            let p = particles[index]
            let step = (p.ring == 4 || detailed) ? 1 : strideBy
            place(p, cx: cx, cy: cy, unit: unit, time: time,
                  amp: amp, glow: glow, energy: energy, flow: flow, into: &buckets)
            index += step
        }

        ctx.drawLayer { layer in
            layer.blendMode = .plusLighter
            for i in 0..<buckets.count where !buckets[i].isEmpty {
                // Kept low so overlapping grains stay teal instead of adding up to white.
                let alpha = 0.035 + Double(i) * 0.028
                layer.fill(buckets[i], with: .color(Color(.sRGB, red: palette.partR, green: palette.partG,
                                                          blue: palette.partB, opacity: alpha)))
            }
        }
    }

    private static func place(_ p: OrbParticle, cx: Double, cy: Double, unit: Double,
                              time: Double, amp: Double, glow: Double, energy: Double, flow: Double,
                              into buckets: inout [Path]) {
        let along = Double(p.along)
        let jitter = Double(p.jitter)
        let theta: Double
        let radius: Double
        let dot: Double
        let bright: Double

        if p.ring == 4 {
            let drift = time * flow * (0.05 + jitter * 0.04) * (p.gain > 0.5 ? 1 : -1)
            theta = along * 2 * .pi + drift
            let breathe = sin(time * 0.35 + jitter * 8) * unit * 0.012
            radius = unit * (0.40 + jitter * 0.30) + breathe
            dot = unit * 0.0036 * Double(p.scale)
            bright = 0.22 + 0.2 * abs(sin(time * 0.6 + along * 6))
        } else {
            let ring = Int(p.ring)
            let spec = ringSpecs[ring]
            theta = along * 2 * .pi + time * spec.spin * (0.65 + flow)
            let wobble = waveform(theta: theta, time: time, ring: ring, jitter: jitter, flow: flow)
            let idle = unit * 0.016 * spec.wobble
            let push = unit * (0.012 + amp * 0.10) * spec.wobble
            radius = unit * spec.base * (1 + sin(time * 0.45 + Double(ring)) * 0.008)
                + wobble * (idle + push)
                + (jitter - 0.5) * unit * 0.018
            dot = unit * 0.0046 * Double(p.scale)
            bright = 0.32 + 0.68 * (0.5 + 0.5 * wobble)
        }

        let alpha = min(1, bright * Double(p.gain) * (0.5 + glow * 0.55 + energy * 0.15))
        let bucket = min(7, max(0, Int(alpha * 7.99)))
        let d = max(0.4, dot)
        buckets[bucket].addEllipse(in: CGRect(x: cx + cos(theta) * radius - d,
                                              y: cy + sin(theta) * radius - d,
                                              width: d * 2, height: d * 2))
    }

    /// Sin harmonics around the ring, plus one simplex sample so the loop stays irregular.
    private static func waveform(theta: Double, time: Double, ring: Int, jitter: Double, flow: Double) -> Double {
        let pace = 0.55 + flow
        let s1 = sin(theta * 3 + time * 0.55 * pace + Double(ring) * 1.3)
        let s2 = sin(theta * 6 - time * 0.85 * pace + jitter * 4)
        let s3 = sin(theta * 13 + time * 0.35 * pace + Double(ring))
        let n = SimplexNoise.noise(cos(theta) * 1.15 + Double(ring) * 2.2,
                                   sin(theta) * 1.15,
                                   time * 0.16 * pace + jitter)
        return s1 * 0.48 + s2 * 0.27 + s3 * 0.12 + n * 0.34
    }

    private static func drawSegments(ctx: inout GraphicsContext, cx: Double, cy: Double, unit: Double,
                                     time: Double, energy: Double, level: Double,
                                     palette: OrbPalette, count: Int) {
        let spin = -time * (2 * .pi / 62) // opposite the sphere, about a minute per turn
        let pitch = 2 * .pi / Double(count)
        let radius = unit * 0.292
        let thickness = unit * 0.050
        let length = radius * pitch * 0.74
        let lit = min(1, energy * 0.75 + min(1, level) * 0.45)
        let cr = palette.segR + (0.32 - palette.segR) * lit
        let cg = palette.segG + (0.62 - palette.segG) * lit
        let cb = palette.segB + (0.78 - palette.segB) * lit

        for i in 0..<count {
            let shade = Double(OrbField.segmentShade[i % OrbField.segmentShade.count])
            let angle = pitch * (Double(i) + 0.5) + spin
            let mx = cx + cos(angle) * radius
            let my = cy + sin(angle) * radius
            let rect = CGRect(x: -length / 2, y: -thickness / 2, width: length, height: thickness)
            var tile = Path(roundedRect: rect, cornerRadius: thickness * 0.38)
            let translation = CGAffineTransform(translationX: mx, y: my)
            let rotation = CGAffineTransform(rotationAngle: CGFloat(angle + .pi / 2))
            tile = tile.applying(translation.concatenating(rotation))
            let alpha = (0.28 + shade * 0.35) * (0.65 + lit * 0.45)
            ctx.fill(tile, with: .color(Color(.sRGB, red: cr, green: cg, blue: cb, opacity: min(1, alpha))))
        }
    }

    private static func drawSphere(ctx: inout GraphicsContext, cx: Double, cy: Double, unit: Double,
                                   time: Double, palette: OrbPalette, sphere: Icosphere) {
        let spin = time * (2 * .pi / 25) // 25 s per revolution, inside the requested 20–30 s
        let radius = unit * 0.148
        var projected: [Proj] = []
        projected.reserveCapacity(sphere.vertices.count)
        for v in sphere.vertices {
            projected.append(project(rotate(v, angle: spin), cx: cx, cy: cy, radius: radius))
        }

        var edgePaths = Array(repeating: Path(), count: 8)
        for edge in sphere.edges {
            let a = projected[Int(edge.0)]
            let b = projected[Int(edge.1)]
            let depth = (a.front + b.front) * 0.5
            let bucket = min(7, max(0, Int(depth * 7.99)))
            edgePaths[bucket].move(to: CGPoint(x: a.x, y: a.y))
            edgePaths[bucket].addLine(to: CGPoint(x: b.x, y: b.y))
        }

        var dots = Array(repeating: Path(), count: 8)
        var halos = Path()
        for i in projected.indices {
            let p = projected[i]
            let bucket = min(7, max(0, Int(p.front * 7.99)))
            let twinkle = 0.75 + 0.25 * sin(time * 1.6 + Double(i) * 1.37)
            let r = max(0.35, radius * 0.045 * (0.45 + p.front) * twinkle)
            dots[bucket].addEllipse(in: CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2))
            if p.front > 0.72 {
                let h = r * 2.6
                halos.addEllipse(in: CGRect(x: p.x - h, y: p.y - h, width: h * 2, height: h * 2))
            }
        }

        let bloom = radius * 1.35
        ctx.drawLayer { layer in
            layer.addFilter(.blur(radius: unit * 0.035))
            layer.fill(Path(ellipseIn: CGRect(x: cx - bloom, y: cy - bloom, width: bloom * 2, height: bloom * 2)),
                       with: .color(Color(.sRGB, red: palette.lineR, green: palette.lineG, blue: palette.lineB, opacity: 0.07)))
        }

        let lw = max(0.45, unit * 0.0031)
        ctx.drawLayer { layer in
            for i in 0..<edgePaths.count where !edgePaths[i].isEmpty {
                let front = Double(i) / 7
                let alpha = 0.07 + front * front * 0.78
                let color = Color(.sRGB, red: palette.lineR, green: palette.lineG, blue: palette.lineB, opacity: alpha)
                layer.stroke(edgePaths[i], with: .color(color),
                             style: StrokeStyle(lineWidth: lw * (1.6 + front), lineCap: .round, lineJoin: .round))
                layer.stroke(edgePaths[i], with: .color(Color(.sRGB, red: palette.lineR, green: palette.lineG,
                                                             blue: palette.lineB, opacity: min(1, alpha + 0.18))),
                             style: StrokeStyle(lineWidth: lw, lineCap: .round, lineJoin: .round))
            }
            if !halos.isEmpty {
                layer.fill(halos, with: .color(Color(.sRGB, red: palette.lineR, green: palette.lineG,
                                                    blue: palette.lineB, opacity: 0.16)))
            }
            for i in 0..<dots.count where !dots[i].isEmpty {
                let front = Double(i) / 7
                // Cyan sparkle. Stay well short of white so the core doesn't bloom out.
                let r = palette.lineR + (0.58 - palette.lineR) * front
                let g = palette.lineG
                let b = palette.lineB
                layer.fill(dots[i], with: .color(Color(.sRGB, red: r, green: g, blue: b,
                                                      opacity: 0.2 + front * 0.65)))
            }
        }
    }

    // MARK: Projection

    /// Spin about an axis tipped ~26° off vertical.
    private static func rotate(_ v: Vec3, angle: Double) -> Vec3 {
        let ax = axisX, ay = axisY, az = 0.0
        let c = cos(angle), s = sin(angle), k = 1 - c
        let dot = ax * v.x + ay * v.y + az * v.z
        let cxv = ay * v.z - az * v.y
        let cyv = az * v.x - ax * v.z
        let czv = ax * v.y - ay * v.x
        return Vec3(x: v.x * c + cxv * s + ax * dot * k,
                    y: v.y * c + cyv * s + ay * dot * k,
                    z: v.z * c + czv * s + az * dot * k)
    }

    private static func project(_ v: Vec3, cx: Double, cy: Double, radius: Double) -> Proj {
        let persp = 3.5 / (3.5 - v.z)
        let front = (v.z + 1) * 0.5
        return Proj(x: cx + v.x * persp * radius,
                    y: cy - v.y * persp * radius,
                    front: min(1, max(0, front)))
    }

    private static let tilt = 26.0 * Double.pi / 180
    private static let axisX = sin(tilt)
    private static let axisY = cos(tilt)

    private static let ringSpecs: [(base: Double, spin: Double, wobble: Double)] = [
        (0.385, 0.040, 1.00),
        (0.460, -0.028, 1.12),
        (0.530, 0.018, 0.92),
        (0.600, -0.012, 0.70),
    ]
}

private struct Proj {
    var x: Double
    var y: Double
    var front: Double
}

private struct Vec3 {
    var x: Double
    var y: Double
    var z: Double

    func normalized() -> Vec3 {
        let len = (x * x + y * y + z * z).squareRoot()
        guard len > 0 else { return self }
        return Vec3(x: x / len, y: y / len, z: z / len)
    }
}

private struct OrbParticle {
    var ring: Int16
    var along: Float
    var jitter: Float
    var scale: Float
    var gain: Float
}

private enum OrbField {
    static let segmentShade: [Float] = (0..<52).map { i in
        let x = sin(Double(i) * 12.9898) * 43758.5453
        let frac = x - floor(x)
        return Float(0.58 + frac * 0.42)
    }

    /// ~2000 grains: four noisy rings plus a few drifters.
    static let particles: [OrbParticle] = {
        var rng: UInt32 = 0xA5C31E7
        func unit() -> Float {
            rng = rng &* 1664525 &+ 1013904223
            return Float(rng % 10_000) / 10_000
        }
        var list: [OrbParticle] = []
        let counts = [560, 520, 480, 340]
        list.reserveCapacity(counts.reduce(0, +) + 180)
        for ring in 0..<counts.count {
            let n = counts[ring]
            for i in 0..<n {
                let along = (Float(i) + unit() * 0.85) / Float(n)
                list.append(OrbParticle(ring: Int16(ring), along: along, jitter: unit(),
                                         scale: 0.55 + unit() * 1.15, gain: 0.45 + unit() * 0.55))
            }
        }
        for _ in 0..<180 {
            list.append(OrbParticle(ring: 4, along: unit(), jitter: unit(),
                                     scale: 0.45 + unit() * 1.0, gain: 0.2 + unit() * 0.45))
        }
        return list
    }()
}

private struct Icosphere {
    var vertices: [Vec3]
    var edges: [(UInt16, UInt16)]

    static let full = build(subdivisions: 2)
    static let small = build(subdivisions: 1)

    static func build(subdivisions: Int) -> Icosphere {
        let t = (1.0 + 5.0.squareRoot()) / 2.0
        var verts = [
            Vec3(x: -1, y: t, z: 0), Vec3(x: 1, y: t, z: 0), Vec3(x: -1, y: -t, z: 0), Vec3(x: 1, y: -t, z: 0),
            Vec3(x: 0, y: -1, z: t), Vec3(x: 0, y: 1, z: t), Vec3(x: 0, y: -1, z: -t), Vec3(x: 0, y: 1, z: -t),
            Vec3(x: t, y: 0, z: -1), Vec3(x: t, y: 0, z: 1), Vec3(x: -t, y: 0, z: -1), Vec3(x: -t, y: 0, z: 1),
        ].map { $0.normalized() }

        var faces: [(Int, Int, Int)] = [
            (0, 11, 5), (0, 5, 1), (0, 1, 7), (0, 7, 10), (0, 10, 11),
            (1, 5, 9), (5, 11, 4), (11, 10, 2), (10, 7, 6), (7, 1, 8),
            (3, 9, 4), (3, 4, 2), (3, 2, 6), (3, 6, 8), (3, 8, 9),
            (4, 9, 5), (2, 4, 11), (6, 2, 10), (8, 6, 7), (9, 8, 1),
        ]

        for _ in 0..<subdivisions {
            var cache: [UInt64: Int] = [:]
            func mid(_ a: Int, _ b: Int) -> Int {
                let key = edgeKey(a, b)
                if let found = cache[key] { return found }
                let m = Vec3(x: (verts[a].x + verts[b].x) * 0.5,
                             y: (verts[a].y + verts[b].y) * 0.5,
                             z: (verts[a].z + verts[b].z) * 0.5).normalized()
                verts.append(m)
                let idx = verts.count - 1
                cache[key] = idx
                return idx
            }
            var next: [(Int, Int, Int)] = []
            next.reserveCapacity(faces.count * 4)
            for f in faces {
                let ab = mid(f.0, f.1)
                let bc = mid(f.1, f.2)
                let ca = mid(f.2, f.0)
                next.append((f.0, ab, ca))
                next.append((f.1, bc, ab))
                next.append((f.2, ca, bc))
                next.append((ab, bc, ca))
            }
            faces = next
        }

        var seen: Set<UInt64> = []
        var edges: [(UInt16, UInt16)] = []
        func add(_ a: Int, _ b: Int) {
            let key = edgeKey(a, b)
            if seen.insert(key).inserted {
                edges.append((UInt16(min(a, b)), UInt16(max(a, b))))
            }
        }
        for f in faces {
            add(f.0, f.1)
            add(f.1, f.2)
            add(f.2, f.0)
        }
        return Icosphere(vertices: verts, edges: edges)
    }

    private static func edgeKey(_ a: Int, _ b: Int) -> UInt64 {
        let lo = UInt64(min(a, b))
        let hi = UInt64(max(a, b))
        return (lo << 32) | hi
    }
}

/// 3D simplex noise, roughly -1...1. Bends the particle rings.
private enum SimplexNoise {
    private static let grad3: [(Double, Double, Double)] = [
        (1, 1, 0), (-1, 1, 0), (1, -1, 0), (-1, -1, 0),
        (1, 0, 1), (-1, 0, 1), (1, 0, -1), (-1, 0, -1),
        (0, 1, 1), (0, -1, 1), (0, 1, -1), (0, -1, -1),
    ]

    private static let perm: [Int] = {
        let p = [
            151, 160, 137, 91, 90, 15, 131, 13, 201, 95, 96, 53, 194, 233, 7, 225, 140, 36, 103, 30, 69, 142, 8, 99, 37, 240, 21, 10, 23,
            190, 6, 148, 247, 120, 234, 75, 0, 26, 197, 62, 94, 252, 219, 203, 117, 35, 11, 32, 57, 177, 33, 88, 237, 149, 56, 87, 174, 20, 125, 136, 171, 168, 68, 175, 74, 165, 71, 134, 139, 48, 27, 166,
            77, 146, 158, 231, 83, 111, 229, 122, 60, 211, 133, 230, 220, 105, 92, 41, 55, 46, 245, 40, 244, 102, 143, 54, 65, 25, 63, 161, 1, 216, 80, 73, 209, 76, 132, 187, 208, 89, 18, 169, 200, 196,
            135, 130, 116, 188, 159, 86, 164, 100, 109, 198, 173, 186, 3, 64, 52, 217, 226, 250, 124, 123, 5, 202, 38, 147, 118, 126, 255, 82, 85, 212, 207, 206, 59, 227, 47, 16, 58, 17, 182, 189, 28, 42,
            223, 183, 170, 213, 119, 248, 152, 2, 44, 154, 163, 70, 221, 153, 101, 155, 167, 43, 172, 9, 129, 22, 39, 253, 19, 98, 108, 110, 79, 113, 224, 232, 178, 185, 112, 104, 218, 246, 97, 228,
            251, 34, 242, 193, 238, 210, 144, 12, 191, 179, 162, 241, 81, 51, 145, 235, 249, 14, 239, 107, 49, 192, 214, 31, 181, 199, 106, 157, 184, 84, 204, 176, 115, 121, 50, 45, 127, 4, 150, 254,
            138, 236, 205, 93, 222, 114, 67, 29, 24, 72, 243, 141, 128, 195, 78, 66, 215, 61, 156, 180,
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

        return 32 * (contrib(x0, y0, z0, gi0) + contrib(x1, y1, z1, gi1)
                     + contrib(x2, y2, z2, gi2) + contrib(x3, y3, z3, gi3))
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
