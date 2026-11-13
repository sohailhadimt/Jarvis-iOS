import AVFoundation
import Foundation

/// Spoken lines for the start-up sequence. Original wording. The George voice is bundled when a
/// build has an ElevenLabs key, otherwise the first successful fetch is cached and later opens
/// play the file. A launch never waits on the network.
enum StartupLine: String, CaseIterable, Sendable {
    case morning
    case afternoon
    case evening
    case preferences
    case operational

    var spoken: String {
        switch self {
        case .morning: "Good morning, Sir. J.A.R.V.I.S. online."
        case .afternoon: "Good afternoon, Sir. J.A.R.V.I.S. online."
        case .evening: "Good evening, Sir. J.A.R.V.I.S. online."
        case .preferences: "Loading your preferences."
        case .operational: "All systems are operational."
        }
    }

    var bundleName: String { "startup-voice-\(rawValue)" }

    static func greeting(at date: Date = .now) -> StartupLine {
        let hour = Calendar.current.component(.hour, from: date)
        if hour < 12 { return .morning }
        if hour < 17 { return .afternoon }
        return .evening
    }
}

/// Bundled synth effects. Playback uses the ambient category so the silent switch mutes them.
@MainActor
enum StartupAudio {
    static func url(_ name: String) -> URL? {
        Bundle.main.url(forResource: name, withExtension: "wav", subdirectory: "Startup")
            ?? Bundle.main.url(forResource: name, withExtension: "wav")
    }
}

@MainActor
final class StartupPlayback {
    private var players: [AVAudioPlayer] = []
    private var armed = false

    /// Ambient mixes with other audio and stays silent when the ringer switch is off.
    /// A live voice session owns the audio session, so the sequence stays quiet rather than stealing it.
    func arm() -> Bool {
        if armed { return true }
        let session = AVAudioSession.sharedInstance()
        if session.category == .playAndRecord { return false }
        do {
            if session.category != .ambient {
                try session.setCategory(.ambient, mode: .default, options: [.mixWithOthers])
            }
            try session.setActive(true)
            armed = true
            return true
        } catch {
            return false
        }
    }

    func play(url: URL?, volume: Float) {
        guard armed, let url else { return }
        guard let player = try? AVAudioPlayer(contentsOf: url) else { return }
        player.volume = volume
        player.prepareToPlay()
        player.play()
        players.append(player)
    }

    func stop() {
        for player in players { player.stop() }
        players.removeAll()
    }
}

/// George-voice files. Missing lines are fetched at most once per process, then stored as WAV.
@MainActor
enum StartupVoiceCache {
    private static var attempted = false

    static func url(_ line: StartupLine, voiceID: String) -> URL? {
        let cached = cacheURL(line, voiceID: voiceID)
        if FileManager.default.fileExists(atPath: cached.path) { return cached }
        guard voiceID == ElevenLabsClient.defaultVoiceID else { return nil }
        return Bundle.main.url(forResource: line.bundleName, withExtension: "wav", subdirectory: "Startup")
            ?? Bundle.main.url(forResource: line.bundleName, withExtension: "wav")
            ?? Bundle.main.url(forResource: line.bundleName, withExtension: "mp3", subdirectory: "Startup")
            ?? Bundle.main.url(forResource: line.bundleName, withExtension: "mp3")
    }

    static func warmOnce(voiceID: String, stability: Double, similarity: Double) {
        guard !attempted else { return }
        let missing = StartupLine.allCases.compactMap { line -> (StartupLine, URL)? in
            guard url(line, voiceID: voiceID) == nil else { return nil }
            return (line, cacheURL(line, voiceID: voiceID))
        }
        guard !missing.isEmpty else { return }
        guard let apiKey = KeychainStore.get(.elevenLabs) else { return }
        attempted = true
        let directory = cacheDirectory()
        Task.detached(priority: .utility) {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            for (line, destination) in missing {
                do {
                    let pcm = try await ElevenLabsClient.collectSpeech(
                        text: line.spoken,
                        voiceID: voiceID,
                        apiKey: apiKey,
                        stability: stability,
                        similarity: similarity
                    )
                    guard pcm.count > 200 else { continue }
                    let wave = Self.wav(fromPCM: pcm, sampleRate: Int(ElevenLabsClient.pcmSampleRate))
                    try wave.write(to: destination, options: .atomic)
                } catch {
                    return
                }
            }
        }
    }

    private static func cacheDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("StartupVoice", isDirectory: true)
    }

    private static func cacheURL(_ line: StartupLine, voiceID: String) -> URL {
        let safe = voiceID.filter { $0.isLetter || $0.isNumber }
        return cacheDirectory().appendingPathComponent("\(line.bundleName)-\(safe).wav")
    }

    /// 16-bit little-endian mono PCM, the format ElevenLabs returns for the streaming voice.
    nonisolated static func wav(fromPCM pcm: Data, sampleRate: Int) -> Data {
        var payload = pcm
        if payload.count % 2 == 1 { payload.removeLast() }
        let dataBytes = payload.count
        let chunk = 36 + dataBytes
        var bytes = Data()
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
        bytes.append(payload)
        return bytes
    }
}
