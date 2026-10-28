import Foundation

enum HQError: LocalizedError {
    case needsToken
    case badURL
    case http(Int, String)

    var errorDescription: String? {
        switch self {
        case .needsToken:
            "Add the JARVIS app token in Settings. It stays in the Keychain."
        case .badURL:
            "The HQ backend URL is not a valid http or https address."
        case .http(let code, let message):
            code < 0 ? "HQ could not be reached. \(message)" : "HQ error \(code): \(message)"
        }
    }
}

enum HQSettings {
    static let defaultBase = "https://jarvis-backend.jarvis-hadi.workers.dev"

    static var baseURLString: String {
        get {
            let stored = UserDefaults.standard.string(forKey: "asghq.baseURL")?.trimmingCharacters(in: .whitespacesAndNewlines)
            return (stored?.isEmpty == false) ? stored! : defaultBase
        }
        set {
            UserDefaults.standard.set(newValue.trimmingCharacters(in: .whitespacesAndNewlines), forKey: "asghq.baseURL")
        }
    }

    static func baseURL() -> URL? {
        var text = baseURLString
        while text.hasSuffix("/") { text.removeLast() }
        guard let url = URL(string: text),
              let scheme = url.scheme?.lowercased(),
              scheme == "https" || scheme == "http",
              let host = url.host, !host.isEmpty else { return nil }
        return url
    }
}

enum HQClient {
    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }()

    static func progress() async throws -> HQProgress {
        try await send(method: "GET", path: "/hq/progress", body: nil as String?, timeout: 20)
    }

    static func talk(bot: String, text: String) async throws -> TalkReply {
        try await send(method: "POST", path: "/hq/talk", body: TalkBody(bot: bot, text: text), timeout: 45)
    }

    static func saveState(name: String, look: Outfit, looks: [Outfit], furniture: [FurniturePlacement]) async throws {
        let body = StateBody(playerName: name, activeLook: look, looks: looks, furniture: furniture)
        let _: StateEnvelope = try await send(method: "POST", path: "/hq/state", body: body, timeout: 20)
    }

    private static func send<Response: Decodable, Body: Encodable>(
        method: String,
        path: String,
        body: Body?,
        timeout: TimeInterval
    ) async throws -> Response {
        guard let root = HQSettings.baseURL() else { throw HQError.badURL }
        guard let token = KeychainStore.token() else { throw HQError.needsToken }
        guard let url = URL(string: root.absoluteString + path) else { throw HQError.badURL }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try encoder.encode(body)
        }
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw HQError.http(-1, error.localizedDescription)
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard (200..<300).contains(status) else {
            if let parsed = try? decoder.decode(ErrorEnvelope.self, from: data) {
                throw HQError.http(status, parsed.error.message)
            }
            throw HQError.http(status, "The HQ request failed.")
        }
        do {
            return try decoder.decode(Response.self, from: data)
        } catch {
            throw HQError.http(status, "HQ returned a response this app could not read.")
        }
    }
}

private struct TalkBody: Encodable {
    var bot: String
    var text: String
}

struct TalkReply: Decodable, Equatable {
    var bot: String
    var botName: String
    var reply: String
    var status: String
    var taskId: String?
    var stored: Bool
    var externalActionTaken: Bool
}

private struct StateBody: Encodable {
    var playerName: String
    var activeLook: Outfit
    var looks: [Outfit]
    var furniture: [FurniturePlacement]
}

private struct StateEnvelope: Decodable {
    var externalActions: Bool?
}

private struct ErrorEnvelope: Decodable {
    struct Inner: Decodable {
        var message: String
    }
    var error: Inner
}
