import SwiftUI

/// Original start-up sequence. Tap anywhere to skip. Reduce Motion uses a short fade.
/// The rings shrink onto the home orb and the black field clears, so the hand-off is the same view.
struct StartupSequenceView: View {
    var dock: CGRect
    var onFinished: () -> Void

    @Environment(AppSettings.self) private var settings
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var started = Date()
    @State private var ended = false
    @State private var dismissed = false
    @State private var appeared = false
    @State private var playback = StartupPlayback()
    @State private var cueTask: Task<Void, Never>?

    var body: some View {
        Group {
            if reduceMotion {
                reduced
            } else {
                cinematic
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .onTapGesture(perform: skip)
        .onAppear(perform: arm)
        .onDisappear {
            cueTask?.cancel()
            playback.stop()
        }
        .opacity(dismissed ? 0 : 1)
        .animation(.easeOut(duration: 0.2), value: dismissed)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("J.A.R.V.I.S. starting")
        .accessibilityHint("Skips the start-up sequence")
        .accessibilityAddTraits(.isButton)
    }

    private var reduced: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            Text("J.A.R.V.I.S.")
                .font(.system(size: 22, weight: .thin, design: .monospaced))
                .tracking(6)
                .foregroundStyle(settings.accentColor)
                .opacity(appeared ? 1 : 0)
        }
    }

    private var cinematic: some View {
        let plan = StartupPlan.cinematic(short: settings.startupShort)
        return TimelineView(.animation(minimumInterval: 1.0 / 60.0, paused: ended)) { context in
            let elapsed = context.date.timeIntervalSince(started)
            GeometryReader { geo in
                let frame = StartupFrame.make(
                    elapsed: elapsed,
                    size: geo.size,
                    plan: plan,
                    dock: dock,
                    accent: settings.accentColor
                )
                ZStack {
                    Color.black.opacity(frame.backdrop).ignoresSafeArea()
                    Canvas { context, size in
                        StartupCanvas.paint(context, size: size, frame: frame)
                    }
                    .allowsHitTesting(false)
                    bootCopy(frame)
                    wordmark(frame)
                }
                .frame(width: geo.size.width, height: geo.size.height)
            }
        }
    }

