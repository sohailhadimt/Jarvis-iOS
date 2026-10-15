import ActivityKit
import AppIntents
import SwiftUI
import WidgetKit

struct JarvisLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: JarvisActivityAttributes.self) { context in
            LockScreenActivityView(state: context.state)
                .activityBackgroundTint(Color.black.opacity(0.85))
                .activitySystemActionForegroundColor(IslandStyle.teal)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    StaticOrb(phase: context.state.phase).frame(width: 44, height: 44)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Button(intent: EndJarvisSessionIntent()) {
                        Image(systemName: "stop.circle.fill").font(.title2)
                    }
                    .tint(.red)
                }
                DynamicIslandExpandedRegion(.center) {
                    Label(context.state.phase.label, systemImage: context.state.phase.symbol)
                        .font(.headline)
                        .foregroundStyle(IslandStyle.teal)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 2) {
                        if !context.state.reply.isEmpty {
                            Text(context.state.reply).lineLimit(2).foregroundStyle(.white)
                        }
                        if !context.state.transcript.isEmpty {
                            Text(context.state.transcript).lineLimit(1).foregroundStyle(.secondary)
                        }
                    }
                    .font(.caption)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            } compactLeading: {
                StaticOrb(phase: context.state.phase).frame(width: 22, height: 22)
            } compactTrailing: {
                VStack(alignment: .trailing, spacing: 0) {
                    Text(context.state.phase.label)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(IslandStyle.teal)
                        .lineLimit(1)
                    if !context.state.reply.isEmpty {
                        Text(context.state.reply)
                            .font(.system(size: 8))
                            .lineLimit(1)
                            .foregroundStyle(.white.opacity(0.85))
                    }
                }
            } minimal: {
                StaticOrb(phase: context.state.phase).frame(width: 18, height: 18)
            }
            .widgetURL(URL(string: "jarvis://open"))
            .keylineTint(IslandStyle.teal)
        }
    }
}

private enum IslandStyle {
    static var teal: Color {
        Color(hex: SharedConfig.defaults.string(forKey: SharedConfig.Key.accentHex) ?? Theme.defaultAccentHex)
    }
}

struct LockScreenActivityView: View {
    let state: JarvisActivityAttributes.ContentState

    var body: some View {
        HStack(spacing: 12) {
            StaticOrb(phase: state.phase).frame(width: 52, height: 52)
            VStack(alignment: .leading, spacing: 3) {
                Label(state.phase.label, systemImage: state.phase.symbol)
                    .font(.headline).foregroundStyle(IslandStyle.teal)
                if !state.transcript.isEmpty {
                    Text("“\(state.transcript)”").font(.caption).lineLimit(1).foregroundStyle(.white.opacity(0.7))
                }
                if !state.reply.isEmpty {
                    Text(state.reply).font(.caption).lineLimit(2).foregroundStyle(.white)
                }
            }
            Spacer(minLength: 0)
            Button(intent: EndJarvisSessionIntent()) {
                Image(systemName: "xmark.circle.fill").font(.title)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.red)
        }
        .padding()
    }
}
