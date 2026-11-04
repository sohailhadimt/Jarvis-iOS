import SwiftUI

/// A comparison of businesses JARVIS is calling. Booking waits for Approve and nothing is paid.
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

    private var waiting: Bool { hunt.status == "awaiting_approval" || hunt.status == "booking" }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(heading)
                .font(.system(size: 11, weight: .semibold))
                .tracking(1.4)
                .foregroundStyle(Color(hex: "#2E8BFF"))
            Text(hunt.goal)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(.white)
                .lineLimit(2)
            ForEach(hunt.quotes) { quote in
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(quote.business)
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(.white)
                        if quote.recommended {
                            Text("RECOMMENDED")
                                .font(.system(size: 10, weight: .semibold))
                                .tracking(0.8)
                                .foregroundStyle(Color(hex: "#2E8BFF"))
                        }
                    }
                    Text(detail(quote))
                        .font(.system(size: 13))
                        .foregroundStyle(Color(hex: "#C9C6D4"))
                        .fixedSize(horizontal: false, vertical: true)
                    if !quote.transcript.isEmpty {
                        Text(transcript(quote))
                            .font(.system(size: 12))
                            .foregroundStyle(Color(hex: "#8E8A99"))
                            .lineLimit(4)
                    }
                    if hunt.status == "draft" {
                        Button("Remove") {
                            JarvisHaptics.tap()
                            engine.removeShopQuote(hunt.id, quoteID: quote.id)
                        }
                        .buttonStyle(.plain)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Color(hex: "#C9C6D4"))
                    }
                    if hunt.status == "comparing", quote.status == "quoted" {
                        Button("Approve") {
                            JarvisHaptics.tap()
                            engine.chooseHunt(hunt.id, quoteID: quote.id)
                        }
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .background(quote.recommended ? Color(hex: "#2E8BFF") : Color.white.opacity(0.06), in: Capsule())
                        .buttonStyle(.plain)
                    }
                }
            }
            if hunt.status == "draft" {
                Button("Start calls") {
                    JarvisHaptics.tap()
                    engine.startShop(hunt.id)
                }
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(Color(hex: "#2E8BFF"), in: Capsule())
                .buttonStyle(.plain)
            }
            Text(footnote)
                .font(.system(size: 12))
                .foregroundStyle(Color(hex: "#8E8A99"))
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(hex: "#0B1220").opacity(0.92), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(Color(hex: "#2E8BFF").opacity(0.45), lineWidth: 0.8))
    }

    private var heading: String {
        switch hunt.status {
        case "draft": return "SHOPPING LIST"
        case "queued": return "WAITING"
        case "calling": return "CALLING"
        case "booking": return "BOOKING"
        case "awaiting_approval": return "AWAITING APPROVAL"
        default: return "COMPARING"
        }
    }

    private var footnote: String {
        switch hunt.status {
        case "draft":
            return "Text or say the numbers to change this list, then start. Nothing is booked."
        case "queued":
            return "Paused until businesses can be rung, after 08:00 and within today's ten calls. Nothing is booked."
        case "calling":
            return "One call at a time. Nothing is booked."
        case "booking":
            return "Ringing them back to book. Nothing is paid."
        case "awaiting_approval":
            return "Waiting for your approval. Nothing is paid."
        default:
            return "Approve books a confirmation call. Nothing is paid."
        }
    }

    private func detail(_ quote: CallQuote) -> String {
        if quote.status == "calling" { return "On the phone now." }
        if quote.status == "pending" { return "Waiting for their turn." }
        if quote.status == "failed" { return "They didn't connect." }
        if quote.status == "skipped" { return "Not called." }
        if quote.status == "booking" { return "Booking call in progress." }
        let price = quote.price.isEmpty ? "Price to confirm" : quote.price
        let when = quote.availability.isEmpty ? "Time to confirm" : quote.availability
        let terms = quote.terms.isEmpty ? (quote.fees.isEmpty ? "Terms to confirm" : "Call-out \(quote.fees)") : quote.terms
        let notes = quote.summary.isEmpty ? "" : " Notes: \(quote.summary)"
        return "\(price) · \(when) · \(terms)\(notes)"
    }

    private func transcript(_ quote: CallQuote) -> String {
        quote.transcript.prefix(4).map { line in
            let who = line.role == "assistant" ? "JARVIS" : "Them"
            return "\(who): \(line.text)"
        }.joined(separator: "\n")
    }
}
