import SwiftUI
import UIKit

/// The home ring. A display link updates layer properties in place, up to 120fps on ProMotion.
/// Paths are rebuilt only when the view's size changes.
struct JarvisRingHost: UIViewRepresentable {
    var paused: Bool

    func makeUIView(context: Context) -> JarvisRingCanvas {
        let view = JarvisRingCanvas()
        view.isUserInteractionEnabled = false
        view.backgroundColor = .clear
        view.isAccessibilityElement = true
        view.accessibilityLabel = "JARVIS"
        return view
    }

    func updateUIView(_ view: JarvisRingCanvas, context: Context) {
        view.setPaused(paused)
    }
}

final class JarvisRingCanvas: UIView {
    private let motion = RingMotion()
    /// The display link retains its target. This box holds the canvas weakly so hiding the ring can release it.
    private final class FrameLink: NSObject {
        weak var canvas: JarvisRingCanvas?
        @objc func tick(_ link: CADisplayLink) {
            // The link is added to the main run loop.
            MainActor.assumeIsolated {
                canvas?.tick(link)
            }
        }
    }

    private var link: CADisplayLink?
    private var frameLink: FrameLink?
    private var wantsRunning = true
    private var laidOutSize = CGSize.zero
    private var laidOutScale: CGFloat = 0

    private let bloomWide = CAShapeLayer()
    private let bloomTight = CAShapeLayer()
    private let disc = CAGradientLayer()
    private let inner = CAShapeLayer()
    private let rim = CAShapeLayer()
    private let hotspot = CALayer()
    private let floorGlow = CAGradientLayer()
    private let floorLine = CAGradientLayer()

