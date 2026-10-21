import Foundation

enum LiveOpenResult: Equatable {
    case ready
    case textRejected
    case failed(String)
}

/// One Gemini Live socket. The phone streams 16 kHz PCM and speaks George from the text, never the model audio.
final class GeminiLiveSession: @unchecked Sendable {
    var onEffect: (@Sendable (LiveEffect) -> Void)?

    private let lock = NSLock()
    private var socket: URLSessionWebSocketTask?
    private var session: URLSession?
    private var setupWait: CheckedContinuation<SetupResult, Never>?
    private var setupReady = false
    private var stopped = false
    private var generation = 0
    private var staged = Data()
    private var reducer = LiveTurnReducer()
    private var sendFailures = 0
    private(set) var modality: LiveModality = .text

    /// 100 ms of 16 kHz 16-bit mono. One socket message per slice, still a continuous stream for server VAD.
    private let batchBytes = 3_200

    func stop() {
        lock.lock()
        generation += 1
        stopped = true
        setupReady = false
        staged.removeAll()
        sendFailures = 0
        let task = socket
        let urlSession = session
        let wait = setupWait
        setupWait = nil
        socket = nil
        session = nil
        lock.unlock()
        wait?.resume(returning: .failed("stopped"))
        task?.cancel(with: .goingAway, reason: nil)
        urlSession?.invalidateAndCancel()
    }

    /// TEXT first. A modality rejection does not reuse the token; the caller mints another for audio transcription.
    func open(url: URL, instruction: String, tools: [JSONValue], modality: LiveModality) async -> LiveOpenResult {
        stop()
        lock.lock()
        let ticket = generation
        stopped = false
        reducer = LiveTurnReducer()
        self.modality = modality
        lock.unlock()
        let socketSession = URLSession(configuration: .default)
        let task = socketSession.webSocketTask(with: url)
        lock.lock()
        session = socketSession
        socket = task
        lock.unlock()
        task.resume()
        let payload = LiveWire.setup(instruction: instruction, declarations: tools, modality: modality)
        let result = await withCheckedContinuation { (continuation: CheckedContinuation<SetupResult, Never>) in
            self.lock.lock()
            self.setupWait = continuation
            self.lock.unlock()
            self.receive(task)
            task.send(.string(payload)) { error in
                if error != nil { self.finishSetup(.failed("send")) }
            }
            Task {
                try? await Task.sleep(nanoseconds: 8_000_000_000)
                self.finishSetup(.failed("timeout"), generation: ticket)
            }
        }
        switch result {
        case .ready:
            lock.lock()
            setupReady = true
            let task = socket
            let queued = drainLocked()
            lock.unlock()
            for chunk in queued {
                sendRaw(task, chunk)
            }
            return .ready
        case .textRejected:
            stop()
            return .textRejected
        case .failed(let reason):
            stop()
            return .failed(reason)
        }
    }

    func sendAudio(_ pcm: Data) {
        guard !pcm.isEmpty else { return }
        lock.lock()
        let halted = stopped
        let ready = setupReady
        let task = socket
        if halted {
            lock.unlock()
            return
        }
        staged.append(pcm)
        if !ready {
            let cap = batchBytes * 50
            if staged.count > cap { staged.removeFirst(staged.count - cap) }
            lock.unlock()
            return
        }
        let queued = drainLocked()
        lock.unlock()
        for chunk in queued {
            sendRaw(task, chunk)
        }
    }

    func sendToolResult(id: String, name: String, result: String) {
        lock.lock()
        let task = socket
        let ready = setupReady
        lock.unlock()
        guard ready, let task else { return }
        task.send(.string(LiveWire.toolResult(id: id, name: name, result: result))) { _ in }
    }

    private func drainLocked() -> [Data] {
        var queued: [Data] = []
        while staged.count >= batchBytes {
            queued.append(Data(staged.prefix(batchBytes)))
            staged.removeFirst(batchBytes)
        }
        return queued
    }

    private func sendRaw(_ task: URLSessionWebSocketTask?, _ pcm: Data) {
        guard let task else { return }
        task.send(.string(LiveWire.audio(pcm))) { [weak self] error in
            guard let self, let error else { return }
            self.noteSendFailure(error.localizedDescription)
        }
    }

    private func noteSendFailure(_ message: String) {
        lock.lock()
        sendFailures += 1
        let count = sendFailures
        lock.unlock()
        if count == 1 {
            VoiceDebugLog.note("live-error", "audio send \(message)")
        }
        if count == 8 {
            emit(.failed("audio send"))
        }
    }

    private enum SetupResult {
        case ready
        case textRejected
        case failed(String)
    }

    private func finishSetup(_ result: SetupResult, generation expected: Int? = nil) {
        lock.lock()
        if let expected, expected != generation {
            lock.unlock()
            return
        }
        let wait = setupWait
        setupWait = nil
        lock.unlock()
        wait?.resume(returning: result)
    }

    private func receive(_ task: URLSessionWebSocketTask) {
        task.receive { [weak self] result in
            guard let self else { return }
            self.lock.lock()
            let current = self.socket
            let halted = self.stopped
            self.lock.unlock()
            guard current === task, !halted else { return }
            switch result {
            case .failure(let error):
                let detail = VoiceDebugLog.safe("socket \(error.localizedDescription)")
                self.finishSetup(.failed(detail.isEmpty ? "socket" : detail))
                VoiceDebugLog.note("live-error", detail.isEmpty ? "socket" : detail)
                self.emit(.failed("socket"))
            case .success(let message):
                let text: String
                switch message {
                case .string(let value): text = value
                case .data(let data): text = String(decoding: data, as: UTF8.self)
                @unknown default: text = ""
                }
                if let data = text.data(using: .utf8) {
                    self.consume(LiveMessages.parse(data))
                }
                self.receive(task)
            }
        }
    }

    private func consume(_ events: [LiveInbound]) {
        for event in events {
            lock.lock()
            let waiting = setupWait != nil
            lock.unlock()
            if case .error(let message) = event, waiting {
                finishSetup(LiveWire.rejectsText(message) ? .textRejected : .failed(message))
                return
            }
            if case .setupComplete = event {
                finishSetup(.ready)
            }
            lock.lock()
            let effects = reducer.apply(event)
            let stillWaiting = setupWait != nil
            lock.unlock()
            if stillWaiting { continue }
            for effect in effects where effect != .ready {
                emit(effect)
            }
        }
    }

    private func emit(_ effect: LiveEffect) {
        onEffect?(effect)
    }
}
