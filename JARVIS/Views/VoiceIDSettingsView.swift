import AVFoundation
import SwiftUI

struct VoiceIDSettingsView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(AssistantEngine.self) private var engine
    @State private var showEnroll = false
    @State private var enrolled = false

    var body: some View {
        voiceForm
            .navigationTitle("Voice ID")
            .onAppear { enrolled = VoiceProfileStore.hasProfile }
            .sheet(isPresented: $showEnroll, onDismiss: {
                enrolled = VoiceProfileStore.hasProfile
                engine.applyVoicePolicy()
            }) {
                VoiceEnrollmentView {
                    settings.voiceMatchEnabled = true
                    settings.voiceMatchPrompted = true
                    enrolled = true
                    showEnroll = false
                    engine.applyVoicePolicy()
                }
            }
    }

    private var voiceForm: some View {
        @Bindable var settings = settings
        return Form {
            Section {
                Toggle("Respond only to my voice", isOn: $settings.voiceMatchEnabled)
                    .onChange(of: settings.voiceMatchEnabled) { _, on in
                        if on, !VoiceProfileStore.hasProfile {
                            settings.voiceMatchEnabled = false
                            showEnroll = true
                        } else {
                            engine.applyVoicePolicy()
                        }
                    }
            } footer: {
                Text(enrolled
                     ? "A voice print is saved on this iPhone. Other voices are ignored."
                     : "Read a short paragraph once. The print stays on this iPhone.")
            }
            Section {
                Slider(value: strictness, in: 0...2, step: 1)
                HStack {
                    Text("Strict")
                    Spacer()
                    Text("Balanced")
                    Spacer()
                    Text("Relaxed")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            } header: {
                Text("Match")
            } footer: {
                Text("Strict ignores more of the room. Relaxed is easier if your own voice is being skipped.")
            }
            Section {
                Button(enrolled ? "Re-enrol" : "Enrol my voice") { showEnroll = true }
                if enrolled {
                    Button("Delete voice print", role: .destructive) {
                        VoiceProfileStore.clear()
                        settings.voiceMatchEnabled = false
                        enrolled = false
                        engine.applyVoicePolicy()
                    }
                }
            }
        }
    }

    private var strictness: Binding<Double> {
        Binding(
            get: { Self.position(settings.voiceMatchSensitivity) },
            set: { newValue in
                settings.voiceMatchSensitivity = Self.sensitivity(newValue)
                engine.applyVoicePolicy()
            }
        )
    }

    private static func position(_ value: VoiceMatchSensitivity) -> Double {
        switch value {
        case .strict: return 0
        case .balanced: return 1
        case .relaxed: return 2
        }
    }

    private static func sensitivity(_ value: Double) -> VoiceMatchSensitivity {
        let rounded: Double = value.rounded()
        let index: Int = Int(rounded)
        if index <= 0 { return .strict }
        if index == 1 { return .balanced }
        return .relaxed
    }
}

struct VoiceEnrollmentView: View {
    var allowsSkip: Bool = false
    var onEnrolled: () -> Void = {}

    @Environment(AssistantEngine.self) private var engine
    @Environment(\.dismiss) private var dismiss
    @State private var recorder = VoiceEnroller()
    @State private var recording = false
    @State private var elapsed: Double = 0
    @State private var message: String?
    @State private var saving = false

    private static let paragraph = """
    Hello. This is my voice, and I am the only person JARVIS should answer. I am speaking in a steady, natural way. \
    The quick brown fox jumps over the lazy dog. Bright vowels and quiet consonants both matter here. \
    I live in the United Kingdom, so I say lift, aluminium, and mobile. \
    The numbers I use are forty two, sixteen, eighty, and three. \
    Please open the calendar, read the morning briefing, and tell me the weather in London. \
    Blue skies, grey rain, and a warm cup of tea. \
    When I finish this paragraph, JARVIS will know my voice and ignore the room.
    """

    var body: some View {
        NavigationStack {
            enrollmentPage
                .navigationTitle("Enrol voice")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { toolbarContent }
        }
    }

