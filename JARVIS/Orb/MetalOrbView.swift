import Metal
import MetalKit
import simd
import SwiftUI
import UIKit

/// Home-screen orb. Metal draws the five layers; SwiftUI only hosts the view and the state inputs.
struct MetalOrbView: UIViewRepresentable {
    var level: Double
    var phase: JarvisPhase
    var sessionActive: Bool
    var executing: Bool
    var hasError: Bool
    var reply: String
    var paused: Bool

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> OrbMTKView {
        let view = OrbMTKView()
        view.owner = context.coordinator
        view.device = MTLCreateSystemDefaultDevice()
        view.delegate = context.coordinator
        view.colorPixelFormat = .bgra8Unorm
        view.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        view.framebufferOnly = true
        view.isOpaque = true
        view.isPaused = false
        view.enableSetNeedsDisplay = false
        view.preferredFramesPerSecond = 60
        view.backgroundColor = .black
        context.coordinator.attach(view)
        return view
    }

    func updateUIView(_ uiView: OrbMTKView, context: Context) {
        let coordinator = context.coordinator
        coordinator.level = Float(min(1, max(0, level)))
        coordinator.phase = phase
        coordinator.sessionActive = sessionActive
        coordinator.executing = executing
        coordinator.hasError = hasError
        coordinator.reply = reply
        coordinator.externallyPaused = paused
        coordinator.applyPause(on: uiView)
    }
}

final class OrbMTKView: MTKView {
    weak var owner: MetalOrbView.Coordinator?

    override func didMoveToWindow() {
        super.didMoveToWindow()
        owner?.viewVisibilityChanged(window != nil)
    }
}

extension MetalOrbView {
    final class Coordinator: NSObject, MTKViewDelegate {
        var level: Float = 0
        var phase: JarvisPhase = .idle
        var sessionActive = false
        var executing = false
        var hasError = false
        var reply = ""
        var externallyPaused = false

        private var inWindow = false
        private var device: MTLDevice?
        private var queue: MTLCommandQueue?
        private var pointPipeline: MTLRenderPipelineState?
        private var solidPipeline: MTLRenderPipelineState?
        private var linePipeline: MTLRenderPipelineState?
        private var corePipeline: MTLRenderPipelineState?
        private var microPipeline: MTLRenderPipelineState?
        private var bloomPipeline: MTLRenderPipelineState?
        private var offscreen: MTLTexture?
        private var lines2: MTLBuffer?
        private var verts2: MTLBuffer?
        private var lines3: MTLBuffer?
        private var verts3: MTLBuffer?
        private var lineCount2 = 0
        private var vertCount2 = 0
        private var lineCount3 = 0
        private var vertCount3 = 0
        private weak var view: MTKView?
        private var powerObserver: NSObjectProtocol?
        private var lastTick = CACurrentMediaTime()
        private var wasActive = false
        private var wasSpeaking = false
        private var activateUntil: CFTimeInterval = 0
        private var successUntil: CFTimeInterval = 0
        private var envelope: Float = 0
        private var amplitude: Float = 0.18
        private var glow: Float = 0.35
        private var scan: Float = 0.4
        private var coreSpeed: Float = 0.35
        private var pulsePos: Float = 0
        private var pulseAmt: Float = 0
        private var dim: Float = 0.9
        private var coreGlow: Float = 0.45
        private var nodeFlash: Float = 0

        func attach(_ view: MTKView) {
            self.view = view
            device = view.device
            guard let device else { return }
            queue = device.makeCommandQueue()
            buildPipelines(device: device, format: view.colorPixelFormat)
            let low = MetalIcosphere.make(subdivisions: 2)
            let high = MetalIcosphere.make(subdivisions: 3)
            lines2 = buffer(device, low.lines)
            verts2 = buffer(device, low.vertices)
            lines3 = buffer(device, high.lines)
            verts3 = buffer(device, high.vertices)
            lineCount2 = low.lines.count
            vertCount2 = low.vertices.count
            lineCount3 = high.lines.count
            vertCount3 = high.vertices.count
            powerObserver = NotificationCenter.default.addObserver(
                forName: .NSProcessInfoPowerStateDidChange, object: nil, queue: .main
            ) { [weak self] _ in
                self?.applyFrameRate()
            }
            applyFrameRate()
        }

