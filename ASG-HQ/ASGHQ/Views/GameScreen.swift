import SceneKit
import SwiftUI
import UIKit

struct GameScreen: View {
    @ObservedObject var session: HQSession

    var body: some View {
        ZStack {
            OfficeRepresentable(session: session)
                .ignoresSafeArea()
            VStack(spacing: 10) {
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 8) {
                        LevelCard(progress: session.progress)
                        Button("Perks") { session.openPerks() }
                            .buttonStyle(ChipButtonStyle())
                    }
                    Spacer(minLength: 8)
                    VStack(alignment: .trailing, spacing: 8) {
                        DailyCard(progress: session.progress, synced: session.hasSnapshot, error: session.syncError)
                        Button { session.openSettings() } label: {
                            Image(systemName: "gearshape.fill")
                                .font(.title3)
                                .foregroundStyle(HQTheme.gold)
                                .frame(width: 44, height: 44)
                                .background(Circle().fill(Color.black.opacity(0.45)))
                                .overlay(Circle().stroke(HQTheme.gold, lineWidth: 1.5))
                        }
                        .accessibilityLabel("Settings")
                    }
                }
                Spacer()
                HStack(alignment: .bottom) {
                    Joystick { x, y in session.setStick(x: x, y: y) }
                    Spacer()
                    if let prompt = session.worldPrompt, session.talk == nil, !session.wardrobeOpen, !session.perksOpen, !session.settingsOpen {
                        PromptChip(prompt: prompt) {
                            switch prompt.action {
                            case .talk(let bot): session.openTalk(bot: bot, mic: false)
                            case .wardrobe: session.openWardrobe()
                            case .none: break
                            }
                        }
                    }
                    Spacer()
                    HStack(spacing: 14) {
                        RoundButton(system: "mic.fill", label: "Dictate", diameter: 68) {
                            session.openGiveTask(mic: true)
                        }
                        RoundButton(system: "bolt.fill", label: "Give task", diameter: 86) {
                            session.openGiveTask(mic: false)
                        }
                    }
                }
            }
            .padding(18)
            if let banner = session.banner {
                Text(banner)
                    .font(.headline.weight(.bold))
                    .foregroundStyle(Color.black)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 10)
                    .background(Capsule().fill(HQTheme.gold))
                    .padding(.top, 8)
                    .frame(maxHeight: .infinity, alignment: .top)
            }
            if let talk = session.talk {
                TalkPanel(session: session, request: talk)
                    .transition(.move(edge: .trailing))
            } else if session.wardrobeOpen {
                WardrobePanel(session: session)
                    .transition(.move(edge: .trailing))
            } else if session.perksOpen {
                PerkPanel(session: session)
                    .transition(.move(edge: .trailing))
            } else if session.settingsOpen {
                SettingsPanel(session: session)
                    .transition(.move(edge: .trailing))
            }
        }
        .background(HQTheme.navy)
        .task {
            await session.sync()
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 45_000_000_000)
                await session.sync()
            }
        }
        .onAppear { UIApplication.shared.isIdleTimerDisabled = true }
        .onDisappear { UIApplication.shared.isIdleTimerDisabled = false }
    }
}

struct OfficeRepresentable: UIViewRepresentable {
    @ObservedObject var session: HQSession

    func makeCoordinator() -> Coordinator {
        Coordinator(session: session)
    }

    func makeUIView(context: Context) -> SCNView {
        let view = SCNView()
        view.scene = session.world.scene
        view.pointOfView = session.world.camera
        view.delegate = context.coordinator
        view.preferredFramesPerSecond = 60
        view.rendersContinuously = true
        view.antialiasingMode = .none
        view.autoenablesDefaultLighting = false
        view.allowsCameraControl = false
        view.isPlaying = true
        view.backgroundColor = UIColor(red: 0.015, green: 0.02, blue: 0.05, alpha: 1)
        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.tapped(_:)))
        view.addGestureRecognizer(tap)
        session.world.onTalk = { [weak session] bot in
            DispatchQueue.main.async { session?.openTalk(bot: bot, mic: false) }
        }
        return view
    }

    func updateUIView(_ uiView: SCNView, context: Context) {
        context.coordinator.session = session
        uiView.pointOfView = session.world.camera
    }

    final class Coordinator: NSObject, SCNSceneRendererDelegate {
        let world: OfficeWorld
        weak var session: HQSession?
        private var lastPrompt: WorldPrompt?
        private var lastZone = "office"

        init(session: HQSession) {
            world = session.world
            self.session = session
        }

        func renderer(_ renderer: SCNSceneRenderer, updateAtTime time: TimeInterval) {
            world.tick(time: time)
            let snap = world.chrome()
            guard snap.0 != lastPrompt || snap.1 != lastZone else { return }
            lastPrompt = snap.0
            lastZone = snap.1
            let prompt = snap.0
            let zone = snap.1
            DispatchQueue.main.async { [weak session] in
                session?.applyChrome(prompt: prompt, zone: zone)
            }
        }

        @objc func tapped(_ gesture: UITapGestureRecognizer) {
            guard let view = gesture.view as? SCNView else { return }
            world.handleTap(in: view, at: gesture.location(in: view))
        }
    }
}

