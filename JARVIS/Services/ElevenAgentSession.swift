import Foundation

/// What the ElevenLabs Agents socket tells the engine.
enum AgentEvent: Equatable {
    case userTranscript(String)
    case agentText(String)
    case audio(Data)
    case interruption
    case tool(id: String, name: String, arguments: String)
    case failed(String)
    case closed
}

/// One ElevenLabs Agents conversation over a signed WebSocket URL (public Agents WebSocket protocol).
/// The phone streams 16 kHz PCM up, receives 24 kHz PCM of George down, and tools run on the phone.
/// ElevenLabs does the turn-taking and interruption; the phone only plays what arrives and stops on `interruption`.
final class ElevenAgentSession: @unchecked Sendable {
    var onEvent: (@Sendable (AgentEvent) -> Void)?

    private let lock = NSLock()
    private var socket: URLSessionWebSocketTask?
    private var session: URLSession?
    private var ready = false
    private var stopped = false
    private var generation = 0
    private var openWait: CheckedContinuation<Bool, Never>?
    private var staged: [String] = []
    private var interruptFloor = -1
    private(set) var conversationID = ""
    private(set) var startedAt: Date?

    /// Bytes of 16-bit mono 16 kHz audio the phone may buffer while the socket is still opening (about 3 s).
    private let stageLimit = 60

