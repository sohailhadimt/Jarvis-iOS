import SwiftUI

/// A comparison of businesses JARVIS called. Booking waits for an approval and nothing is paid.
struct HuntStrip: View {
    @Environment(AssistantEngine.self) private var engine

    var body: some View {
        VStack(spacing: 8) {
            ForEach(engine.hunts) { hunt in
                HuntCard(hunt: hunt)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.spring(duration: 0.42, bounce: 0.05), value: engine.hunts.map(\.id))
    }
}

private struct HuntCard: View {
    @Environment(AssistantEngine.self) private var engine
    var hunt: CallHunt

    private var waiting: Bool { hunt.status == "awaiting_approval" }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(waiting ? "AWAITING APPROVAL" : "COMPARING")
                .font(.system(size: 11, weight: .semibold))
                .tracking(1.4)
                .foregroundStyle(Color(hex: "#2E8BFF"))
            Text(hunt.goal)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(.white)
                .lineLimit(2)
            ForEach(hunt.quotes) { quote in
                VStack(alignment: .leading, spacing: 4) {
                    Text(quote.business)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(.white)
                    Text(detail(quote))
                        .font(.system(size: 13))
                        .foregroundStyle(Color(hex: "#C9C6D4"))
                        .fixedSize(horizontal: false, vertical: true)
                    if hunt.status == "comparing", quote.status == "quoted" {
                        Button("Book") {
                            JarvisHaptics.tap()
                            engine.chooseHunt(hunt.id, quoteID: quote.id)
                        }
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .background(Color.white.opacity(0.06), in: Capsule())
                        .buttonStyle(.plain)
                    }
                }
            }
            Text(waiting ? "Waiting for your approval. Nothing is paid." : "Booking waits for your approval. Nothing is paid.")
                .font(.system(size: 12))
                .foregroundStyle(Color(hex: "#8E8A99"))
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(hex: "#0B1220").opacity(0.92), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(Color(hex: "#2E8BFF").opacity(0.45), lineWidth: 0.8))
    }

    private func detail(_ quote: CallQuote) -> String {
        let price = quote.price.isEmpty ? "Price to confirm" : quote.price
        let when = quote.availability.isEmpty ? "Time to confirm" : quote.availability
        let fees = quote.fees.isEmpty ? "No call-out fee noted" : "Call-out \(quote.fees)"
        if quote.status == "calling" { return "Still on the call, Sir." }
        if quote.status == "failed" { return "They didn't connect." }
        return "\(price) · \(when) · \(fees)"
    }
}
