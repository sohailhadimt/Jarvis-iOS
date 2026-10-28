import SwiftUI

struct PerkPanel: View {
    @ObservedObject var session: HQSession

    private let perks: [(id: String, title: String, detail: String, level: Int)] = [
        ("outfit_pack", "Outfit pack", "Tee, chinos, trainers, overcoat, glasses, and the gold, burgundy, and forest cloth. The bar cart comes with it.", 3),
        ("corner_office", "Corner office", "The glass office in the south-east opens, and the art frame can hang in the apartment.", 5),
        ("rooftop", "Rooftop terrace", "The lift on the east wall goes up to the terrace.", 8),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Perks").font(.title3.weight(.bold)).foregroundStyle(HQTheme.gold)
                Spacer()
                Button("Close") { session.closePerks() }
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(HQTheme.gold)
            }
            Text("Level \(session.progress.level) · \(session.progress.xp) XP from finished work")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(HQTheme.ink)
            ForEach(perks, id: \.id) { perk in
                let open = session.progress.perks.contains(perk.id)
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: open ? "checkmark.seal.fill" : "lock.fill")
                        .foregroundStyle(open ? HQTheme.gold : HQTheme.ink.opacity(0.6))
                    VStack(alignment: .leading, spacing: 3) {
                        Text(perk.title).font(.headline).foregroundStyle(HQTheme.ink)
                        Text(perk.detail).font(.caption).foregroundStyle(HQTheme.ink.opacity(0.75))
                        Text(open ? "Unlocked" : "Level \(perk.level)")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(HQTheme.gold)
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 12).stroke(HQTheme.gold.opacity(open ? 1 : 0.35), lineWidth: 1))
            }
            Text("Recent work")
                .font(.caption.weight(.bold))
                .foregroundStyle(HQTheme.gold)
            if session.progress.events.isEmpty {
                Text("XP shows up here when JARVIS finishes a task, you approve a draft, or a call is booked. Walking and tapping do not count.")
                    .font(.caption)
                    .foregroundStyle(HQTheme.ink.opacity(0.75))
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(session.progress.events) { event in
                            VStack(alignment: .leading, spacing: 2) {
                                Text("+\(event.xp) XP · \(event.kind.replacingOccurrences(of: "_", with: " "))")
                                    .font(.caption.weight(.bold))
                                    .foregroundStyle(HQTheme.gold)
                                Text(event.summary)
                                    .font(.caption)
                                    .foregroundStyle(HQTheme.ink)
                                    .lineLimit(3)
                            }
                        }
                    }
                }
            }
        }
        .padding(16)
        .frame(width: 420)
        .frame(maxHeight: .infinity)
        .background(HQTheme.panel)
        .overlay(Rectangle().frame(width: 1).foregroundStyle(HQTheme.gold), alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .trailing)
    }
}
