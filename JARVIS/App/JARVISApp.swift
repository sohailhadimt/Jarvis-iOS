import SwiftData
import SwiftUI
import UIKit

@main
struct JARVISApp: App {
    @UIApplicationDelegateAdaptor(JarvisPush.self) private var push
    @State private var engine = AssistantEngine.shared
    @State private var settings = AppSettings.shared

    init() {
        UIWindow.appearance().backgroundColor = UIColor(red: 5 / 255, green: 8 / 255, blue: 15 / 255, alpha: 1)
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(engine)
                .environment(settings)
        }
        .modelContainer(JarvisStore.container)
    }
}
