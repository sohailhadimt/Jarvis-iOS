import SwiftUI

enum VoiceLook {
    static let blue = Color(red: 0.22, green: 0.47, blue: 1.0)
    static let deep = Color(red: 0.08, green: 0.18, blue: 0.62)
    static let lavender = Color(red: 0.73, green: 0.62, blue: 1.0)
    static let mist = Color(red: 0.88, green: 0.90, blue: 1.0)
    static let ink = Color(red: 0.02, green: 0.03, blue: 0.06)
}

/// ChatGPT-style blue-to-lavender cloud. The Metal geodesic orb stays in the project for JARVIS classic.
struct CloudOrbView: View {
    var level: Double
    var phase: JarvisPhase
    var sessionActive: Bool = false
    var executing: Bool = false
    var hasError: Bool = false
    var paused: Bool = false

    var body: some View {
        TimelineView(.animation(minimumInterval: paused ? 1.0 : 1.0 / 30.0, paused: paused)) { timeline in
            let time = timeline.date.timeIntervalSinceReferenceDate
            Canvas { context, size in
                draw(context: context, size: size, time: time)
            }
            .blur(radius: 26)
        }
        .accessibilityLabel("Voice orb, \(phase.label.lowercased())")
        .accessibilityHidden(false)
    }

    private func draw(context: GraphicsContext, size: CGSize, time: Double) {
        let side = min(size.width, size.height)
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        let mood = moodScale
        let breath = 1 + 0.035 * sin(time * (phase == .thinking ? 1.6 : 0.85))
        let energy = 1 + min(0.28, level * 0.55)
        let radius = side * CGFloat(0.22 * mood * breath * energy)
        let spin = time * spinSpeed
        let lavenderMix = lavenderAmount
        let dim = hasError ? 0.4 : 1.0

        for index in 0..<7 {
            let orbit = spin + Double(index) * (.pi * 2 / 7)
            let wobble = radius * CGFloat(sin(time * 0.7 + Double(index)) * 0.22)
            let point = CGPoint(
                x: center.x + CGFloat(cos(orbit)) * radius * CGFloat(0.55) + wobble,
                y: center.y + CGFloat(sin(orbit * 1.15)) * radius * CGFloat(0.48)
            )
            let blobRadius = radius * CGFloat(0.72 + 0.08 * sin(time + Double(index)))
            let color = index.isMultiple(of: 2)
                ? VoiceLook.blue.opacity(0.85 * dim)
                : blend(VoiceLook.lavender, toward: VoiceLook.deep, amount: 1 - lavenderMix).opacity(0.8 * dim)
            fill(context, center: point, radius: blobRadius, color: color)
        }
        fill(context, center: center, radius: radius * CGFloat(0.78),
             color: blend(VoiceLook.blue, toward: VoiceLook.lavender, amount: lavenderMix).opacity(0.9 * dim))
        fill(context, center: CGPoint(x: center.x - radius * CGFloat(0.12), y: center.y - radius * CGFloat(0.08)),
             radius: radius * CGFloat(0.38), color: VoiceLook.mist.opacity((0.55 + level * 0.25) * dim))
    }

    private var spinSpeed: Double {
        if executing { return 1.35 }
        switch phase {
        case .idle: return sessionActive ? 0.45 : 0.28
        case .listening: return 0.72
        case .thinking: return 1.25
        case .speaking: return 0.95
        }
    }

    private var lavenderAmount: Double {
        if executing { return 0.82 }
        switch phase {
        case .idle: return 0.28
        case .listening: return 0.38 + level * 0.2
        case .thinking: return 0.78
        case .speaking: return 0.55
        }
    }

    private var moodScale: Double {
        if hasError { return 0.82 }
        switch phase {
        case .idle: return sessionActive ? 0.94 : 0.88
        case .listening: return 1
        case .thinking: return 0.9
        case .speaking: return 1.06
        }
    }

    private func fill(_ context: GraphicsContext, center: CGPoint, radius: CGFloat, color: Color) {
        let rect = CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
        context.fill(Path(ellipseIn: rect), with: .color(color))
    }

    private func blend(_ from: Color, toward: Color, amount: Double) -> Color {
        amount > 0.5 ? toward : from
    }
}
