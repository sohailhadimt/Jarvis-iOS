import SwiftUI

/// Full camera from the menu. The same session can stay up on the voice screen.
struct VisionStudioView: View {
    @Environment(AssistantEngine.self) private var engine
    @Environment(AppSettings.self) private var settings
    @State private var camera = VisionCamera.shared
    @State private var draft = ""

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            ScrollView {
                studio
            }
        }
        .navigationTitle("Camera")
        .toolbar(.visible, for: .navigationBar)
        .task { await camera.acquire(owner: .panel) }
        .onDisappear { camera.release(owner: .panel) }
    }

    private var studio: some View {
        VStack(spacing: 16) {
            preview
            if let note = camera.note, !note.isEmpty {
                Text(note)
                    .font(.system(size: 13, weight: .medium, design: .monospaced))
                    .foregroundStyle(settings.accentColor)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .padding(.horizontal, 24)
            }
            controls
            askField
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 12)
    }

    private var preview: some View {
        ZStack(alignment: .topTrailing) {
            if camera.isLive {
                CameraPreview(session: camera.previewSession)
            } else {
                Color.black
            }
            if let still = camera.heldPreview {
                Image(uiImage: still)
                    .resizable()
                    .scaledToFill()
            }
            if camera.heldPreview != nil {
                Button(action: { camera.discardHeld() }) {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 28, height: 28)
                        .background(Circle().fill(Color.black.opacity(0.65)))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Discard photo")
                .padding(8)
            }
        }
        .frame(maxWidth: .infinity)
        .aspectRatio(0.78, contentMode: .fit)
        .frame(maxHeight: 360)
        .clipShape(RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(settings.accentColor.opacity(0.7), lineWidth: 1))
    }

    private var controls: some View {
        HStack(spacing: 12) {
            roundButton(system: "arrow.triangle.2.circlepath", label: "Flip camera") {
                camera.flip()
            }
            roundButton(system: "camera", label: "Snap photo") {
                camera.holdStill()
            }
            roundButton(system: camera.isLive ? "video.slash" : "video", label: camera.isLive ? "Stop camera" : "Start camera") {
                Task {
                    if camera.isLive {
                        camera.suspend()
                    } else {
                        await camera.acquire(owner: .panel)
                    }
                }
            }
        }
    }

    private var askField: some View {
        VStack(spacing: 10) {
            Button(action: askSight) {
                Text("What do you see?")
                    .font(.system(size: 15, weight: .medium, design: .monospaced))
                    .foregroundStyle(settings.accentColor)
                    .frame(maxWidth: .infinity)
                    .frame(height: 44)
                    .overlay(Capsule().stroke(settings.accentColor.opacity(0.7), lineWidth: 1))
            }
            .buttonStyle(.plain)
            HStack(spacing: 8) {
                TextField("", text: $draft, prompt: Text("Ask about the photo…").foregroundStyle(settings.accentColor.opacity(0.55)))
                    .font(.system(size: 15, weight: .regular, design: .monospaced))
                    .foregroundStyle(.white)
                    .submitLabel(.send)
                    .onSubmit(sendDraft)
                Button(action: sendDraft) {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(settings.accentColor)
                        .frame(width: 32, height: 32)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Send")
            }
            .padding(.leading, 16)
            .padding(.trailing, 8)
            .frame(height: 44)
            .overlay(Capsule().stroke(settings.accentColor.opacity(0.55), lineWidth: 1))
        }
    }

    private func roundButton(system: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: system)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(settings.accentColor)
                .frame(width: 52, height: 52)
                .background(Circle().fill(Color.black))
                .overlay(Circle().stroke(settings.accentColor.opacity(0.75), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    private func askSight() {
        engine.ask("What do you see?")
    }

    private func sendDraft() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        draft = ""
        engine.ask(text)
    }
}
