import Foundation
import Photos
import UIKit

struct MadeImage: Sendable {
    var jpeg: Data?
}

/// Free pictures. Gemini's image model when a key is saved, otherwise Pollinations.
enum ImageStudio {
    static func wants(_ text: String) -> Bool {
        let lower = text.lowercased()
        let needles = [
            "draw ", "draw me", "sketch ", "generate an image", "generate a picture",
            "make a picture", "make an image", "make me a picture", "paint ",
            "illustrate", "edit this photo", "edit the photo", "change this photo", "change the photo",
        ]
        return needles.contains { lower.contains($0) }
    }

    static func make(prompt: String, sourceJPEG: Data?) async -> MadeImage {
        if let key = KeychainStore.get(.gemini), !key.isEmpty {
            if let jpeg = await gemini(prompt: prompt, sourceJPEG: sourceJPEG, apiKey: key) {
                return MadeImage(jpeg: jpeg)
            }
        }
        if sourceJPEG != nil {
            return MadeImage(jpeg: nil)
        }
        let jpeg = await pollinations(prompt: prompt)
        return MadeImage(jpeg: jpeg)
    }

    private static func gemini(prompt: String, sourceJPEG: Data?, apiKey: String) async -> Data? {
        let model = "gemini-2.5-flash-image"
        let raw = "https://generativelanguage.googleapis.com/v1beta/models/\(model):generateContent"
        guard let url = URL(string: raw) else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 60
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        request.httpBody = body(prompt: prompt, sourceJPEG: sourceJPEG)
        do {
            let (data, response) = try await HTTPConnections.session.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard (200..<300).contains(status) else { return nil }
            return imageData(from: data)
        } catch {
            return nil
        }
    }

    private static func body(prompt: String, sourceJPEG: Data?) -> Data? {
        var parts: [[String: Any]] = []
        if let sourceJPEG {
            parts.append([
                "inline_data": [
                    "mime_type": "image/jpeg",
                    "data": sourceJPEG.base64EncodedString(),
                ],
            ])
        }
        parts.append(["text": prompt])
        let payload: [String: Any] = [
            "contents": [["role": "user", "parts": parts]],
            "generationConfig": ["responseModalities": ["TEXT", "IMAGE"]],
        ]
        return try? JSONSerialization.data(withJSONObject: payload)
    }

    private static func imageData(from data: Data) -> Data? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let candidates = root["candidates"] as? [Any],
              let first = candidates.first as? [String: Any],
              let content = first["content"] as? [String: Any],
              let parts = content["parts"] as? [Any] else { return nil }
        for part in parts {
            guard let dict = part as? [String: Any] else { continue }
            let inline = (dict["inlineData"] as? [String: Any]) ?? (dict["inline_data"] as? [String: Any])
            guard let inline, let encoded = inline["data"] as? String else { continue }
            if let jpeg = Data(base64Encoded: encoded), !jpeg.isEmpty { return jpeg }
        }
        return nil
    }

    private static func pollinations(prompt: String) async -> Data? {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let clipped = trimmed.count > 300 ? String(trimmed.prefix(300)) : trimmed
        let allowed = CharacterSet.urlPathAllowed.subtracting(CharacterSet(charactersIn: "?"))
        let encoded = clipped.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
        guard !encoded.isEmpty else { return nil }
        var components = URLComponents()
        components.scheme = "https"
        components.host = "image.pollinations.ai"
        components.percentEncodedPath = "/prompt/" + encoded
        components.queryItems = [
            URLQueryItem(name: "width", value: "768"),
            URLQueryItem(name: "height", value: "768"),
            URLQueryItem(name: "nologo", value: "true"),
        ]
        guard let url = components.url else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 60
        request.setValue("JARVIS/1.0", forHTTPHeaderField: "User-Agent")
        do {
            let (data, response) = try await HTTPConnections.session.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard (200..<300).contains(status), data.count > 32 else { return nil }
            return data
        } catch {
            return nil
        }
    }
}

enum PhotoSaver {
    static func add(_ data: Data) async -> Bool {
        let allowed = await authorize()
        guard allowed else { return false }
        return await withCheckedContinuation { continuation in
            PHPhotoLibrary.shared().performChanges({
                let request = PHAssetCreationRequest.forAsset()
                request.addResource(with: .photo, data: data, options: nil)
            }, completionHandler: { success, _ in
                continuation.resume(returning: success)
            })
        }
    }

    private static func authorize() async -> Bool {
        let current = PHPhotoLibrary.authorizationStatus(for: .addOnly)
        if current == .authorized || current == .limited { return true }
        if current == .denied || current == .restricted { return false }
        return await withCheckedContinuation { continuation in
            PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
                let granted = status == .authorized || status == .limited
                continuation.resume(returning: granted)
            }
        }
    }
}
