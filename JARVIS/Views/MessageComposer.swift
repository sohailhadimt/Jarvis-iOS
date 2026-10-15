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
        let onFinish: @MainActor () -> Void
        init(onFinish: @escaping @MainActor () -> Void) { self.onFinish = onFinish }

        nonisolated func messageComposeViewController(_ controller: MFMessageComposeViewController,
                                                      didFinishWith result: MessageComposeResult) {
            MainActor.assumeIsolated { onFinish() }
        }
    }
}
