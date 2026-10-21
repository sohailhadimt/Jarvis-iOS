import Accelerate
import Foundation

/// On-device voice print. A short MFCC embedding plus pitch, compared with cosine similarity.
/// A bundled Core ML speaker model was not available in this build, so the print stays local math.
struct SpeakerPrint: Sendable {
    var embedding: [Float]
    var pitchHz: Float
}

struct VoiceProfile: Codable, Sendable {
    var version: Int
    var embedding: [Float]
    var pitchHz: Float
}

enum SpeakerEmbedding {
    static let dimension: Int = 38
    static let profileVersion: Int = 1

    static func profile(samples: [Float], sampleRate: Double) -> VoiceProfile? {
        guard let print = makePrint(samples: samples, sampleRate: sampleRate, minimumFrames: 250) else { return nil }
        guard print.embedding.count == dimension else { return nil }
        return VoiceProfile(version: profileVersion, embedding: print.embedding, pitchHz: print.pitchHz)
    }

    static func makePrint(samples: [Float], sampleRate: Double, minimumFrames: Int) -> SpeakerPrint? {
        MFCCFrontEnd.shared.makePrint(samples: samples, sampleRate: sampleRate, minimumFrames: minimumFrames)
    }

    static func similarity(_ lhs: [Float], _ rhs: [Float]) -> Float {
        guard lhs.count == rhs.count, lhs.count == dimension else { return 0 }
        var dot: Float = 0
        var index: Int = 0
        while index < lhs.count {
            dot += lhs[index] * rhs[index]
            index += 1
        }
        if dot > 1 { return 1 }
        if dot < -1 { return -1 }
        return dot
    }
}

struct SpectralFrame: Sendable {
    var speechBand: Float
    var flatness: Float
}

/// Speech-band share of a short FFT. Values near 1 are voice-shaped; bass and hiss sit lower.
final class SpeechBandMeter: @unchecked Sendable {
    static let shared = SpeechBandMeter()

    private let lock = NSLock()
    private var setup: FFTSetup?
    private let size: Int = 256
    private let log2n: vDSP_Length = 8
    private var window: [Float]

    private init() {
        window = [Float](repeating: 0, count: 256)
        setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))
        window.withUnsafeMutableBufferPointer { ptr in
            guard let base = ptr.baseAddress else { return }
            vDSP_hann_window(base, vDSP_Length(256), Int32(vDSP_HANN_NORM))
        }
    }

    deinit {
        if let setup { vDSP_destroy_fftsetup(setup) }
    }

    func ratio(samples: UnsafePointer<Float>, count: Int, sampleRate: Float) -> Float {
        measure(samples: samples, count: count, sampleRate: sampleRate).speechBand
    }

    /// Speech-band share and spectral flatness for one short frame. Flatness near 1 is hiss.
    func measure(samples: UnsafePointer<Float>, count: Int, sampleRate: Float) -> SpectralFrame {
        guard count >= size, sampleRate > 1_000, let setup else {
            return SpectralFrame(speechBand: 0.5, flatness: 0.35)
        }
        lock.lock()
        defer { lock.unlock() }
        var frame = [Float](repeating: 0, count: size)
        var index: Int = 0
        while index < size {
            frame[index] = samples[index] * window[index]
            index += 1
        }
        let power = Self.power(frame, setup: setup, log2n: log2n)
        var total: Float = 0
        var speech: Float = 0
        var arith: Float = 0
        var logSum: Float = 0
        var used: Float = 0
        let bins: Int = size / 2
        var bin: Int = 1
        while bin < bins {
            let mag: Float = power[bin]
            let hz: Float = sampleRate * Float(bin) / Float(size)
            total += mag
            if hz >= 300 && hz <= 3_400 {
                speech += mag
            }
            let amplitude: Float = mag.squareRoot()
            arith += amplitude
            logSum += log(amplitude + 0.000_000_1)
            used += 1
            bin += 1
        }
        let band: Float = total < 0.000_000_1 ? 0 : speech / total
        let flat: Float
        if used < 1 || arith < 0.000_000_1 {
            flat = 1
        } else {
            let geometric: Float = exp(logSum / used)
            flat = min(1, max(0, geometric / (arith / used)))
        }
        return SpectralFrame(speechBand: band, flatness: flat)
    }

    fileprivate static func power(_ frame: [Float], setup: FFTSetup, log2n: vDSP_Length) -> [Float] {
        let bins: Int = frame.count / 2
        var real = [Float](repeating: 0, count: bins)
        var imag = [Float](repeating: 0, count: bins)
        var power = [Float](repeating: 0, count: bins)
        real.withUnsafeMutableBufferPointer { realBuf in
            imag.withUnsafeMutableBufferPointer { imagBuf in
                guard let realBase = realBuf.baseAddress, let imagBase = imagBuf.baseAddress else { return }
                var split = DSPSplitComplex(realp: realBase, imagp: imagBase)
                frame.withUnsafeBytes { raw in
                    guard let base = raw.baseAddress?.assumingMemoryBound(to: DSPComplex.self) else { return }
                    vDSP_ctoz(base, 1, &split, 1, vDSP_Length(bins))
                }
                vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                vDSP_zvmags(&split, 1, &power, 1, vDSP_Length(bins))
            }
        }
        return power
    }
}