private struct LevelCard: View {
    var progress: HQProgress

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "shield.fill")
                    .foregroundStyle(HQTheme.gold)
                Text("LEVEL \(progress.level)")
                    .font(.system(size: 16, weight: .heavy, design: .rounded))
                    .foregroundStyle(HQTheme.ink)
            }
            GeometryReader { geo in
                let fraction = progress.xpToNext > 0 ? CGFloat(progress.xpIntoLevel) / CGFloat(progress.xpToNext) : 0
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.14))
                    Capsule().fill(HQTheme.gold).frame(width: max(8, geo.size.width * min(1, fraction)))
                }
            }
            .frame(width: 180, height: 8)
            Text("XP \(progress.xpIntoLevel) / \(progress.xpToNext)")
                .font(.caption.weight(.semibold))
                .foregroundStyle(HQTheme.ink.opacity(0.8))
        }
        .padding(12)
        .background(HQCard())
    }
}

private struct DailyCard: View {
    var progress: HQProgress
    var synced: Bool
    var error: String?

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Daily challenge:")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(HQTheme.ink.opacity(0.75))
                Text(synced ? progress.daily.title : "Waiting for JARVIS")
                    .font(.headline.weight(.bold))
                    .foregroundStyle(HQTheme.ink)
                if synced {
                    Text(progress.daily.done ? "Done" : "\(progress.daily.progress) / \(progress.daily.target)")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(progress.daily.done ? Color.green : HQTheme.gold)
                } else if let error {
                    Text(error)
                        .font(.caption2)
                        .foregroundStyle(HQTheme.gold)
                        .lineLimit(2)
                }
            }
            Image(systemName: "calendar")
                .font(.title2)
                .foregroundStyle(HQTheme.gold)
                .frame(width: 46, height: 46)
                .background(RoundedRectangle(cornerRadius: 10).stroke(HQTheme.gold, lineWidth: 1.5))
        }
        .padding(12)
        .background(HQCard())
    }
}

private struct PromptChip: View {
    var prompt: WorldPrompt
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: prompt.action == .wardrobe ? "tshirt.fill" : "hand.point.up.left.fill")
                VStack(alignment: .leading, spacing: 1) {
                    Text(prompt.title).font(.headline.weight(.bold))
                    Text(prompt.detail).font(.caption)
                }
            }
            .foregroundStyle(prompt.action == .none ? HQTheme.gold : Color.black)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(Capsule().fill(prompt.action == .none ? Color.black.opacity(0.72) : Color.white))
            .overlay(Capsule().stroke(HQTheme.gold, lineWidth: 2))
        }
        .disabled(prompt.action == .none)
    }
}

private struct RoundButton: View {
    var system: String
    var label: String
    var diameter: CGFloat
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 2) {
                Image(systemName: system).font(.title3.weight(.bold))
                Text(label).font(.system(size: 12, weight: .bold))
            }
            .foregroundStyle(HQTheme.ink)
            .frame(width: diameter, height: diameter)
            .background(Circle().fill(Color.black.opacity(0.45)))
            .overlay(Circle().stroke(HQTheme.gold, lineWidth: 3))
        }
        .accessibilityLabel(label)
    }
}

private struct Joystick: View {
    var onChange: (Float, Float) -> Void
    @State private var offset = CGSize.zero
    private let radius: CGFloat = 42

    var body: some View {
        ZStack {
            Circle()
                .fill(Color.black.opacity(0.35))
                .overlay(Circle().stroke(HQTheme.gold, lineWidth: 3))
            Circle()
                .fill(HQTheme.gold.opacity(0.92))
                .frame(width: 52, height: 52)
                .offset(offset)
        }
        .frame(width: 124, height: 124)
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    let dx = value.translation.width
                    let dy = value.translation.height
                    let distance = hypot(dx, dy)
                    let scale = distance > 0 ? min(distance, radius) / distance : 0
                    offset = CGSize(width: dx * scale, height: dy * scale)
                    onChange(Float(offset.width / radius), Float(-offset.height / radius))
                }
                .onEnded { _ in
                    offset = .zero
                    onChange(0, 0)
                }
        )
        .accessibilityLabel("Move")
    }
}

private struct ChipButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.caption.weight(.bold))
            .foregroundStyle(HQTheme.gold)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Capsule().fill(Color.black.opacity(0.5)))
            .overlay(Capsule().stroke(HQTheme.gold, lineWidth: 1))
    }
}

private struct HQCard: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 16, style: .continuous)
            .fill(Color.black.opacity(0.55))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(HQTheme.gold.opacity(0.85), lineWidth: 1))
    }
}
