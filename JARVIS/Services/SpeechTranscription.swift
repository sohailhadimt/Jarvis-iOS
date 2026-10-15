import Foundation
import Speech

/// Groq's OpenAI-compatible Whisper endpoint. Used when a Groq API key is saved.
enum GroqTranscription {
    static let endpoint = URL(string: "https://api.groq.com/openai/v1/audio/transcriptions")!
    static let model = "whisper-large-v3-turbo"

    static func transcribe(fileURL: URL, apiKey: String) async throws -> String {
        let boundary = "jarvis-\(UUID().uuidString)"
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 45
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = try multipart(fileURL: fileURL, boundary: boundary)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw LLMError.http(-1, error.localizedDescription, provider: "Groq transcription")
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw LLMError.http(status, String(data: data, encoding: .utf8) ?? "", provider: "Groq transcription")
        }
        struct Payload: Decodable { let text: String? }
        guard let text = (try? JSONDecoder().decode(Payload.self, from: data))?.text else {
            throw LLMError.http(-1, "Groq transcription returned no text.", provider: "Groq transcription")
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func multipart(fileURL: URL, boundary: String) throws -> Data {
        let filename = fileURL.lastPathComponent
        let mime = filename.lowercased().hasSuffix(".wav") ? "audio/wav" : "audio/m4a"
        let file = try Data(contentsOf: fileURL)
        var body = Data()
        func add(_ string: String) { body.append(Data(string.utf8)) }
        add("--\(boundary)\r\n")
        add("Content-Disposition: form-data; name=\"model\"\r\n\r\n")
        add("\(model)\r\n")
        add("--\(boundary)\r\n")
        add("Content-Disposition: form-data; name=\"file\"; filename=\"\(filename)\"\r\n")
        add("Content-Type: \(mime)\r\n\r\n")
        body.append(file)
        add("\r\n")
        add("--\(boundary)--\r\n")
        return body
    }
}

/// On-device Apple Speech for a recorded file. Used when Groq Whisper is unavailable or fails.
enum AppleFileTranscriber {
    static func transcribe(_ url: URL) async throws -> String {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<String, any Error>) in
            guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-GB")) ?? SFSpeechRecognizer(),
                  recognizer.isAvailable else {
                cont.resume(throwing: ListenerError.unavailable)
                return
            }
            let request = SFSpeechURLRecognitionRequest(url: url)
            request.shouldReportPartialResults = false
            if recognizer.supportsOnDeviceRecognition {
                request.requiresOnDeviceRecognition = true
            }
            let box = SpeechResumeBox(cont)
            let task = recognizer.recognitionTask(with: request,
                                                  resultHandler: AudioTaps.finalRecognitionHandler { text, error in
                if let text {
                    box.finish(.success(text))
                } else if let error {
                    box.finish(.failure(error))
                }
            })
            box.keep(task: task, recognizer: recognizer)
            Task {
                try? await Task.sleep(for: .seconds(40))
                box.finish(.failure(ListenerError.timedOut))
            }
        }
    }
}

struct SpeechTranscriptionError: LocalizedError, Sendable {
    let groq: String
    let apple: String
    var errorDescription: String? {
        "Groq speech-to-text failed (\(groq)). On-device speech also failed (\(apple))."
    }
}

/// Holds the speech task so it is not released early, and resumes the continuation once.
private final class SpeechResumeBox: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<String, any Error>?
    private var task: SFSpeechRecognitionTask?
    private var recognizer: SFSpeechRecognizer?
    private var finished = false

    init(_ continuation: CheckedContinuation<String, any Error>) {
        self.continuation = continuation
    }

    func keep(task: SFSpeechRecognitionTask, recognizer: SFSpeechRecognizer) {
        lock.lock()
        self.task = task
        self.recognizer = recognizer
        lock.unlock()
    }

    func finish(_ result: Result<String, any Error>) {
        lock.lock()
        guard !finished else {
            lock.unlock()
            return
        }
        finished = true
        let task = self.task
        self.task = nil
        recognizer = nil
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        if case .failure = result {
            task?.cancel()
        }
        switch result {
        case .success(let text):
            continuation?.resume(returning: text)
        case .failure(let error):
            continuation?.resume(throwing: error)
        }
    }
}
