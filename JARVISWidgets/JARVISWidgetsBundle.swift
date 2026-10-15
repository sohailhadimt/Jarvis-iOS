import SwiftUI
import WidgetKit

@main
struct JARVISWidgetsBundle: WidgetBundle {
    var body: some Widget {
        JarvisLiveActivity()
        JarvisStandByWidget()
        JarvisControl()
    }
}
