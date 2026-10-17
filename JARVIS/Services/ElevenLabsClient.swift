import Foundation

struct ElevenVoice: Decodable, Identifiable, Hashable, Sendable {
    let voiceID: String
    let name: String
    let previewURL: String?
    let category: String?
    var id: String { voiceID }

    enum CodingKeys: String, CodingKey {
        case voiceID = "voice_id", name, previewURL = "preview_url", category
    }
}

enum ElevenLabsError: LocalizedError {
    case http(Int, String)
    var errorDescription: String? {
        switch self { case .http(let c, let b): "ElevenLabs error \(c): \(b.prefix(200))" }
    }
}

enum ElevenLabsClient {
    static let defaultVoiceID = "JBFqnCBsd6RMkjVDRZzb" // "George" premade British voice
    static let modelID = "eleven_turbo_v2_5"
    static let flashModelID = "eleven_flash_v2_5"
    /// Raw 16-bit little-endian mono PCM at 24 kHz, so we can play it while it streams.
    static let pcmSampleRate: Double = 24_000

    private struct VoicesResponse: Decodable { let voices: [ElevenVoice] }

    static func voices(apiKey: String) async throws -> [ElevenVoice] {
        var req = URLRequest(url: URL(string: "https://api.elevenlabs.io/v1/voices")!)
        req.setValue(apiKey, forHTTPHeaderField: "xi-api-key")
        let (data, resp) = try await HTTPConnections.session.data(for: req)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw ElevenLabsError.http(status, String(data: data, encoding: .utf8) ?? "") }
        return try JSONDecoder().decode(VoicesResponse.self, from: data).voices
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private struct TTSBody: Encodable {
        struct Settings: Encodable {
            let stability: Double
            let similarity_boost: Double
        }
        let text: String
        let model_id: String
        let voice_settings: Settings
    }

    static func streamSpeech(text: String, voiceID: String, apiKey: String,
                             stability: Double, similarity: Double) async throws -> URLSession.AsyncBytes {
        do {
            return try await streamSpeech(text: text, voiceID: voiceID, apiKey: apiKey,
                                          stability: stability, similarity: similarity, model: flashModelID)
        } catch let error as ElevenLabsError {
            if case .http(let code, _) = error, code == 400 || code == 404 || code == 422 {
                return try await streamSpeech(text: text, voiceID: voiceID, apiKey: apiKey,
                                              stability: stability, similarity: similarity, model: modelID)
            }
            throw error
        }
    }

    private static func streamSpeech(text: String, voiceID: String, apiKey: String,
                                     stability: Double, similarity: Double, model: String) async throws -> URLSession.AsyncBytes {
        var comps = URLComponents(string: "https://api.elevenlabs.io/v1/text-to-speech/\(voiceID)/stream")!
        comps.queryItems = [
            URLQueryItem(name: "output_format", value: "pcm_24000"),
            URLQueryItem(name: "optimize_streaming_latency", value: "4"),
        ]
        var req = URLRequest(url: comps.url!)
        req.httpMethod = "POST"
        req.setValue(apiKey, forHTTPHeaderField: "xi-api-key")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONEncoder().encode(TTSBody(
            text: text, model_id: model,
            voice_settings: .init(stability: stability, similarity_boost: similarity)))

        let (bytes, resp) = try await HTTPConnections.session.bytes(for: req)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            var body = Data()
            for try await b in bytes {
                body.append(b)
                if body.count > 2_000 { break }
            }
            throw ElevenLabsError.http(status, String(data: body, encoding: .utf8) ?? "")
        }
        return bytes
    }

    /// Downloads one utterance so the next sentence can start while the current one plays.
    static func collectSpeech(text: String, voiceID: String, apiKey: String,
                              stability: Double, similarity: Double) async throws -> Data {
        let bytes = try await streamSpeech(text: text, voiceID: voiceID, apiKey: apiKey,
                                           stability: stability, similarity: similarity)
        var data = Data()
        data.reserveCapacity(24_000)
        for try await byte in bytes {
            try Task.checkCancellation()
            data.append(byte)
        }
        return data
    }
}
