import SwiftUI
import WidgetKit

@main
struct JARVISWidgetsBundle: WidgetBundle {
    var body: some Widget {
        JarvisLiveActivity()
        JarvisStandByWidget()
        if #available(iOS 18.0, *) {
            JarvisTalkControl()
            JarvisControl()
        }
    }
}