    private func bootCopy(_ frame: StartupFrame) -> some View {
        VStack(spacing: 16) {
            HStack(spacing: 0) {
                Text("INITIATING SYSTEMS…")
                Text(frame.cursorOn ? "█" : " ")
                    .frame(width: 16, alignment: .leading)
            }
            .font(.system(size: frame.titleSize, weight: .medium, design: .monospaced))
            .foregroundStyle(frame.ink)
            HStack(spacing: 3) {
                ForEach(0..<24, id: \.self) { index in
                    Capsule()
                        .fill(frame.ink.opacity(Double(index) / 24 < frame.bar ? 0.92 : 0.16))
                        .frame(width: 7, height: 5)
                }
            }
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(StartupCopy.terminals.enumerated()), id: \.offset) { index, line in
                    Text(line)
                        .font(.system(size: 11, weight: .regular, design: .monospaced))
                        .foregroundStyle(frame.ink.opacity(0.82))
                        .opacity(index < frame.terminals.count ? frame.terminals[index] : 0.0)
                }
            }
            .frame(width: 196, alignment: .leading)
        }
        .scaleEffect(1 - frame.collapse * 0.92)
        .opacity(frame.bootAlpha)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .allowsHitTesting(false)
    }

    private func wordmark(_ frame: StartupFrame) -> some View {
        ZStack {
            Text("J.A.R.V.I.S.")
                .font(.system(size: 22, weight: .thin, design: .monospaced))
                .tracking(6)
                .foregroundStyle(frame.ink)
                .opacity(frame.wordAlpha)
            Text("Loading your preferences.")
                .font(.system(size: 12, weight: .regular, design: .monospaced))
                .foregroundStyle(frame.ink.opacity(0.8))
                .opacity(frame.prefsAlpha)
                .offset(y: 28)
        }
        .position(frame.center)
        .allowsHitTesting(false)
    }

    private func arm() {
        StartupVoiceCache.warmOnce(
            voiceID: settings.voiceID,
            stability: settings.stability,
            similarity: settings.similarity
        )
        if reduceMotion {
            withAnimation(.easeInOut(duration: 0.4)) { appeared = true }
            cueTask = Task { @MainActor in
                do { try await Task.sleep(for: .milliseconds(780)) } catch { return }
                guard !Task.isCancelled else { return }
                finish()
            }
            return
        }
        let plan = StartupPlan.cinematic(short: settings.startupShort)
        let effects = settings.bootChime
        let voiceID = settings.voiceID
        let sound = playback.arm()
        if sound { JarvisHaptics.prepareStartup() }
        let greeting = StartupLine.greeting()
        let origin = started
        cueTask = Task { @MainActor in
            for cue in plan.cues(greeting: greeting) {
                guard await sleepUntil(cue.at, origin: origin) else { return }
                perform(cue, effects: effects, sound: sound, voiceID: voiceID)
            }
            guard await sleepUntil(plan.duration, origin: origin) else { return }
            finish()
        }
    }

    private func perform(_ cue: StartupCue, effects: Bool, sound: Bool, voiceID: String) {
        switch cue.kind {
        case .tick:
            JarvisHaptics.tick()
            if effects, sound { playback.play(url: StartupAudio.url("startup-tick"), volume: 0.16) }
        case .strike:
            JarvisHaptics.strike()
        case .chime:
            if effects, sound { playback.play(url: StartupAudio.url("startup-chime"), volume: 0.22) }
        case .swell:
            if effects, sound { playback.play(url: StartupAudio.url("startup-swell"), volume: 0.2) }
        case .speech(let line):
            if sound { playback.play(url: StartupVoiceCache.url(line, voiceID: voiceID), volume: 0.82) }
        }
    }

    private func sleepUntil(_ time: TimeInterval, origin: Date) async -> Bool {
        let wait = time - Date().timeIntervalSince(origin)
        if wait > 0.001 {
            do { try await Task.sleep(for: .seconds(wait)) } catch { return false }
        }
        return !Task.isCancelled
    }

    private func skip() {
        guard !ended else { return }
        cueTask?.cancel()
        playback.stop()
        dismissed = true
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(200))
            finish()
        }
    }

    private func finish() {
        guard !ended else { return }
        ended = true
        onFinished()
    }
}

struct OrbAnchorKey: PreferenceKey {
    static var defaultValue: CGRect = .zero
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        let next = nextValue()
        if next.width > 1, next.height > 1 { value = next }
    }
}

private enum StartupCopy {
    static let terminals = [
        "LINK: SECURE CHANNEL",
        "VOICE CORE: ONLINE",
        "MEMORY SYNC",
        "CHECKSUM: OK",
    ]
}

private struct StartupPlan {
    var short: Bool
    var bootEnd: Double
    var collapseEnd: Double
    var bloomEnd: Double
    var duration: Double

    static func cinematic(short: Bool) -> StartupPlan {
        if short {
            return StartupPlan(short: true, bootEnd: 0.72, collapseEnd: 0.90, bloomEnd: 2.05, duration: 3.15)
        }
        return StartupPlan(short: false, bootEnd: 1.8, collapseEnd: 2.1, bloomEnd: 4.5, duration: 6.5)
    }