        deinit {
            if let powerObserver {
                NotificationCenter.default.removeObserver(powerObserver)
            }
        }

        func viewVisibilityChanged(_ visible: Bool) {
            inWindow = visible
            applyPause(on: view)
        }

        func applyPause(on view: MTKView?) {
            view?.isPaused = externallyPaused || !inWindow
            applyFrameRate()
        }

        func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
            offscreen = nil
        }

        func draw(in view: MTKView) {
            let now = CACurrentMediaTime()
            let dt = Float(min(0.05, max(1.0 / 120.0, now - lastTick)))
            lastTick = now
            step(dt: dt, now: now)
            guard let drawable = view.currentDrawable,
                  let queue,
                  let command = queue.makeCommandBuffer(),
                  let target = offscreenTexture(matching: view),
                  let pointPipeline, let ringPipeline, let solidPipeline, let linePipeline,
                  let corePipeline, let microPipeline, let bloomPipeline else { return }

            let scene = MTLRenderPassDescriptor()
            scene.colorAttachments[0].texture = target
            scene.colorAttachments[0].loadAction = .clear
            scene.colorAttachments[0].storeAction = .store
            scene.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
            guard let encoder = command.makeRenderCommandEncoder(descriptor: scene) else { return }

            var uniforms = makeUniforms(view: view)
            let lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
            encoder.setVertexBytes(&uniforms, length: MemoryLayout<OrbUniforms>.stride, index: 0)

            encoder.setRenderPipelineState(pointPipeline)
            encoder.drawPrimitives(type: .point, vertexStart: 0, vertexCount: lowPower ? 720 : 1680)
            encoder.setRenderPipelineState(ringPipeline)
            encoder.drawPrimitives(type: .point, vertexStart: 0, vertexCount: 840)
            encoder.setRenderPipelineState(solidPipeline)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 360)

            let lines = lowPower ? lines2 : lines3
            let verts = lowPower ? verts2 : verts3
            let lineCount = lowPower ? lineCount2 : lineCount3
            let vertCount = lowPower ? vertCount2 : vertCount3
            if let lines, lineCount > 0 {
                encoder.setRenderPipelineState(linePipeline)
                encoder.setVertexBuffer(lines, offset: 0, index: 1)
                encoder.drawPrimitives(type: .line, vertexStart: 0, vertexCount: lineCount)
            }
            if let verts, vertCount > 0 {
                encoder.setRenderPipelineState(corePipeline)
                encoder.setVertexBuffer(verts, offset: 0, index: 1)
                encoder.drawPrimitives(type: .point, vertexStart: 0, vertexCount: vertCount)
            }
            encoder.setRenderPipelineState(microPipeline)
            encoder.drawPrimitives(type: .point, vertexStart: 0, vertexCount: lowPower ? 160 : 420)
            encoder.endEncoding()

