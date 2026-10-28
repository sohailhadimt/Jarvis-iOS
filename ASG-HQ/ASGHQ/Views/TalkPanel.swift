import SwiftUI

struct TalkPanel: View {
    @ObservedObject var session: HQSession
    var request: TalkRequest
    @StateObject private var speech = SpeechDictation()
    @State private var draft = ""

    private var bot: HQBot { HQBot.find(request.bot) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(bot.name).font(.title3.weight(.bold)).foregroundStyle(HQTheme.gold)
                    Text(bot.role).font(.caption).foregroundStyle(HQTheme.ink.opacity(0.75))
                }
                Spacer()
                Button("Close") { session.closeTalk() }
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(HQTheme.gold)
            }
            Text("Drafts stay at HQ. Sending, publishing, and spending wait in JARVIS Approvals. This game does not send them.")
                .font(.caption)
                .foregroundStyle(HQTheme.ink.opacity(0.7))
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(session.lines.filter { $0.bot == request.bot }) { line in
                        Text(line.text)
                            .font(.subheadline)
                            .foregroundStyle(line.role == .player ? Color.black : HQTheme.ink)
                            .padding(10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(
                                RoundedRectangle(cornerRadius: 12)
                                    .fill(line.role == .player ? Color.white : (line.needsApproval ? Color.red.opacity(0.35) : Color.white.opacity(0.08)))
                            )
                    }
                }
            }
            if let error = speech.error {
                Text(error).font(.caption).foregroundStyle(HQTheme.gold)
            }
            if speech.listening || !speech.transcript.isEmpty {
                Text(speech.listening ? "Listening…" : "Heard")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(HQTheme.gold)
                Text(speech.transcript.isEmpty ? "…" : speech.transcript)
                    .font(.subheadline)
                    .foregroundStyle(HQTheme.ink)
            }
            TextField("Give \(bot.name) a task", text: $draft, axis: .vertical)
                .lineLimit(2...4)
                .textFieldStyle(.roundedBorder)
            HStack {
                Button { speech.toggle() } label: {
                    Image(systemName: speech.listening ? "stop.fill" : "mic.fill")
                        .frame(width: 44, height: 36)
                }
                .buttonStyle(GoldButtonStyle())
                Button(session.sending ? "Sending…" : "Give task") {
                    let spoken = speech.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
                    let message = [draft, spoken].filter { !$0.isEmpty }.joined(separator: " ")
                    speech.stop()
                    draft = ""
                    Task { await session.send(bot: request.bot, text: message) }
                }
                .buttonStyle(GoldButtonStyle())
                .disabled(session.sending)
            }
        }
        .padding(16)
        .frame(width: 420)
        .frame(maxHeight: .infinity)
        .background(HQTheme.panel)
        .overlay(Rectangle().frame(width: 1).foregroundStyle(HQTheme.gold), alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .trailing)
        .onAppear {
            if request.mic { speech.start() }
        }
        .onDisappear { speech.stop() }
    }
}