    func cues(greeting: StartupLine) -> [StartupCue] {
        var items = [
            StartupCue(at: bootEnd * 0.16, kind: .tick),
            StartupCue(at: bootEnd * 0.38, kind: .tick),
            StartupCue(at: bootEnd * 0.58, kind: .tick),
            StartupCue(at: bootEnd * 0.80, kind: .tick),
            StartupCue(at: bootEnd, kind: .strike),
            StartupCue(at: collapseEnd + 0.02, kind: .chime),
            StartupCue(at: collapseEnd + 0.12, kind: .speech(greeting)),
            StartupCue(at: bloomEnd, kind: .swell),
            StartupCue(at: bloomEnd + 0.06, kind: .speech(.operational)),
        ]
        if !short {
            let span = bloomEnd - collapseEnd
            items.append(StartupCue(at: collapseEnd + span * 0.42, kind: .speech(.preferences)))
        }
        return items.sorted { $0.at < $1.at }
    }
}

private struct StartupCue {
    enum Kind {
        case tick
        case strike
        case chime
        case swell
        case speech(StartupLine)
    }
    var at: TimeInterval
    var kind: Kind
}

private struct StartupFrame {
    var backdrop: Double
    var bootAlpha: Double
    var collapse: CGFloat
    var terminals: [Double]
    var bar: Double
    var cursorOn: Bool
    var titleSize: CGFloat
    var dotRadius: CGFloat
    var dotAlpha: Double
    var ringAlpha: Double
    var ringRadius: CGFloat
    var center: CGPoint
    var spins: [Double]
    var wordAlpha: Double
    var prefsAlpha: Double
    var gridAlpha: Double
    var sweep: Double
    var pulse: Double
    var flare: Double
    var ink: Color

    static func make(elapsed: Double, size: CGSize, plan: StartupPlan, dock: CGRect, accent: Color) -> StartupFrame {
        let t = max(0, elapsed)
        let boot = unit(t, 0, plan.bootEnd)
        let collapse = CGFloat(smooth(unit(t, plan.bootEnd, plan.collapseEnd)))
        let bloom = smooth(unit(t, plan.collapseEnd, plan.collapseEnd + 0.55))
        let powerSpan = plan.duration - plan.bloomEnd
        let dockStart = plan.bloomEnd + powerSpan * 0.32
        let dockT = smooth(unit(t, dockStart, plan.duration))
        let full = min(size.width, size.height) * 0.30
        let homeRadius = dock.width > 1 ? max(36, (dock.width - 72) / 2) : full * 0.46
        let homeCenter = dock.width > 1
            ? CGPoint(x: dock.midX, y: dock.midY)
            : CGPoint(x: size.width / 2, y: size.height * 0.38)
        let screenCenter = CGPoint(x: size.width / 2, y: size.height / 2)
        let radius = lerp(lerp(8, full, CGFloat(bloom)), homeRadius, CGFloat(dockT))
        let center = lerp(screenCenter, homeCenter, CGFloat(dockT))
        let bootAlpha = 1 - smooth(unit(t, plan.bootEnd, plan.collapseEnd))
        let ringFade = 1 - smooth(unit(dockT, 0.72, 1))
        let ringAlpha = bloom * ringFade
        let wordIn = smooth(unit(t, plan.collapseEnd + 0.12, plan.collapseEnd + 0.5))
        let wordOut = 1 - smooth(unit(dockT, 0.02, 0.42))
        let span = max(0.2, plan.bloomEnd - plan.collapseEnd)
        let prefsIn = plan.short ? 0.0 : smooth(unit(t, plan.collapseEnd + span * 0.36, plan.collapseEnd + span * 0.5))
        let prefsOut = plan.short ? 0.0 : 1 - smooth(unit(t, plan.bloomEnd - 0.2, plan.bloomEnd + 0.1))
        let power = smooth(unit(t, plan.bloomEnd, plan.bloomEnd + powerSpan * 0.28)) * (1 - dockT)
        let starts = [0.14, 0.36, 0.56, 0.76]
        let terminals = starts.enumerated().map { index, mark in
            let appear = smooth(unit(t, plan.bootEnd * mark, plan.bootEnd * mark + 0.12))
            let step = Int(t * 18)
            let glitch = ((step * 31 + index * 17) % 11) == 0 ? 0.32 : 1.0
            return appear * glitch * bootAlpha
        }
        let ink = accent.mix(with: Color(hex: "#2E8BFF"), by: dockT * 0.85)
        return StartupFrame(
            backdrop: 1 - smooth(unit(dockT, 0.12, 0.92)),
            bootAlpha: bootAlpha,
            collapse: collapse,
            terminals: terminals,
            bar: min(1, boot / 0.92),
            cursorOn: Int(t * 2).isMultiple(of: 2),
            titleSize: size.width < 360 ? 16 : 20,
            dotRadius: lerp(3, 16, collapse) * (1 - CGFloat(bloom) * 0.4),
            dotAlpha: smooth(unit(t, plan.bootEnd, plan.bootEnd + 0.08)) * ringFade,
            ringAlpha: ringAlpha,
            ringRadius: radius,
            center: center,
            spins: [t * 0.35, -t * 0.62, t * 0.9, -t * 0.22],
            wordAlpha: wordIn * wordOut,
            prefsAlpha: prefsIn * prefsOut,
            gridAlpha: ringAlpha * (1 - dockT) * 0.9,
            sweep: t * 1.7,
            pulse: power * (0.55 + 0.45 * sin(t * 9)),
            flare: bootAlpha,
            ink: ink
        )
    }
}

