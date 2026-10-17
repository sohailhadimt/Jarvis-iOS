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
            canvas?.tick(link)
        }
    }

    private var link: CADisplayLink?
    private var frameLink: FrameLink?
    private var wantsRunning = true
    private var laidOutSize = CGSize.zero

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
        guard bounds.size != laidOutSize, bounds.width > 1, bounds.height > 1 else { return }
        laidOutSize = bounds.size
        let side = bounds.width
        let ringRect = CGRect(x: 0, y: 0, width: side, height: side)
        let path = UIBezierPath(ovalIn: ringRect.insetBy(dx: 8, dy: 8)).cgPath
        for ring in [bloomWide, bloomTight, inner, rim] {
            ring.frame = bounds
            ring.path = path
        }
        let inset = side * 0.08
        disc.frame = ringRect.insetBy(dx: inset, dy: inset)
        disc.cornerRadius = disc.bounds.width / 2
        disc.masksToBounds = true
        inner.path = UIBezierPath(ovalIn: ringRect.insetBy(dx: side * 0.11, dy: side * 0.11)).cgPath
        let hotWidth = side * 0.22
        hotspot.bounds = CGRect(x: 0, y: 0, width: hotWidth, height: 8)
        hotspot.cornerRadius = 4
        hotspot.position = CGPoint(x: side / 2, y: side - 10)
        floorGlow.frame = CGRect(x: side * 0.06, y: side + 2, width: side * 0.88, height: 16)
        floorGlow.cornerRadius = 8
        floorLine.frame = CGRect(x: side * 0.18, y: side + 8, width: side * 0.64, height: 2)
        floorLine.cornerRadius = 1
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
        bloomWide.lineWidth = 16 + pulse * 18
        bloomWide.opacity = Float(0.18 + pulse * 0.28)
        bloomTight.lineWidth = 7 + pulse * 8
        bloomTight.opacity = Float(0.35 + pulse * 0.4)
        rim.lineWidth = 2.5 + pulse * 1.8
        hotspot.opacity = Float(0.45 + pulse * 0.5)
        let hotHeight = 7 + pulse * 5
        if abs(hotspot.bounds.height - hotHeight) > 0.4 {
            hotspot.bounds.size.height = hotHeight
            hotspot.cornerRadius = hotHeight / 2
        }
        floorGlow.opacity = Float(0.35 + pulse * 0.45)
        floorLine.opacity = Float(0.7 + min(pulse, 0.3))
    }

    deinit {
        link?.invalidate()
    }
}
