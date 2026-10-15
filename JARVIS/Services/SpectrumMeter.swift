import Accelerate
import AVFoundation

/// Three-band magnitudes from the live mic or playback tap. Read from the Metal draw loop.
final class SpectrumMeter: @unchecked Sendable {
    static let shared = SpectrumMeter()

    private let lock = NSLock()
    private let n = 256
    private let log2n: vDSP_Length = 8
    private var setup: FFTSetup?
    private var window = [Float](repeating: 0, count: 256)
    private var low: Float = 0
    private var mid: Float = 0
    private var high: Float = 0

    private init() {
        setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))
        window.withUnsafeMutableBufferPointer { ptr in
            guard let base = ptr.baseAddress else { return }
            vDSP_hann_window(base, vDSP_Length(n), Int32(vDSP_HANN_NORM))
        }
    }

    deinit {
        if let setup { vDSP_destroy_fftsetup(setup) }
    }

    func push(_ buffer: AVAudioPCMBuffer) {
        guard let data = buffer.floatChannelData?[0], let setup else { return }
        let frames = Int(buffer.frameLength)
        guard frames >= 32 else { return }
        lock.lock()
        defer { lock.unlock() }

        var samples = [Float](repeating: 0, count: n)
        let copyCount = min(n, frames)
        for i in 0..<copyCount {
            samples[i] = data[i] * window[i]
        }
        var real = [Float](repeating: 0, count: n / 2)
        var imag = [Float](repeating: 0, count: n / 2)
        real.withUnsafeMutableBufferPointer { realBuf in
            imag.withUnsafeMutableBufferPointer { imagBuf in
                guard let r = realBuf.baseAddress, let i = imagBuf.baseAddress else { return }
                var split = DSPSplitComplex(realp: r, imagp: i)
                samples.withUnsafeBytes { raw in
                    guard let base = raw.baseAddress?.assumingMemoryBound(to: DSPComplex.self) else { return }
                    vDSP_ctoz(base, 1, &split, 1, vDSP_Length(n / 2))
                }
                vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                var mags = [Float](repeating: 0, count: n / 2)
                vDSP_zvmags(&split, 1, &mags, 1, vDSP_Length(n / 2))
                func band(_ a: Int, _ b: Int) -> Float {
                    var sum: Float = 0
                    for index in a..<b { sum += mags[index] }
                    return (sum / Float(b - a)).squareRoot()
                }
                func norm(_ value: Float) -> Float { min(Float(1), value * 6) }
                low = low * 0.62 + norm(band(1, 5)) * 0.38
                mid = mid * 0.62 + norm(band(5, 18)) * 0.38
                high = high * 0.62 + norm(band(18, 64)) * 0.38
            }
        }
    }

    func bands() -> SIMD3<Float> {
        lock.lock()
        defer { lock.unlock() }
        return SIMD3(low, mid, high)
    }
}
