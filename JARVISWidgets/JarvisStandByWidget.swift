import SwiftUI
import WidgetKit

struct StandByEntry: TimelineEntry {
    let date: Date
    let transcript: String
    let reply: String
}

struct StandByProvider: TimelineProvider {
    func placeholder(in context: Context) -> StandByEntry {
        StandByEntry(date: .now, transcript: "", reply: "At your service, sir.")
    }

    func getSnapshot(in context: Context, completion: @escaping (StandByEntry) -> Void) {
        completion(currentEntry())
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<StandByEntry>) -> Void) {
        // The app calls WidgetCenter.reloadTimelines after every reply, so no polling needed.
        completion(Timeline(entries: [currentEntry()], policy: .never))
    }

    private func currentEntry() -> StandByEntry {
        let d = SharedConfig.defaults
        return StandByEntry(date: .now,
                            transcript: d.string(forKey: SharedConfig.Key.lastTranscript) ?? "",
                            reply: d.string(forKey: SharedConfig.Key.lastReply) ?? "At your service, sir.")
    }
}

struct JarvisStandByWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: SharedConfig.standByWidgetKind, provider: StandByProvider()) { entry in
            StandByWidgetView(entry: entry)
                .containerBackground(.black, for: .widget)
        }
        .configurationDisplayName("JARVIS")
        .description("The JARVIS orb and last reply. On the Lock Screen, a tap opens JARVIS listening. On the Home Screen, a tap opens StandBy.")
        .supportedFamilies([.systemSmall, .accessoryCircular, .accessoryRectangular, .accessoryInline])
    }
}

struct StandByWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: StandByEntry

    var body: some View {
        content.widgetURL(destination)
    }

    /// Lock Screen families open listening. The Home Screen widget still opens StandBy.
    private var destination: URL? {
        switch family {
        case .accessoryCircular, .accessoryRectangular, .accessoryInline:
            URL(string: "jarvis://listen")
        default:
            URL(string: "jarvis://standby")
        }
    }

    @ViewBuilder
    private var content: some View {
        switch family {
        case .accessoryCircular:
            StaticOrb().padding(2)
        case .accessoryRectangular:
            HStack {
                StaticOrb().frame(width: 30, height: 30)
                Text(entry.reply).font(.caption2).lineLimit(3)
            }
        case .accessoryInline:
            Label("JARVIS", systemImage: "mic.fill")
        default:
            VStack(spacing: 6) {
                StaticOrb().frame(maxWidth: .infinity, maxHeight: .infinity)
                Text(entry.reply)
                    .font(.caption2)
                    .lineLimit(2)
                    .foregroundStyle(.white.opacity(0.8))
                    .multilineTextAlignment(.center)
            }
        }
    }
}