    private static let bloomColor = UIColor(red: 46 / 255, green: 139 / 255, blue: 255 / 255, alpha: 1).cgColor
    private static let rimColor = UIColor(white: 1, alpha: 0.95).cgColor
    private static let innerColor = UIColor(white: 1, alpha: 0.22).cgColor

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = false
        for ring in [bloomWide, bloomTight, inner, rim] {
            ring.fillColor = nil
            ring.lineCap = .round
        }
        bloomWide.strokeColor = Self.bloomColor
        bloomTight.strokeColor = Self.bloomColor
        bloomWide.shadowColor = Self.bloomColor
        bloomTight.shadowColor = Self.bloomColor
        bloomWide.shadowOffset = .zero
        bloomTight.shadowOffset = .zero
        bloomWide.masksToBounds = false
        bloomTight.masksToBounds = false
        inner.strokeColor = Self.innerColor
        rim.strokeColor = Self.rimColor
        // Bloom sits behind the dark centre. The inner ring and rim sit in front of it.
        layer.addSublayer(bloomWide)
        layer.addSublayer(bloomTight)
        disc.type = .radial
        disc.colors = [
            UIColor(red: 7 / 255, green: 12 / 255, blue: 22 / 255, alpha: 1).cgColor,
            UIColor(red: 5 / 255, green: 8 / 255, blue: 15 / 255, alpha: 1).cgColor,
            UIColor(red: 2 / 255, green: 4 / 255, blue: 10 / 255, alpha: 1).cgColor
        ]
        disc.startPoint = CGPoint(x: 0.5, y: 0.5)
        disc.endPoint = CGPoint(x: 1, y: 1)
        layer.addSublayer(disc)
        layer.addSublayer(inner)
        layer.addSublayer(rim)
        hotspot.backgroundColor = UIColor.white.cgColor
        hotspot.cornerCurve = .continuous
        layer.addSublayer(hotspot)
        configure(floorGlow, colors: [
            UIColor.clear.cgColor,
            UIColor(red: 46 / 255, green: 139 / 255, blue: 255 / 255, alpha: 0.55).cgColor,
            UIColor.clear.cgColor
        ])
        configure(floorLine, colors: [
            UIColor.clear.cgColor,
            UIColor(red: 46 / 255, green: 139 / 255, blue: 255 / 255, alpha: 0.45).cgColor,
            UIColor.white.cgColor,
            UIColor(red: 46 / 255, green: 139 / 255, blue: 255 / 255, alpha: 0.45).cgColor,
            UIColor.clear.cgColor
        ])
        layer.addSublayer(floorGlow)
        layer.addSublayer(floorLine)
        apply(0.22)
    }

    required init?(coder: NSCoder) { return nil }

    func setPaused(_ paused: Bool) {
        wantsRunning = !paused
        updateLink()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        updateLink()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let rasterScale = traitCollection.displayScale
        let resolvedScale: CGFloat = rasterScale > 1 ? rasterScale : 2
        guard bounds.width > 100, bounds.height > 80 else { return }
        guard bounds.size != laidOutSize || resolvedScale != laidOutScale else { return }
        laidOutSize = bounds.size
        laidOutScale = resolvedScale
        // The view is wider than the ring so the cached blur can extend past the rim.
        let pad: CGFloat = 28
        let side = bounds.width - pad * 2
        let ringRect = CGRect(x: pad, y: 4, width: side, height: side)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let oval = UIBezierPath(ovalIn: ringRect.insetBy(dx: 8, dy: 8)).cgPath
        inner.frame = bounds
        rim.frame = bounds
        inner.path = UIBezierPath(ovalIn: ringRect.insetBy(dx: side * 0.11, dy: side * 0.11)).cgPath
        rim.path = oval
        installBloom(bloomWide, in: ringRect, lineWidth: 12, shadowRadius: 20, shadowOpacity: 0.9, strokeAlpha: 0.28, scale: resolvedScale)
        installBloom(bloomTight, in: ringRect, lineWidth: 4.5, shadowRadius: 8, shadowOpacity: 1, strokeAlpha: 0.72, scale: resolvedScale)
        let inset = side * 0.08
        disc.frame = ringRect.insetBy(dx: inset, dy: inset)
        disc.cornerRadius = disc.bounds.width / 2
        disc.masksToBounds = true
        let hotWidth = side * 0.22
        hotspot.bounds = CGRect(x: 0, y: 0, width: hotWidth, height: 9)
        hotspot.cornerRadius = 4.5
        hotspot.position = CGPoint(x: ringRect.midX, y: ringRect.maxY - 10)
        floorGlow.frame = CGRect(x: ringRect.minX + side * 0.06, y: ringRect.maxY + 2, width: side * 0.88, height: 16)
        floorGlow.cornerRadius = 8
        floorLine.frame = CGRect(x: ringRect.minX + side * 0.18, y: ringRect.maxY + 8, width: side * 0.64, height: 2)
        floorLine.cornerRadius = 1
        CATransaction.commit()
    }

    /// Fixed stroke and shadow. Rasterized once per size so a frame only fades and scales the bitmap.
    private func installBloom(_ ring: CAShapeLayer, in ringRect: CGRect, lineWidth: CGFloat, shadowRadius: CGFloat, shadowOpacity: Float, strokeAlpha: CGFloat, scale: CGFloat) {
        ring.frame = ringRect
        let local = CGRect(origin: .zero, size: ringRect.size).insetBy(dx: 8, dy: 8)
        let oval = UIBezierPath(ovalIn: local).cgPath
        ring.path = oval
        ring.lineWidth = lineWidth
        ring.strokeColor = UIColor(red: 46 / 255, green: 139 / 255, blue: 1, alpha: strokeAlpha).cgColor
        ring.fillColor = nil
        ring.shadowColor = Self.bloomColor
        ring.shadowRadius = shadowRadius
        ring.shadowOpacity = shadowOpacity
        ring.shadowOffset = .zero
        ring.shadowPath = oval.copy(strokingWithWidth: lineWidth, lineCap: .round, lineJoin: .round, miterLimit: 10, transform: .identity)
        ring.masksToBounds = false
        ring.shouldRasterize = true
        ring.rasterizationScale = scale
    }

    private func configure(_ gradient: CAGradientLayer, colors: [CGColor]) {
        gradient.colors = colors
        gradient.startPoint = CGPoint(x: 0, y: 0.5)
        gradient.endPoint = CGPoint(x: 1, y: 0.5)
    }

    private func updateLink() {
        if window == nil {
            link?.invalidate()
            link = nil
            frameLink = nil
            return
        }
        let shouldRun = wantsRunning
        if shouldRun {
            if link == nil {
                let box = FrameLink()
                box.canvas = self
                frameLink = box
                let next = CADisplayLink(target: box, selector: #selector(FrameLink.tick(_:)))
                next.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 120, preferred: 120)
                next.add(to: .main, forMode: .common)
                link = next
            } else {
                link?.isPaused = false
            }
        } else {
            link?.isPaused = true
        }
    }

    fileprivate func tick(_ link: CADisplayLink) {
        let pulse = motion.sample(level: VoiceMeter.shared.level, phase: VoiceMeter.shared.phase, now: link.timestamp)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        apply(pulse)
        CATransaction.commit()
    }

    private func apply(_ pulse: Double) {
        let scale = 1 + max(0, pulse - 0.18) * 0.04
        let transform = CATransform3DMakeScale(scale, scale, 1)
        bloomWide.transform = transform
        bloomTight.transform = transform
        bloomWide.opacity = Float(min(1, 0.62 + pulse * 0.38))
        bloomTight.opacity = Float(min(1, 0.7 + pulse * 0.3))
        rim.lineWidth = 2.5 + pulse * 1.8
        hotspot.opacity = Float(0.45 + pulse * 0.5)
        floorGlow.opacity = Float(0.35 + pulse * 0.45)
        floorLine.opacity = Float(0.7 + min(pulse, 0.3))
    }

    deinit {
        MainActor.assumeIsolated {
            link?.invalidate()
        }
    }
}
