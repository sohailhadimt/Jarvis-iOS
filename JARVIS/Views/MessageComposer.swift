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
