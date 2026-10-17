import AVFoundation
import Foundation

/// A short two-note tone generated in memory. Nothing is stored in the repo.
enum BootChime {
    private static var player: AVAudioPlayer?

    static func play() {
        guard AppSettings.shared.bootChime, player == nil || player?.isPlaying == false else { return }
        guard let url = writeTone() else { return }
        do {
            let next = try AVAudioPlayer(contentsOf: url)
            next.volume = 0.28
            next.prepareToPlay()
            next.play()
            player = next
        } catch {
            player = nil
        }
    }

    private static func writeTone() -> URL? {
        let sampleRate = 22050
        let duration = 0.42
        let count = Int(Double(sampleRate) * duration)
        var samples = [Int16](repeating: 0, count: count)
        for index in 0..<count {
            let time = Double(index) / Double(sampleRate)
            let envelope = exp(-time * 6.5)
            let first = sin(2 * Double.pi * 523.25 * time)
            let second = time > 0.16 ? sin(2 * Double.pi * 659.25 * (time - 0.16)) : 0
            let mixed = (first * 0.55 + second * 0.45) * envelope * 0.35
            samples[index] = Int16(max(-1, min(1, mixed)) * 32767)
        }
        var data = Data()
        for byte in wavHeader(sampleRate: sampleRate, samples: count) {
            data.append(byte)
        }
        samples.withUnsafeBytes { raw in
            for byte in raw {
                data.append(byte)
            }
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("jarvis-boot.wav")
        do {
            try data.write(to: url, options: .atomic)
            return url
        } catch {
            return nil
        }
    }

    private static func wavHeader(sampleRate: Int, samples: Int) -> [UInt8] {
        let dataBytes = samples * 2
        let chunk = 36 + dataBytes
        var bytes: [UInt8] = []
        func ascii(_ text: String) { bytes.append(contentsOf: text.utf8) }
        func u32(_ value: Int) {
            bytes.append(UInt8(value & 0xff))
            bytes.append(UInt8((value >> 8) & 0xff))
            bytes.append(UInt8((value >> 16) & 0xff))
            bytes.append(UInt8((value >> 24) & 0xff))
        }
        func u16(_ value: Int) {
            bytes.append(UInt8(value & 0xff))
            bytes.append(UInt8((value >> 8) & 0xff))
        }
        ascii("RIFF")
        u32(chunk)
        ascii("WAVE")
        ascii("fmt ")
        u32(16)
        u16(1)
        u16(1)
        u32(sampleRate)
        u32(sampleRate * 2)
        u16(2)
        u16(16)
        ascii("data")
        u32(dataBytes)
        return bytes
    }
}
