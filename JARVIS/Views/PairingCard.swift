import Contacts
import ContactsUI
import SwiftUI
import UIKit

/// A Contacts card named JARVIS, with the worker number and the ring mark.
enum JarvisContactCard {
    static func make(number: String) -> CNMutableContact {
        let contact = CNMutableContact()
        contact.givenName = "JARVIS"
        contact.organizationName = "JARVIS"
        contact.phoneNumbers = [
            CNLabeledValue(label: CNLabelPhoneNumberMain, value: CNPhoneNumber(stringValue: number)),
        ]
        contact.imageData = ringImage().pngData()
        return contact
    }

    /// The home-screen ring, drawn once for the contact photo.
    static func ringImage() -> UIImage {
        let side: CGFloat = 400
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: side, height: side))
        return renderer.image { context in
            UIColor(red: 5 / 255, green: 8 / 255, blue: 15 / 255, alpha: 1).setFill()
            context.fill(CGRect(x: 0, y: 0, width: side, height: side))
            let center = CGPoint(x: side / 2, y: side / 2)
            let bloom = UIBezierPath(arcCenter: center, radius: 132, startAngle: 0, endAngle: .pi * 2, clockwise: true)
            UIColor(red: 46 / 255, green: 139 / 255, blue: 255, alpha: 0.35).setStroke()
            bloom.lineWidth = 28
            bloom.stroke()
            let ring = UIBezierPath(arcCenter: center, radius: 118, startAngle: 0, endAngle: .pi * 2, clockwise: true)
            UIColor(red: 46 / 255, green: 139 / 255, blue: 255, alpha: 1).setStroke()
            ring.lineWidth = 10
            ring.stroke()
            let rim = UIBezierPath(arcCenter: center, radius: 96, startAngle: 0, endAngle: .pi * 2, clockwise: true)
            UIColor.white.withAlphaComponent(0.9).setStroke()
            rim.lineWidth = 3
            rim.stroke()
        }
    }
}

struct JarvisContactSheet: UIViewControllerRepresentable {
    var number: String
    @Environment(\.dismiss) private var dismiss

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIViewController(context: Context) -> UINavigationController {
        let editor = CNContactViewController(forNewContact: JarvisContactCard.make(number: number))
        editor.contactStore = CNContactStore()
        editor.delegate = context.coordinator
        editor.allowsActions = false
        return UINavigationController(rootViewController: editor)
    }

    func updateUIViewController(_ controller: UINavigationController, context: Context) {
        context.coordinator.dismiss = dismiss
    }

    final class Coordinator: NSObject, CNContactViewControllerDelegate {
        var dismiss: DismissAction?
        func contactViewController(_ viewController: CNContactViewController, didCompleteWith contact: CNContact?) {
            dismiss?()
        }
    }
}

/// The 6-digit code Sohail texts to the JARVIS number.
struct PairingCard: View {
    @Environment(AssistantEngine.self) private var engine
    @State private var showingContact = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("TEXT JARVIS")
                .font(.system(size: 11, weight: .semibold))
                .tracking(1.4)
                .foregroundStyle(Color(hex: "#2E8BFF"))
            Text(spaced(engine.pairCode))
                .font(.system(size: 32, weight: .semibold, design: .monospaced))
                .foregroundStyle(.white)
                .tracking(4)
            Text(instruction)
                .font(.system(size: 15))
                .foregroundStyle(Color(hex: "#C9C6D4"))
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                capsule("New code") { engine.refreshPairing() }
                if !engine.pairNumber.isEmpty {
                    capsule("Add to Contacts") { showingContact = true }
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(hex: "#0B1220").opacity(0.92), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(Color(hex: "#2E8BFF").opacity(0.45), lineWidth: 0.8))
        .sheet(isPresented: $showingContact) {
            JarvisContactSheet(number: engine.pairNumber)
        }
    }

    private var instruction: String {
        if engine.pairNumber.isEmpty {
            return "Text this code to the JARVIS number. He replies Connected, Sir."
        }
        return "Text this code to \(engine.pairNumber). He replies Connected, Sir."
    }

    private func capsule(_ title: String, action: @escaping () -> Void) -> some View {
        Button(title) {
            JarvisHaptics.tap()
            action()
        }
        .font(.system(size: 13, weight: .medium))
        .foregroundStyle(.white)
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(Color.white.opacity(0.06), in: Capsule())
        .buttonStyle(.plain)
    }

    private func spaced(_ code: String) -> String {
        let digits = code.filter(\.isNumber)
        guard digits.count == 6 else { return code }
        let mid = digits.index(digits.startIndex, offsetBy: 3)
        return "\(digits[..<mid]) \(digits[mid...])"
    }
}