            guard let present = view.currentRenderPassDescriptor,
                  let bloom = command.makeRenderCommandEncoder(descriptor: present) else {
                command.commit()
                return
            }
            bloom.setRenderPipelineState(bloomPipeline)
            bloom.setFragmentTexture(target, index: 0)
            bloom.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            bloom.endEncoding()
            command.present(drawable)
            command.commit()
        }

        // MARK: State

        private func step(dt: Float, now: CFTimeInterval) {
            if sessionActive, !wasActive {
                activateUntil = now + 0.55
            }
            if !sessionActive { activateUntil = 0 }
            wasActive = sessionActive
            if phase == .speaking {
                wasSpeaking = true
            } else if wasSpeaking {
                wasSpeaking = false
                if !reply.isEmpty { successUntil = now + 0.70 }
            }
            let visual = currentVisual(now: now)
            let raw = level
            let tau: Float = raw > envelope ? 0.030 : 0.250
            envelope += (raw - envelope) * (Float(1) - exp(-dt / tau))

            let bands = SpectrumMeter.shared.bands()
            let spectral = bands.x * 0.5 + bands.y * 0.35 + bands.z * 0.15
            let cycle = Float(now.truncatingRemainder(dividingBy: 4.8))
            let flip: Float = cycle > 4.0 ? -1 : 1

            let targetAmp: Float
            let targetGlow: Float
            let targetScan: Float
            let targetCore: Float
            let targetDim: Float
            let targetCoreGlow: Float
            let targetFlash: Float
            switch visual {
            case .activating:
                targetAmp = 0.06
                targetGlow = 0.95
                targetScan = 1.3 * flip
                targetCore = 0.85
                targetDim = 1
                targetCoreGlow = 1
                targetFlash = 0.4
            case .listening:
                targetAmp = 0.20 + envelope * 0.85 + spectral * 0.12
                targetGlow = 0.42 + envelope * 0.5
                targetScan = 0.28 * flip
                targetCore = 0.40
                targetDim = 1
                targetCoreGlow = 0.55
                targetFlash = 0
            case .thinking:
                targetAmp = 0.30
                targetGlow = 0.62
                targetScan = 1.7 * flip
                targetCore = 1.05
                targetDim = 1
                targetCoreGlow = 0.85
                targetFlash = 1
            case .speaking:
                targetAmp = 0.18 + envelope * 0.95 + spectral * 0.10
                targetGlow = 0.48 + envelope * 0.45
                targetScan = 0.55 * flip
                targetCore = 0.6
                targetDim = 1
                targetCoreGlow = 0.7
                targetFlash = 0.15
            case .executing:
                targetAmp = 0.16
                targetGlow = 0.58
                targetScan = 0.9
                targetCore = 1.15
                targetDim = 1
                targetCoreGlow = 0.9
                targetFlash = 0.2
            case .success:
                targetAmp = 0.22
                targetGlow = 1
                targetScan = 0.4
                targetCore = 0.5
                targetDim = 1
                targetCoreGlow = 1
                targetFlash = 0.3
            case .error:
                targetAmp = 0.08
                targetGlow = 0.18
                targetScan = 0.12
                targetCore = 0.22
                targetDim = 0.42
                targetCoreGlow = 0.25
                targetFlash = 0
            case .idle:
                targetAmp = 0.16
                targetGlow = 0.34
                targetScan = 0.18 * flip
                targetCore = 0.32
                targetDim = 0.88
                targetCoreGlow = 0.42
                targetFlash = 0
            }

            let k = Float(1) - exp(-dt / 0.16)
            amplitude += (targetAmp - amplitude) * k
            glow += (targetGlow - glow) * k
            scan += (targetScan - scan) * k
            coreSpeed += (targetCore - coreSpeed) * k
            dim += (targetDim - dim) * k
            coreGlow += (targetCoreGlow - coreGlow) * k
            nodeFlash += (targetFlash - nodeFlash) * k

            if visual == .activating {
                pulsePos = Float((now.truncatingRemainder(dividingBy: 0.55)) / 0.55)
                pulseAmt += (Float(1) - pulseAmt) * k
            } else if now < successUntil {
                let remain = Float((successUntil - now) / 0.70)
                pulsePos = Float(1) - remain
                pulseAmt += (remain - pulseAmt) * k
            } else if visual == .thinking {
                pulsePos = Float(now.truncatingRemainder(dividingBy: 1.6) / 1.6)
                pulseAmt += (Float(0.65) - pulseAmt) * k
            } else {
                pulseAmt += (Float(0) - pulseAmt) * k
            }
        }

        private func currentVisual(now: CFTimeInterval) -> OrbVisual {
            if hasError { return .error }
            if sessionActive, now < activateUntil, (phase == .listening || phase == .idle) {
                return .activating
            }
            if executing, phase == .thinking { return .executing }
            switch phase {
            case .speaking: return .speaking
            case .thinking: return .thinking
            case .listening: return .listening
            case .idle:
                return now < successUntil ? .success : .idle
            }
        }

        private func makeUniforms(view: MTKView) -> OrbUniforms {
            let bands = SpectrumMeter.shared.bands()
            let size = view.drawableSize
            let aspect = Float(size.height > 0 ? size.width / size.height : 1)
            return OrbUniforms(
                time: Float(CACurrentMediaTime()),
                amplitude: amplitude,
                level: envelope,
                glow: glow,
                scan: scan,
                coreSpeed: coreSpeed,
                pulsePos: pulsePos,
                pulseAmt: pulseAmt,
                dim: dim,
                quality: ProcessInfo.processInfo.isLowPowerModeEnabled ? Float(0.45) : 1,
                aspect: aspect,
                state: currentVisual(now: CACurrentMediaTime()).raw,
                coreGlow: coreGlow,
                nodeFlash: nodeFlash,
                bandLow: bands.x,
                bandMid: bands.y,
                bandHigh: bands.z
            )
        }

        // MARK: Metal setup

        private var ringPipeline: MTLRenderPipelineState?

        private func buildPipelines(device: MTLDevice, format: MTLPixelFormat) {
            guard let library = device.makeDefaultLibrary() else { return }
            pointPipeline = pipeline(device, library, "membrane_vertex", "point_fragment", format, additive: true)
            ringPipeline = pipeline(device, library, "ring_vertex", "point_fragment", format, additive: true)
            solidPipeline = pipeline(device, library, "segment_vertex", "solid_fragment", format, additive: true)
            linePipeline = pipeline(device, library, "line_vertex", "solid_fragment", format, additive: true)
            corePipeline = pipeline(device, library, "core_vertex", "point_fragment", format, additive: true)
            microPipeline = pipeline(device, library, "micro_vertex", "point_fragment", format, additive: true)
            bloomPipeline = pipeline(device, library, "bloom_vertex", "bloom_fragment", format, additive: false)
        }

        private func pipeline(_ device: MTLDevice, _ library: MTLLibrary, _ vertex: String, _ fragment: String,
                              _ format: MTLPixelFormat, additive: Bool) -> MTLRenderPipelineState? {
            guard let vfn = library.makeFunction(name: vertex),
                  let ffn = library.makeFunction(name: fragment) else { return nil }
            let desc = MTLRenderPipelineDescriptor()
            desc.vertexFunction = vfn
            desc.fragmentFunction = ffn
            desc.colorAttachments[0].pixelFormat = format
            if additive, let attachment = desc.colorAttachments[0] {
                attachment.isBlendingEnabled = true
                attachment.rgbBlendOperation = .add
                attachment.alphaBlendOperation = .add
                attachment.sourceRGBBlendFactor = .one
                attachment.sourceAlphaBlendFactor = .one
                attachment.destinationRGBBlendFactor = .one
                attachment.destinationAlphaBlendFactor = .one
            }
            return try? device.makeRenderPipelineState(descriptor: desc)
        }

        private func buffer(_ device: MTLDevice, _ values: [SIMD4<Float>]) -> MTLBuffer? {
            guard !values.isEmpty else { return nil }
            return device.makeBuffer(bytes: values,
                                     length: MemoryLayout<SIMD4<Float>>.stride * values.count,
                                     options: .storageModeShared)
        }

        private func offscreenTexture(matching view: MTKView) -> MTLTexture? {
            let width = max(1, Int(view.drawableSize.width))
            let height = max(1, Int(view.drawableSize.height))
            if let offscreen, offscreen.width == width, offscreen.height == height { return offscreen }
            let desc = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: view.colorPixelFormat, width: width, height: height, mipmapped: false)
            desc.usage = [.renderTarget, .shaderRead]
            desc.storageMode = .private
            offscreen = view.device?.makeTexture(descriptor: desc)
            return offscreen
        }

        private func applyFrameRate() {
            view?.preferredFramesPerSecond = ProcessInfo.processInfo.isLowPowerModeEnabled ? 30 : 60
        }
    }
}

