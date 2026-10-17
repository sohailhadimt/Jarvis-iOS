import SwiftData
import SwiftUI
import UIKit

@main
struct JARVISApp: App {
    @UIApplicationDelegateAdaptor(JarvisPush.self) private var push
    @State private var engine = AssistantEngine.shared
    @State private var settings = AppSettings.shared

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(engine)
                .environment(settings)
        }
        .modelContainer(JarvisStore.container)
    }
}
