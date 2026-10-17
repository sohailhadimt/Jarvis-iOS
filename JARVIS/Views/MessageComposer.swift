import MessageUI
import SwiftUI

/// Apple's message sheet with recipients and body prefilled. iOS requires the user to tap Send.
struct MessageComposer: UIViewControllerRepresentable {
    let draft: MessageDraft
    let onFinish: @MainActor () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onFinish: onFinish) }

    func makeUIViewController(context: Context) -> MFMessageComposeViewController {
        let vc = MFMessageComposeViewController()
        vc.recipients = draft.recipients
        vc.body = draft.body
        vc.messageComposeDelegate = context.coordinator
        return vc
    }

    func updateUIViewController(_ uiViewController: MFMessageComposeViewController, context: Context) {}

    final class Coordinator: NSObject, MFMessageComposeViewControllerDelegate {
        /// Created on the main actor so the nonisolated delegate callback can finish
        /// without sending `self` into a main-actor closure.
        private let finishOnMain: @Sendable () -> Void

        @MainActor
        init(onFinish: @escaping @MainActor () -> Void) {
            self.finishOnMain = { @Sendable in
                Task { @MainActor in onFinish() }
            }
        }

        nonisolated func messageComposeViewController(_ controller: MFMessageComposeViewController,
                                                      didFinishWith result: MessageComposeResult) {
            finishOnMain()
        }
    }
}

/// Apple's mail sheet. iOS requires the user to tap Send. JARVIS never sends the message itself.
struct MailComposer: UIViewControllerRepresentable {
    let draft: MailDraft
    let onFinish: @MainActor () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onFinish: onFinish) }

    func makeUIViewController(context: Context) -> MFMailComposeViewController {
        let vc = MFMailComposeViewController()
        vc.setToRecipients(draft.recipients)
        vc.setSubject(draft.subject)
        vc.setMessageBody(draft.body, isHTML: false)
        vc.mailComposeDelegate = context.coordinator
        return vc
    }

    func updateUIViewController(_ uiViewController: MFMailComposeViewController, context: Context) {}

    final class Coordinator: NSObject, MFMailComposeViewControllerDelegate {
        private let finishOnMain: @Sendable () -> Void

        @MainActor
        init(onFinish: @escaping @MainActor () -> Void) {
            self.finishOnMain = { @Sendable in
                Task { @MainActor in onFinish() }
            }
        }

        nonisolated func mailComposeController(_ controller: MFMailComposeViewController,
                                               didFinishWith result: MFMailComposeResult,
                                               error: Error?) {
            finishOnMain()
        }
    }
}
