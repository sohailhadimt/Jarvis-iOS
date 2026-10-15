import SwiftData
import SwiftUI

@main
struct JARVISApp: App {
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