/// MFCC mean, spread, and delta, plus pitch. Shared by enrolment and the live gate.
private final class MFCCFrontEnd: @unchecked Sendable {
    static let shared = MFCCFrontEnd()

    private let lock = NSLock()
    private var setup: FFTSetup?
    private let fftSize: Int = 512
    private let log2n: vDSP_Length = 9
    private let frameLength: Int = 400
    private let hop: Int = 160
    private var hann: [Float]
    private var mel: [[Float]]

    private init() {
        hann = [Float](repeating: 0, count: 400)
        mel = []
        setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))
        hann.withUnsafeMutableBufferPointer { ptr in
            guard let base = ptr.baseAddress else { return }
            vDSP_hann_window(base, vDSP_Length(400), Int32(vDSP_HANN_NORM))
        }
        mel = Self.buildMelBank(fftSize: fftSize)
    }

    deinit {
        if let setup { vDSP_destroy_fftsetup(setup) }
    }

    func makePrint(samples: [Float], sampleRate: Double, minimumFrames: Int) -> SpeakerPrint? {
        guard sampleRate > 1_000, samples.count > frameLength else { return nil }
        lock.lock()
        defer { lock.unlock() }
        guard let setup else { return nil }
        let limited = Self.tail(samples, sampleRate: sampleRate)
        let down = Self.downsample(limited, from: sampleRate, to: 16_000)
        let emphasised = Self.preEmphasis(down)
        let frames = voicedFrames(emphasised, setup: setup)
        guard frames.count >= minimumFrames else { return nil }
        let pitch = Self.pitchTrack(emphasised, sampleRate: 16_000)
        return Self.aggregate(frames, pitch: pitch)
    }

    private func voicedFrames(_ samples: [Float], setup: FFTSetup) -> [[Float]] {
        var frames: [[Float]] = []
        var start: Int = 0
        while start + frameLength <= samples.count {
            let row = mfccFrame(samples, start: start, setup: setup)
            if let row { frames.append(row) }
            start += hop
        }
        return frames
    }

    private func mfccFrame(_ samples: [Float], start: Int, setup: FFTSetup) -> [Float]? {
        var windowed = [Float](repeating: 0, count: fftSize)
        var energy: Float = 0
        var index: Int = 0
        while index < frameLength {
            let sample: Float = samples[start + index]
            let window: Float = sample * hann[index]
            windowed[index] = window
            energy += sample * sample
            index += 1
        }
        let meanEnergy: Float = energy / Float(frameLength)
        if meanEnergy < 0.000_016 { return nil }
        let power = SpeechBandMeter.power(windowed, setup: setup, log2n: log2n)
        var logged = [Double](repeating: 0, count: mel.count)
        var filter: Int = 0
        while filter < mel.count {
            var sum: Float = 0
            let weights = mel[filter]
            let bins: Int = min(weights.count, power.count)
            var bin: Int = 0
            while bin < bins {
                sum += power[bin] * weights[bin]
                bin += 1
            }
            let floor: Double = max(Double(sum), 1.0e-10)
            logged[filter] = log(floor)
            filter += 1
        }
        return Self.cepstrum(logged)
    }

    private static func cepstrum(_ logged: [Double]) -> [Float] {
        var coeffs = [Float]()
        coeffs.reserveCapacity(12)
        let count: Int = logged.count
        var k: Int = 1
        while k <= 12 {
            var sum: Double = 0
            var m: Int = 0
            while m < count {
                let angle: Double = Double.pi * Double(k) * (Double(m) + 0.5) / Double(count)
                sum += logged[m] * cos(angle)
                m += 1
            }
            coeffs.append(Float(sum))
            k += 1
        }
        return coeffs
    }

    private static func aggregate(_ frames: [[Float]], pitch: (mean: Float, spread: Float)) -> SpeakerPrint? {
        let count: Int = frames.count
        guard count > 0 else { return nil }
        var mean = [Float](repeating: 0, count: 12)
        var deltaMean = [Float](repeating: 0, count: 12)
        var index: Int = 0
        while index < count {
            let row = frames[index]
            guard row.count == 12 else { return nil }
            var bin: Int = 0
            while bin < 12 {
                mean[bin] += row[bin]
                bin += 1
            }
            if index > 0 && index + 1 < count {
                let next = frames[index + 1]
                let prev = frames[index - 1]
                var deltaBin: Int = 0
                while deltaBin < 12 {
                    let step: Float = (next[deltaBin] - prev[deltaBin]) * 0.5
                    deltaMean[deltaBin] += step
                    deltaBin += 1
                }
            }
            index += 1
        }
        let denom: Float = Float(count)
        var bin: Int = 0
        while bin < 12 {
            mean[bin] = mean[bin] / denom
            deltaMean[bin] = deltaMean[bin] / denom
            bin += 1
        }
        var variance = [Float](repeating: 0, count: 12)
        index = 0
        while index < count {
            let row = frames[index]
            var varBin: Int = 0
            while varBin < 12 {
                let delta: Float = row[varBin] - mean[varBin]
                variance[varBin] += delta * delta
                varBin += 1
            }
            index += 1
        }
        var std = [Float](repeating: 0, count: 12)
        bin = 0
        while bin < 12 {
            let meanSquare: Float = variance[bin] / denom
            std[bin] = meanSquare.squareRoot()
            bin += 1
        }
        var vector: [Float] = []
        vector.reserveCapacity(SpeakerEmbedding.dimension)
        bin = 0
        while bin < 12 {
            vector.append(mean[bin] * 0.05)
            bin += 1
        }
        bin = 0
        while bin < 12 {
            vector.append(std[bin] * 0.10)
            bin += 1
        }
        bin = 0
        while bin < 12 {
            vector.append(deltaMean[bin] * 0.05)
            bin += 1
        }
        let pitchScale: Float = pitch.mean / 300.0
        let spreadScale: Float = pitch.spread / 120.0
        vector.append(pitchScale)
        vector.append(spreadScale)
        guard vector.count == SpeakerEmbedding.dimension else { return nil }
        normalize(&vector)
        return SpeakerPrint(embedding: vector, pitchHz: pitch.mean)
    }

    private static func normalize(_ vector: inout [Float]) {
        var energy: Float = 0
        for value in vector { energy += value * value }
        let norm: Float = energy.squareRoot()
        if norm < 0.000_001 { return }
        let scale: Float = 1.0 / norm
        var index: Int = 0
        while index < vector.count {
            vector[index] = vector[index] * scale
            index += 1
        }
    }

    private static func tail(_ samples: [Float], sampleRate: Double) -> [Float] {
        let maxCount: Int = Int(sampleRate * 28.0)
        guard maxCount > 0, samples.count > maxCount else { return samples }
        return Array(samples.suffix(maxCount))
    }

    private static func downsample(_ input: [Float], from sourceRate: Double, to targetRate: Double) -> [Float] {
        if abs(sourceRate - targetRate) < 1 { return input }
        let ratio: Double = sourceRate / targetRate
        guard ratio > 0 else { return input }
        let outCount: Int = Int(Double(input.count) / ratio)
        guard outCount > 1 else { return input }
        var output = [Float](repeating: 0, count: outCount)
        var index: Int = 0
        let last: Int = input.count - 1
        while index < outCount {
            let position: Double = Double(index) * ratio
            let left: Int = min(Int(position), last)
            let fraction: Double = position - Double(left)
            let right: Int = min(left + 1, last)
            let sampleA: Float = input[left]
            let sampleB: Float = input[right]
            let mixed: Float = sampleA + (sampleB - sampleA) * Float(fraction)
            output[index] = mixed
            index += 1
        }
        return output
    }

    private static func preEmphasis(_ input: [Float]) -> [Float] {
        guard input.count > 1 else { return input }
        var output = input
        let coefficient: Float = 0.97
        var index: Int = input.count - 1
        while index > 0 {
            let current: Float = input[index]
            let previous: Float = input[index - 1]
            output[index] = current - coefficient * previous
            index -= 1
        }
        return output
    }

    private static func pitchTrack(_ samples: [Float], sampleRate: Float) -> (mean: Float, spread: Float) {
        let window: Int = 800
        guard samples.count >= window else { return (0, 0) }
        let hop: Int = samples.count > 16_000 * 8 ? 1_600 : 480
        var pitches: [Float] = []
        var start: Int = 0
        while start + window <= samples.count && pitches.count < 48 {
            if let hz = pitchAt(samples, start: start, count: window, sampleRate: sampleRate) {
                pitches.append(hz)
            }
            start += hop
        }
        guard pitches.count >= 3 else { return (0, 0) }
        var sum: Float = 0
        for hz in pitches { sum += hz }
        let count: Float = Float(pitches.count)
        let mean: Float = sum / count
        var variance: Float = 0
        for hz in pitches {
            let delta: Float = hz - mean
            variance += delta * delta
        }
        let spread: Float = (variance / count).squareRoot()
        return (mean, spread)
    }

    private static func pitchAt(_ samples: [Float], start: Int, count: Int, sampleRate: Float) -> Float? {
        let minHz: Float = 70
        let maxHz: Float = 400
        let minLag: Int = Int(sampleRate / maxHz)
        let maxLag: Int = min(count - 1, Int(sampleRate / minHz))
        guard maxLag > minLag, minLag > 0 else { return nil }
        var energy: Float = 0
        var index: Int = 0
        while index < count {
            let sample: Float = samples[start + index]
            energy += sample * sample
            index += 1
        }
        if energy < 0.000_1 { return nil }
        var best: Float = 0
        var bestLag: Int = minLag
        var lag: Int = minLag
        while lag <= maxLag {
            var corr: Float = 0
            var cursor: Int = 0
            let limit: Int = count - lag
            while cursor < limit {
                corr += samples[start + cursor] * samples[start + cursor + lag]
                cursor += 1
            }
            let score: Float = corr / energy
            if score > best {
                best = score
                bestLag = lag
            }
            lag += 1
        }
        if best < 0.35 { return nil }
        return sampleRate / Float(bestLag)
    }

    private static func hzToMel(_ hz: Double) -> Double {
        let ratio: Double = hz / 700.0
        return 2595.0 * log10(1.0 + ratio)
    }

    private static func melToHz(_ mel: Double) -> Double {
        let power: Double = mel / 2595.0
        return 700.0 * (pow(10.0, power) - 1.0)
    }

    private static func buildMelBank(fftSize: Int) -> [[Float]] {
        let filters: Int = 26
        let sampleRate: Double = 16_000
        let lowHz: Double = 80
        let highHz: Double = 4_000
        let bins: Int = fftSize / 2
        let lowMel: Double = hzToMel(lowHz)
        let highMel: Double = hzToMel(highHz)
        let step: Double = (highMel - lowMel) / Double(filters + 1)
        var points = [Double](repeating: 0, count: filters + 2)
        var point: Int = 0
        while point < points.count {
            let mel: Double = lowMel + step * Double(point)
            let hz: Double = melToHz(mel)
            points[point] = Double(fftSize) * hz / sampleRate
            point += 1
        }
        var bank = [[Float]](repeating: [Float](repeating: 0, count: bins), count: filters)
        var filter: Int = 0
        while filter < filters {
            let left: Double = points[filter]
            let center: Double = points[filter + 1]
            let right: Double = points[filter + 2]
            var bin: Int = 0
            while bin < bins {
                let position: Double = Double(bin)
                var weight: Double = 0
                if position >= left && position <= center && center > left {
                    weight = (position - left) / (center - left)
                } else if position > center && position <= right && right > center {
                    weight = (right - position) / (right - center)
                }
                bank[filter][bin] = Float(weight)
                bin += 1
            }
            filter += 1
        }
        return bank
    }
}
