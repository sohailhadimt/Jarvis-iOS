import SwiftUI

/// End-of-speech latency, false triggers, and the synthetic turn-meter checks.
struct VoiceTimingView: View {
    @Environment(AssistantEngine.self) private var engine
    @State private var latency = LatencySnapshot(voiceProcessing: false, lastFirstAudioMs: nil, falseTriggers: 0, fillers: 0)
    @State private var meter = VoiceTurnSnapshot(probability: 0, noiseFloor: 0, calibrated: false, falseTriggers: 0, forwarding: false, endProbability: nil)
    @State private var lines: [String] = []

    var body: some View {
        Form {
            Section("This session") {
                LabeledContent("Voice processing", value: latency.voiceProcessing ? "On" : "Off")
                LabeledContent("End of speech to first audio", value: latencyText)
                LabeledContent("False triggers", value: "\(latency.falseTriggers)")
                LabeledContent("Late acknowledgements", value: "\(latency.fillers)")
            }
            Section("Turn meter") {
                LabeledContent("End of turn", value: endText)
                LabeledContent("Speech probability", value: String(format: "%.2f", meter.probability))
                LabeledContent("Noise floor", value: String(format: "%.4f", meter.noiseFloor))
                LabeledContent("Calibrated", value: meter.calibrated ? "Yes" : "No")
                LabeledContent("Forwarding speech", value: meter.forwarding ? "Yes" : "No")
                LabeledContent("Short bursts ignored", value: "\(meter.falseTriggers)")
            }
            Section {
                Button("Run turn fixtures") {
                    lines = VoiceTurnFixtures.run().lines
                }
                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                    Text(line)
                        .font(.caption.monospaced())
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            } header: {
                Text("Simulator fixtures")
            } footer: {
                Text("Before this meter: an energy gate, 800 ms of speech, 1.75 s of silence, and barge-in at 250 ms. These checks use synthetic frames. A real iPhone still has to confirm echo cancellation, Voice ID against a television, and the time from the end of speech to the first spoken word. The simulator often leaves voice processing off.")
            }
        }
        .navigationTitle("Voice timing")
        .toolbar(.visible, for: .navigationBar)
        .onAppear(perform: refresh)
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
                refresh()
            }
        }
    }

    private var latencyText: String {
        guard let ms = latency.lastFirstAudioMs else { return "—" }
        return "\(ms) ms"
    }

    private var endText: String {
        guard let score = meter.endProbability else { return "—" }
        return String(format: "%.2f", score)
    }

    private func refresh() {
        let timing = engine.voiceDebugSnapshot()
        latency = timing.latency
        meter = timing.meter
    }
}