private enum StartupCanvas {
    static func paint(_ context: GraphicsContext, size: CGSize, frame: StartupFrame) {
        var boot = context
        let anchor = CGPoint(x: size.width / 2, y: size.height / 2)
        boot.translateBy(x: anchor.x, y: anchor.y)
        boot.scaleBy(x: 1 - frame.collapse * 0.92, y: 1 - frame.collapse * 0.92)
        boot.translateBy(x: -anchor.x, y: -anchor.y)
        boot.opacity = frame.bootAlpha
        flare(boot, size: size, frame: frame)
        frameLines(boot, size: size, frame: frame)

        if frame.dotAlpha > 0.02 {
            let dot = CGRect(
                x: frame.center.x - frame.dotRadius,
                y: frame.center.y - frame.dotRadius,
                width: frame.dotRadius * 2,
                height: frame.dotRadius * 2
            )
            context.fill(
                Path(ellipseIn: dot.insetBy(dx: -10, dy: -10)),
                with: .radialGradient(
                    Gradient(colors: [frame.ink.opacity(0.85 * frame.dotAlpha), .clear]),
                    center: frame.center,
                    startRadius: 0,
                    endRadius: frame.dotRadius + 18
                )
            )
            context.fill(Path(ellipseIn: dot), with: .color(.white.opacity(frame.dotAlpha)))
        }

        guard frame.ringAlpha > 0.01 else { return }
        var rings = context
        rings.translateBy(x: frame.center.x, y: frame.center.y)
        rings.opacity = frame.ringAlpha
        let radii: [CGFloat] = [1, 0.82, 0.64, 0.46]
        let dashes: [[CGFloat]] = [[], [7, 6], [1.2, 5], []]
        let widths: [CGFloat] = [1.6, 1.3, 1.8, 1.1]
        for index in 0..<4 {
            var layer = rings
            layer.rotate(by: .radians(frame.spins[index]))
            let radius = frame.ringRadius * radii[index]
            let path = Path(ellipseIn: CGRect(x: -radius, y: -radius, width: radius * 2, height: radius * 2))
            let width = widths[index] + CGFloat(frame.pulse) * 1.4
            let style = StrokeStyle(lineWidth: width, lineCap: .round, dash: dashes[index])
            layer.stroke(path, with: .color(frame.ink.opacity(0.9)), style: style)
        }
        let core = frame.ringRadius * 0.28
        rings.fill(
            Path(ellipseIn: CGRect(x: -core, y: -core, width: core * 2, height: core * 2)),
            with: .radialGradient(
                Gradient(colors: [.white.opacity(0.9), frame.ink.opacity(0.45), .clear]),
                center: .zero,
                startRadius: 0,
                endRadius: core
            )
        )
        sweep(rings, radius: frame.ringRadius * 1.05, angle: frame.sweep, ink: frame.ink)
        sweep(rings, radius: frame.ringRadius * 0.72, angle: -frame.sweep * 1.3, ink: frame.ink.opacity(0.7))

        if frame.gridAlpha > 0.02 {
            grid(context, size: size, frame: frame)
        }
    }

