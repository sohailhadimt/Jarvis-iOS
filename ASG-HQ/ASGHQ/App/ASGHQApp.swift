import SwiftUI
import UIKit

final class HQAppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        .landscape
    }
}

@main
struct ASGHQApp: App {
    @UIApplicationDelegateAdaptor(HQAppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            RootView()
                .preferredColorScheme(.dark)
                .statusBarHidden(true)
        }
    }
}

struct RootView: View {
    @StateObject private var session = HQSession()

    var body: some View {
        Group {
            if session.onboarded {
                GameScreen(session: session)
            } else {
                OnboardingView(session: session)
            }
        }
        .background(HQTheme.navy.ignoresSafeArea())
    }
}