    func open(url: URL, prompt: String, firstMessage: String) async -> Bool {
        stop()
        lock.lock()
        let ticket = generation
        stopped = false
        ready = false
        staged.removeAll()
        lock.unlock()
        let urlSession = URLSession(configuration: .default)
        let task = urlSession.webSocketTask(with: url)
        lock.lock()
        session = urlSession
        socket = task
        lock.unlock()
        task.resume()
        let initiation: [String: Any] = [
            "type": "conversation_initiation_client_data",
            "conversation_config_override": [
                "agent": ["prompt": ["prompt": prompt], "first_message": firstMessage, "language": "en"],
            ],
            "source_info": ["source": "jarvis-ios", "version": "1"],
        ]
        let opened = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            lock.lock()
            openWait = continuation
            lock.unlock()
            receive(task)
            send(task, initiation) { [weak self] error in
                if error != nil { self?.finishOpen(false, generation: ticket) }
            }
            Task {
                try? await Task.sleep(nanoseconds: 8_000_000_000)
                self.finishOpen(false, generation: ticket)
            }
        }
        if !opened { stop() }
        return opened
    }

    func stop() {
        lock.lock()
        generation += 1
        stopped = true
        ready = false
        staged.removeAll()
        let task = socket
        let urlSession = session
        let wait = openWait
        openWait = nil
        socket = nil
        session = nil
        lock.unlock()
        wait?.resume(returning: false)
        task?.cancel(with: .goingAway, reason: nil)
        urlSession?.invalidateAndCancel()
    }

    /// Seconds since the agent confirmed the conversation. Zero if it never started.
    var elapsedSeconds: Int {
        guard let startedAt else { return 0 }
        return max(0, Int(Date().timeIntervalSince(startedAt).rounded()))
    }

    func sendAudio(_ pcm: Data) {
        guard !pcm.isEmpty else { return }
        let message = "{\"user_audio_chunk\":\"\(pcm.base64EncodedString())\"}"
        lock.lock()
        if stopped { lock.unlock(); return }
        if !ready {
            staged.append(message)
            if staged.count > stageLimit { staged.removeFirst(staged.count - stageLimit) }
            lock.unlock()
            return
        }
        let task = socket
        lock.unlock()
        task?.send(.string(message)) { [weak self] error in
            if error != nil { self?.emit(.failed("audio send")) }
        }
    }

    func sendToolResult(id: String, result: String, isError: Bool = false) {
        lock.lock()
        let task = socket
        lock.unlock()
        guard let task else { return }
        send(task, ["type": "client_tool_result", "tool_call_id": id, "result": result, "is_error": isError]) { _ in }
    }

    /// Background context the agent can use on its next turn without speaking it.
    func sendContext(_ text: String, id: String) {
        lock.lock()
        let task = socket
        lock.unlock()
        guard let task else { return }
        send(task, ["type": "contextual_update", "text": text, "context_id": id]) { _ in }
    }

    private func send(_ task: URLSessionWebSocketTask, _ object: [String: Any], completion: @escaping @Sendable (Error?) -> Void) {
        guard let data = try? JSONSerialization.data(withJSONObject: object),
              let text = String(data: data, encoding: .utf8) else {
            completion(nil)
            return
        }
        task.send(.string(text), completionHandler: completion)
    }

    private func finishOpen(_ ok: Bool, generation expected: Int? = nil) {
        lock.lock()
        if let expected, expected != generation { lock.unlock(); return }
        let wait = openWait
        openWait = nil
        var queued: [String] = []
        let task = socket
        if ok {
            ready = true
            startedAt = Date()
            queued = staged
            staged.removeAll()
        }
        lock.unlock()
        wait?.resume(returning: ok)
        if ok, let task {
            for message in queued { task.send(.string(message)) { _ in } }
        }
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
            case .failure:
                self.finishOpen(false)
                self.emit(.closed)
            case .success(let message):
                let data: Data?
                switch message {
                case .string(let text): data = text.data(using: .utf8)
                case .data(let raw): data = raw
                @unknown default: data = nil
                }
                if let data { self.consume(data, task: task) }
                self.receive(task)
            }
        }
    }

    private func consume(_ data: Data, task: URLSessionWebSocketTask) {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = object["type"] as? String else { return }
        switch type {
        case "conversation_initiation_metadata":
            if let meta = object["conversation_initiation_metadata_event"] as? [String: Any] {
                conversationID = meta["conversation_id"] as? String ?? ""
                let format = meta["agent_output_audio_format"] as? String ?? ""
                if format != "pcm_24000" {
                    VoiceDebugLog.note("agent-format", VoiceDebugLog.safe(format))
                }
            }
            finishOpen(true)
        case "ping":
            let event = (object["ping_event"] as? [String: Any])?["event_id"] ?? 0
            send(task, ["type": "pong", "event_id": event]) { _ in }
        case "audio":
            if let event = object["audio_event"] as? [String: Any],
               !staleAudio(event["event_id"]),
               let encoded = event["audio_base_64"] as? String,
               let pcm = Data(base64Encoded: encoded), !pcm.isEmpty {
                emit(.audio(pcm))
            }
        case "user_transcript":
            if let event = object["user_transcription_event"] as? [String: Any],
               let text = event["user_transcript"] as? String, !text.isEmpty {
                emit(.userTranscript(text))
            }
        case "agent_response":
            if let event = object["agent_response_event"] as? [String: Any],
               let text = event["agent_response"] as? String, !text.isEmpty {
                emit(.agentText(text))
            }
        case "agent_response_correction":
            if let event = object["agent_response_correction_event"] as? [String: Any],
               let text = event["corrected_agent_response"] as? String, !text.isEmpty {
                emit(.agentText(text))
            }
        case "interruption":
            if let event = object["interruption_event"] as? [String: Any], let id = event["event_id"] as? Int {
                lock.lock()
                interruptFloor = max(interruptFloor, id)
                lock.unlock()
            }
            emit(.interruption)
        case "client_tool_call":
            if let call = object["client_tool_call"] as? [String: Any],
               let name = call["tool_name"] as? String,
               let id = call["tool_call_id"] as? String {
                let params = call["parameters"] as? [String: Any] ?? [:]
                let json = (try? JSONSerialization.data(withJSONObject: params)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
                emit(.tool(id: id, name: name, arguments: json))
            }
        default:
            break
        }
    }

    /// Audio of a reply the user already talked over can still be in flight. Drop it.
    private func staleAudio(_ id: Any?) -> Bool {
        guard let id = id as? Int else { return false }
        lock.lock()
        defer { lock.unlock() }
        return id <= interruptFloor
    }

    private func emit(_ event: AgentEvent) {
        onEvent?(event)
    }
}
