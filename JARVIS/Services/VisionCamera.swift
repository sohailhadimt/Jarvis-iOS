import AVFoundation
import CoreImage
import CoreVideo
import Observation
import SwiftUI
import UIKit

enum CameraOwner: Hashable {
    case voice
    case panel
}

private enum CameraFailure: LocalizedError {
    case unavailable
    case denied

    var errorDescription: String? {
        switch self {
        case .unavailable:
            "This iPhone has no camera JARVIS can use."
        case .denied:
            "Camera access is off. Enable it in iPhone Settings > JARVIS > Camera."
        }
    }
}

/// Latest camera JPEG. Written on the frame queue, read on the main actor.
private final class FrameBox: @unchecked Sendable {
    private let lock = NSLock()
    private var jpeg: Data?

    func store(_ data: Data) {
        lock.lock()
        jpeg = data
        lock.unlock()
    }

    func clear() {
        lock.lock()
        jpeg = nil
        lock.unlock()
    }

    func copy() -> Data? {
        lock.lock()
        let value = jpeg
        lock.unlock()
        return value
    }
}

/// Video-only capture. The session does not touch the voice-chat audio session.
private final class CameraPump: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    let session = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "jarvis.vision.session")
    private let frameQueue = DispatchQueue(label: "jarvis.vision.frames")
    private let box = FrameBox()
    private let context = CIContext(options: nil)
    private var output: AVCaptureVideoDataOutput?
    private var configured = false
    private var position: AVCaptureDevice.Position = .back
    private var lastAt: Double = 0

    func latest() -> Data? {
        box.copy()
    }

    func start() async -> String? {
        await withCheckedContinuation { continuation in
            sessionQueue.async {
                do {
                    try self.configureIfNeeded()
                    self.box.clear()
                    if !self.session.isRunning {
                        self.session.startRunning()
                    }
                    continuation.resume(returning: nil)
                } catch {
                    continuation.resume(returning: error.localizedDescription)
                }
            }
        }
    }

    func stop() {
        sessionQueue.async {
            if self.session.isRunning {
                self.session.stopRunning()
            }
        }
    }

    func flip() {
        sessionQueue.async {
            self.flipOnQueue()
        }
    }

    private func configureIfNeeded() throws {
        if configured { return }
        session.beginConfiguration()
        session.sessionPreset = .vga640x480
        session.automaticallyConfiguresApplicationAudioSession = false
        do {
            guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back)
                    ?? AVCaptureDevice.default(for: .video) else {
                throw CameraFailure.unavailable
            }
            let input = try AVCaptureDeviceInput(device: device)
            guard session.canAddInput(input) else { throw CameraFailure.unavailable }
            session.addInput(input)
            let video = AVCaptureVideoDataOutput()
            let format = NSNumber(value: kCVPixelFormatType_32BGRA)
            let videoSettings: [String: Any] = [kCVPixelBufferPixelFormatTypeKey as String: format]
            video.videoSettings = videoSettings
            video.alwaysDiscardsLateVideoFrames = true
            video.setSampleBufferDelegate(self, queue: frameQueue)
            guard session.canAddOutput(video) else { throw CameraFailure.unavailable }
            session.addOutput(video)
            apply(connection: video.connection(with: .video))
            output = video
            session.commitConfiguration()
            configured = true
        } catch {
            session.commitConfiguration()
            session.beginConfiguration()
            for input in session.inputs {
                session.removeInput(input)
            }
            if let video = output {
                session.removeOutput(video)
                output = nil
            }
            configured = false
            session.commitConfiguration()
            throw error
        }
    }

    private func apply(connection: AVCaptureConnection?) {
        guard let connection else { return }
        let angle: CGFloat = 90
        if connection.isVideoRotationAngleSupported(angle) {
            connection.videoRotationAngle = angle
        }
    }

    private func flipOnQueue() {
        guard configured else { return }
        let next: AVCaptureDevice.Position = position == .back ? .front : .back
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: next) else { return }
        session.beginConfiguration()
        let previous = session.inputs
        for input in previous {
            session.removeInput(input)
        }
        do {
            let input = try AVCaptureDeviceInput(device: device)
            if session.canAddInput(input) {
                session.addInput(input)
                position = next
                apply(connection: output?.connection(with: .video))
                session.commitConfiguration()
                return
            }
        } catch {
            // The previous camera is put back below.
        }
        for input in previous {
            if session.canAddInput(input) {
                session.addInput(input)
            }
        }
        session.commitConfiguration()
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        let now: Double = CACurrentMediaTime()
        let elapsed: Double = now - lastAt
        if elapsed < 1.0 { return }
        lastAt = now
        guard let jpeg = jpeg(from: sampleBuffer) else { return }
        box.store(jpeg)
    }

    private func jpeg(from sampleBuffer: CMSampleBuffer) -> Data? {
        guard let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return nil }
        var image = CIImage(cvPixelBuffer: buffer)
        let width: CGFloat = image.extent.width
        let height: CGFloat = image.extent.height
        let longest: CGFloat = max(width, height)
        let limit: CGFloat = 768
        if longest > limit && longest > 0 {
            let ratio: CGFloat = limit / longest
            image = image.transformed(by: CGAffineTransform(scaleX: ratio, y: ratio))
        }
        guard let cg = context.createCGImage(image, from: image.extent) else { return nil }
        let ui = UIImage(cgImage: cg)
        let quality: CGFloat = 0.55
        guard var data = ui.jpegData(compressionQuality: quality) else { return nil }
        if data.count > 400_000 {
            let tighter: CGFloat = 0.35
            if let smaller = ui.jpegData(compressionQuality: tighter) {
                data = smaller
            }
        }
        return data
    }
}