    private static func flare(_ source: GraphicsContext, size: CGSize, frame: StartupFrame) {
        var context = source
        let center = CGPoint(x: 0, y: size.height * 0.46)
        let rect = CGRect(x: -30, y: size.height * 0.22, width: size.width * 0.62, height: size.height * 0.5)
        context.fill(
            Path(ellipseIn: rect),
            with: .radialGradient(
                Gradient(colors: [
                    .white.opacity(0.75 * frame.flare),
                    frame.ink.opacity(0.45 * frame.flare),
                    .clear,
                ]),
                center: center,
                startRadius: 0,
                endRadius: size.width * 0.48
            )
        )
    }

    private static func frameLines(_ source: GraphicsContext, size: CGSize, frame: StartupFrame) {
        var context = source
        var path = Path()
        path.move(to: CGPoint(x: 18, y: 28))
        path.addLine(to: CGPoint(x: size.width - 18, y: 28))
        path.move(to: CGPoint(x: 18, y: size.height - 28))
        path.addLine(to: CGPoint(x: size.width - 18, y: size.height - 28))
        context.stroke(path, with: .color(frame.ink.opacity(0.28)), lineWidth: 3)
        context.stroke(path, with: .color(frame.ink.opacity(0.95)), lineWidth: 1)
    }

    private static func sweep(_ source: GraphicsContext, radius: CGFloat, angle: Double, ink: Color) {
        var context = source
        var path = Path()
        path.addArc(
            center: .zero,
            radius: radius,
            startAngle: .radians(angle),
            endAngle: .radians(angle + 0.9),
            clockwise: false
        )
        context.stroke(path, with: .color(ink), style: StrokeStyle(lineWidth: 2, lineCap: .round))
    }

    private static func grid(_ source: GraphicsContext, size: CGSize, frame: StartupFrame) {
        var layer = source
        let span = frame.ringRadius * 2.3
        let box = CGRect(
            x: frame.center.x - span / 2,
            y: frame.center.y - span / 2,
            width: span,
            height: span
        )
        layer.clip(to: Path(ellipseIn: box))
        layer.opacity = frame.gridAlpha * 0.35
        var path = Path()
        let step: CGFloat = 26
        var x = box.minX
        while x <= box.maxX {
            path.move(to: CGPoint(x: x, y: box.minY))
            path.addLine(to: CGPoint(x: x, y: box.maxY))
            x += step
        }
        var y = box.minY
        while y <= box.maxY {
            path.move(to: CGPoint(x: box.minX, y: y))
            path.addLine(to: CGPoint(x: box.maxX, y: y))
            y += step
        }
        layer.stroke(path, with: .color(frame.ink), lineWidth: 0.6)
    }
}

private func unit(_ time: Double, _ start: Double, _ end: Double) -> Double {
    guard end > start else { return time >= end ? 1 : 0 }
    return min(1, max(0, (time - start) / (end - start)))
}

private func smooth(_ value: Double) -> Double {
    let t = min(1, max(0, value))
    return t * t * (3 - 2 * t)
}

private func lerp(_ a: CGFloat, _ b: CGFloat, _ t: CGFloat) -> CGFloat {
    a + (b - a) * t
}

private func lerp(_ a: CGPoint, _ b: CGPoint, _ t: CGFloat) -> CGPoint {
    CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)
}
