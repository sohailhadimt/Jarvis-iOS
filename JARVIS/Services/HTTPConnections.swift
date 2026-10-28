import Foundation

/// One URLSession for the model and voice hosts so TLS stays warm between turns.
enum HTTPConnections {
    static let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.httpMaximumConnectionsPerHost = 6
        config.waitsForConnectivity = false
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 120
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.urlCache = nil
        return URLSession(configuration: config)
    }()

    /// Opens TLS to Gemini, Groq and ElevenLabs before the first spoken turn.
    static func prewarm() {
        let hosts = [
            "https://jarvis-backend.jarvis-hadi.workers.dev/health",
            "https://generativelanguage.googleapis.com/",
            "https://api.groq.com/",
            "https://api.elevenlabs.io/",
        ]
        Task {
            for raw in hosts {
                await warm(raw)
            }
        }
    }

    private static func warm(_ raw: String) async {
        guard let url = URL(string: raw) else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        request.timeoutInterval = 8
        _ = try? await session.data(for: request)
    }
}