/// Shared camera for the voice screen and the Vision panel.
@MainActor
@Observable
final class VisionCamera {
    static let shared = VisionCamera()

    private let pump = CameraPump()
    private var owners: Set<CameraOwner> = []
    private var heldJPEG: Data?

    var isLive = false
    var note: String?
    var heldPreview: UIImage?
    var hasHeld: Bool { heldJPEG != nil }

    var previewSession: AVCaptureSession { pump.session }

    private init() {}

    func acquire(owner: CameraOwner) async {
        owners.insert(owner)
        if isLive { return }
        let granted = await Self.authorize()
        guard owners.contains(owner) else { return }
        guard granted else {
            owners.remove(owner)
            note = CameraFailure.denied.localizedDescription
            return
        }
        if let problem = await pump.start() {
            guard owners.contains(owner) else {
                pump.stop()
                return
            }
            owners.remove(owner)
            isLive = false
            note = JarvisLines.explain(problem)
            return
        }
        guard owners.contains(owner) else {
            pump.stop()
            return
        }
        isLive = true
        note = "Camera on. Ask what I see."
    }

    func release(owner: CameraOwner) {
        owners.remove(owner)
        guard owners.isEmpty else { return }
        isLive = false
        pump.stop()
        if heldJPEG == nil {
            note = nil
        }
    }

    /// Voice-screen button. Stops the camera even if the Vision panel is also open.
    func toggleFromVoice() async {
        if isLive {
            suspend()
        } else {
            await acquire(owner: .voice)
        }
    }

    /// Backgrounding stops the sensor. A snapped photo is kept for the next question.
    func suspend() {
        let holding = heldJPEG != nil
        owners.removeAll()
        isLive = false
        pump.stop()
        note = holding ? "Photo held. Ask what you see." : nil
    }

    func flip() {
        pump.flip()
    }

    func holdStill() {
        guard let data = pump.latest() else {
            note = "Hold still a moment, then snap again."
            return
        }
        heldJPEG = data
        heldPreview = UIImage(data: data)
        note = "Photo held. Ask what you see."
    }

    func discardHeld() {
        heldJPEG = nil
        heldPreview = nil
        if isLive {
            note = "Camera on. Ask what I see."
        } else {
            note = nil
        }
    }

    /// Snapped photo, or the latest live frame. A snap is consumed once.
    func frameForQuestion() -> Data? {
        if let held = heldJPEG {
            heldJPEG = nil
            heldPreview = nil
            note = nil
            return held
        }
        guard isLive else { return nil }
        return pump.latest()
    }

    private static func authorize() async -> Bool {
        let status = AVCaptureDevice.authorizationStatus(for: .video)
        if status == .authorized { return true }
        if status == .denied || status == .restricted { return false }
        return await withCheckedContinuation { continuation in
            AVCaptureDevice.requestAccess(for: .video) { granted in
                continuation.resume(returning: granted)
            }
        }
    }
}

struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession

    func makeUIView(context: Context) -> PreviewHost {
        let view = PreviewHost()
        view.previewLayer.session = session
        view.previewLayer.videoGravity = .resizeAspectFill
        return view
    }

    func updateUIView(_ uiView: PreviewHost, context: Context) {
        uiView.previewLayer.session = session
        uiView.applyPortrait()
    }
}

final class PreviewHost: UIView {
    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }

    var previewLayer: AVCaptureVideoPreviewLayer {
        layer as! AVCaptureVideoPreviewLayer
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        applyPortrait()
    }

    func applyPortrait() {
        let angle: CGFloat = 90
        guard let connection = previewLayer.connection else { return }
        if connection.isVideoRotationAngleSupported(angle) {
            connection.videoRotationAngle = angle
        }
    }
}
