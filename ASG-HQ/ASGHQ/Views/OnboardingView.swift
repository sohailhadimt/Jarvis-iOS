import SwiftUI

struct OnboardingView: View {
    @ObservedObject var session: HQSession
    @State private var page = 0
    @State private var name = "Sohail"
    @State private var token = ""

    var body: some View {
        ZStack {
            HQTheme.navy.ignoresSafeArea()
            VStack(spacing: 18) {
                Text("ASG HQ")
                    .font(.system(size: 44, weight: .black, design: .rounded))
                    .foregroundStyle(HQTheme.gold)
                TabView(selection: $page) {
                    pageCard(
                        "The night office",
                        "Walk the floor of Adz Security Growth. Four desks. One headquarters. You, in the middle of it."
                    ).tag(0)
                    pageCard(
                        "The desks stay inside",
                        "J.A.R.V.I.S. coordinates. F.R.I.D.A.Y. designs. U.L.T.R.O.N. drafts pitches. E.D.I.T.H. researches. Anything that would send, publish, or spend waits in the JARVIS app for approval. This game never sends it."
                    ).tag(1)
                    pageCard(
                        "XP is real work",
                        "Levels come from tasks finished, posts approved, and calls booked. Walking around the office does not award XP."
                    ).tag(2)
                    tokenPage.tag(3)
                }
                .tabViewStyle(.page(indexDisplayMode: .always))
                .frame(maxWidth: 640, maxHeight: 280)
            }
            .padding(28)
        }
    }

    private func pageCard(_ title: String, _ body: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.title2.weight(.bold))
                .foregroundStyle(HQTheme.ink)
            Text(body)
                .font(.body)
                .foregroundStyle(HQTheme.ink.opacity(0.86))
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(22)
        .background(panel)
    }

    private var tokenPage: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Your key")
                .font(.title2.weight(.bold))
                .foregroundStyle(HQTheme.ink)
            Text("Paste the same JARVIS app token. It is stored in the iPhone Keychain and is not written into the app.")
                .font(.subheadline)
                .foregroundStyle(HQTheme.ink.opacity(0.8))
            TextField("Your name", text: $name)
                .textFieldStyle(.roundedBorder)
            SecureField("JARVIS app token", text: $token)
                .textFieldStyle(.roundedBorder)
            HStack {
                Button("Save token and enter") {
                    session.finishOnboarding(name: name, token: token)
                }
                .buttonStyle(GoldButtonStyle())
                .disabled(token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Button("Enter and add the token in Settings") {
                    session.finishOnboarding(name: name, token: nil)
                }
                .font(.footnote.weight(.semibold))
                .foregroundStyle(HQTheme.gold)
            }
        }
        .padding(22)
        .background(panel)
    }

    private var panel: some View {
        RoundedRectangle(cornerRadius: 18, style: .continuous)
            .fill(HQTheme.panel)
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(HQTheme.gold.opacity(0.7), lineWidth: 1))
    }
}

struct GoldButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.bold))
            .foregroundStyle(Color.black)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(Capsule().fill(HQTheme.gold.opacity(configuration.isPressed ? 0.7 : 1)))
    }
}