    private var enrollmentPage: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("Read this aloud for about 30 seconds.")
                    .font(.headline)
                Text(Self.paragraph)
                    .font(.body)
                ProgressView(value: progressValue, total: 30.0)
                Text(statusText())
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                if let message {
                    Text(message)
                        .font(.footnote)
                        .foregroundStyle(.orange)
                }
                Button(recording ? "Save voice" : "Start recording") {
                    Task { await toggleRecording() }
                }
                .buttonStyle(.borderedProminent)
                .disabled(saving || (recording && elapsed < 12))
                if recording {
                    Button("Cancel") {
                        recording = false
                        recorder.cancel()
                        elapsed = 0
                    }
                }
            }
            .padding(20)
        }
        .task(id: recording) { await tick() }
        .onDisappear {
            recorder.cancel()
            engine.finishVoiceEnrollment()
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            Button(allowsSkip ? "Not now" : "Close") { dismiss() }
        }
    }

    private var progressValue: Double {
        let capped: Double = min(elapsed, 30)
        return capped
    }

    private func statusText() -> String {
        let shown: Int = Int(elapsed.rounded())
        if recording {
            return "\(shown) seconds. You can save after 12."
        }
        return "JARVIS keeps this recording on the phone. Nothing is uploaded."
    }

    private func tick() async {
        while recording && !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(200))
            guard recording else { return }
            elapsed = recorder.seconds()
            if elapsed >= 32 {
                await saveRecording()
                return
            }
        }
    }

    private func toggleRecording() async {
        if recording {
            await saveRecording()
            return
        }
        message = nil
        await engine.prepareVoiceEnrollment()
        let allowed = await ensureMicrophone()
        guard allowed else { return }
        do {
            try recorder.start()
            elapsed = 0
            recording = true
        } catch {
            message = "Couldn't open the microphone."
        }
    }

    private func saveRecording() async {
        guard !saving else { return }
        saving = true
        recording = false
        let snap = recorder.takeSamples()
        let samples = snap.samples
        let rate: Double = snap.rate
        let profile = await Task.detached(priority: .userInitiated) {
            SpeakerEmbedding.profile(samples: samples, sampleRate: rate)
        }.value
        saving = false
        guard let profile else {
            message = "That was too quiet or too short. Read the paragraph again."
            elapsed = 0
            return
        }
        VoiceProfileStore.save(profile)
        onEnrolled()
        dismiss()
    }

    private func ensureMicrophone() async -> Bool {
        if AVAudioApplication.shared.recordPermission == .granted { return true }
        let granted = await AVAudioApplication.requestRecordPermission()
        if !granted {
            message = "Microphone access is off. Enable it in iPhone Settings > JARVIS."
        }
        return granted
    }
}

@MainActor
final class VoiceEnroller {
    private var audioEngine: AVAudioEngine?
    private let box = SampleBox()
    private var tapOn = false

    func seconds() -> Double {
        let stats = box.stats()
        guard stats.rate > 0 else { return 0 }
        let duration: Double = Double(stats.frames) / stats.rate
        return duration
    }

    func start() throws {
        stopEngine()
        box.reset()
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .voiceChat, options: [.defaultToSpeaker, .allowBluetoothHFP])
        try session.setActive(true)
        let engine = AVAudioEngine()
        try? engine.inputNode.setVoiceProcessingEnabled(true)
        engine.inputNode.isVoiceProcessingBypassed = false
        let captured = box
        let tap = AudioTaps.captureTap { buffer in
            captured.append(buffer)
        }
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw ListenerError.noInput }
        input.installTap(onBus: 0, bufferSize: 4096, format: format, block: tap)
        tapOn = true
        engine.prepare()
        do {
            try engine.start()
        } catch {
            stopEngine()
            throw error
        }
        audioEngine = engine
    }

    func takeSamples() -> (samples: [Float], rate: Double) {
        stopEngine()
        return box.snapshot()
    }

    func cancel() {
        stopEngine()
        box.reset()
    }

    private func stopEngine() {
        if tapOn {
            audioEngine?.inputNode.removeTap(onBus: 0)
            tapOn = false
        }
        audioEngine?.stop()
        audioEngine = nil
    }
}

final class SampleBox: @unchecked Sendable {
    private let lock = NSLock()
    private var samples: [Float] = []
    private var rate: Double = 48_000

    func append(_ buffer: AVAudioPCMBuffer) {
        guard let data = buffer.floatChannelData?[0] else { return }
        let count: Int = Int(buffer.frameLength)
        guard count > 0 else { return }
        lock.lock()
        if buffer.format.sampleRate > 1 { rate = buffer.format.sampleRate }
        samples.append(contentsOf: UnsafeBufferPointer(start: data, count: count))
        let cap: Int = Int(rate * 32.0)
        if cap > 0, samples.count > cap {
            let extra: Int = samples.count - cap
            samples.removeFirst(extra)
        }
        lock.unlock()
    }

    func stats() -> (frames: Int, rate: Double) {
        lock.lock()
        defer { lock.unlock() }
        return (samples.count, rate)
    }

    func snapshot() -> (samples: [Float], rate: Double) {
        lock.lock()
        defer { lock.unlock() }
        return (samples, rate)
    }

    func reset() {
        lock.lock()
        samples.removeAll(keepingCapacity: false)
        lock.unlock()
    }
}