private enum OrbVisual {
    case idle, activating, listening, thinking, speaking, executing, success, error

    var raw: Float {
        switch self {
        case .idle: 0
        case .activating: 1
        case .listening: 2
        case .thinking: 3
        case .speaking: 4
        case .executing: 5
        case .success: 6
        case .error: 7
        }
    }
}

private struct OrbUniforms {
    var time: Float
    var amplitude: Float
    var level: Float
    var glow: Float
    var scan: Float
    var coreSpeed: Float
    var pulsePos: Float
    var pulseAmt: Float
    var dim: Float
    var quality: Float
    var aspect: Float
    var state: Float
    var coreGlow: Float
    var nodeFlash: Float
    var bandLow: Float
    var bandMid: Float
    var bandHigh: Float
}

private struct MetalIcosphere {
    var lines: [SIMD4<Float>]
    var vertices: [SIMD4<Float>]

    static func make(subdivisions: Int) -> MetalIcosphere {
        let t = Float((1.0 + 5.0.squareRoot()) / 2.0)
        var verts: [SIMD3<Float>] = [
            SIMD3(-1, t, 0), SIMD3(1, t, 0), SIMD3(-1, -t, 0), SIMD3(1, -t, 0),
            SIMD3(0, -1, t), SIMD3(0, 1, t), SIMD3(0, -1, -t), SIMD3(0, 1, -t),
            SIMD3(t, 0, -1), SIMD3(t, 0, 1), SIMD3(-t, 0, -1), SIMD3(-t, 0, 1),
        ].map { simd_normalize($0) }

        var faces: [(Int, Int, Int)] = [
            (0, 11, 5), (0, 5, 1), (0, 1, 7), (0, 7, 10), (0, 10, 11),
            (1, 5, 9), (5, 11, 4), (11, 10, 2), (10, 7, 6), (7, 1, 8),
            (3, 9, 4), (3, 4, 2), (3, 2, 6), (3, 6, 8), (3, 8, 9),
            (4, 9, 5), (2, 4, 11), (6, 2, 10), (8, 6, 7), (9, 8, 1),
        ]
        for _ in 0..<subdivisions {
            var cache: [UInt64: Int] = [:]
            func mid(_ a: Int, _ b: Int) -> Int {
                let key = (UInt64(min(a, b)) << 32) | UInt64(max(a, b))
                if let found = cache[key] { return found }
                let m = simd_normalize((verts[a] + verts[b]) * 0.5)
                verts.append(m)
                let index = verts.count - 1
                cache[key] = index
                return index
            }
            var next: [(Int, Int, Int)] = []
            next.reserveCapacity(faces.count * 4)
            for face in faces {
                let ab = mid(face.0, face.1)
                let bc = mid(face.1, face.2)
                let ca = mid(face.2, face.0)
                next.append((face.0, ab, ca))
                next.append((face.1, bc, ab))
                next.append((face.2, ca, bc))
                next.append((ab, bc, ca))
            }
            faces = next
        }

        var seen = Set<UInt64>()
        var lines: [SIMD4<Float>] = []
        func add(_ a: Int, _ b: Int) {
            let key = (UInt64(min(a, b)) << 32) | UInt64(max(a, b))
            guard seen.insert(key).inserted else { return }
            lines.append(SIMD4(verts[a], 1))
            lines.append(SIMD4(verts[b], 1))
        }
        for face in faces {
            add(face.0, face.1)
            add(face.1, face.2)
            add(face.2, face.0)
        }
        let points = verts.map { SIMD4($0, 1) }
        return MetalIcosphere(lines: lines, vertices: points)
    }
}
