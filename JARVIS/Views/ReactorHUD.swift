import SwiftUI

/// Thin cyan rings, tick marks, and a sweeping arc around the voice orb.
struct ReactorHUD: View {
    var diameter: CGFloat
    var accent: Color

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: false)) { timeline in
            reactorFrame(date: timeline.date)
        }
        .frame(width: diameter, height: diameter)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    /// Rotation uses Double. The cloud shader is the only clock that must stay in Float.
    private func reactorFrame(date: Date) -> some View {
        let elapsed: Double = date.timeIntervalSinceReferenceDate
        let spinCycle: Double = elapsed.truncatingRemainder(dividingBy: 12.0)
        let spin: Double = spinCycle / 12.0 * 360.0
        let sweepCycle: Double = elapsed.truncatingRemainder(dividingBy: 2.8)
        let sweep: Double = sweepCycle / 2.8 * 360.0
        let spinAngle: Double = spin - 90.0
        let sweepAngle: Double = -sweep - 90.0
        let counterAngle: Double = sweep * 1.6 - 90.0
        return ZStack {
            Circle()
                .stroke(accent.opacity(0.28), lineWidth: 1)
            Circle()
                .stroke(accent.opacity(0.55), lineWidth: 1.2)
                .padding(8)
            Circle()
                .stroke(accent.opacity(0.85), lineWidth: 2)
                .blur(radius: 6)
                .padding(8)
            tickMarks
            Circle()
                .trim(from: 0.0, to: 0.16)
                .stroke(accent, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                .rotationEffect(.degrees(spinAngle))
                .padding(1)
            Circle()
                .trim(from: 0.40, to: 0.52)
                .stroke(accent.opacity(0.75), style: StrokeStyle(lineWidth: 1.4, lineCap: .round))
                .rotationEffect(.degrees(sweepAngle))
                .padding(16)
            Circle()
                .trim(from: 0.0, to: 0.05)
                .stroke(accent, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                .rotationEffect(.degrees(counterAngle))
                .padding(16)
        }
    }

    private var tickMarks: some View {
        Canvas { context, size in
            paintTicks(context: context, size: size)
        }
    }

    private func paintTicks(context: GraphicsContext, size: CGSize) {
        let cx: CGFloat = size.width / 2.0
        let cy: CGFloat = size.height / 2.0
        let radius: CGFloat = min(size.width, size.height) / 2.0 - 1.0
        var index: Int = 0
        while index < 60 {
            let major: Bool = index % 5 == 0
            let turns: Double = Double(index) / 60.0
            let angle: Double = turns * (2.0 * Double.pi) - (Double.pi / 2.0)
            let inset: CGFloat = major ? 9.0 : 4.5
            let inner: CGFloat = radius - inset
            let c: CGFloat = CGFloat(cos(angle))
            let s: CGFloat = CGFloat(sin(angle))
            var path = Path()
            path.move(to: CGPoint(x: cx + c * inner, y: cy + s * inner))
            path.addLine(to: CGPoint(x: cx + c * radius, y: cy + s * radius))
            let alpha: Double = major ? 0.9 : 0.32
            let width: CGFloat = major ? 1.4 : 0.6
            context.stroke(path, with: .color(accent.opacity(alpha)),
                           style: StrokeStyle(lineWidth: width, lineCap: .butt))
            index += 1
        }
    }
}
