import ActivityKit
import SwiftUI
import WidgetKit

struct DriveActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: DriveActivityAttributes.self) { context in
            Text("REC")
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.center) { Text("REC") }
            } compactLeading: {
                Text("REC")
            } compactTrailing: {
                Text("--")
            } minimal: {
                Text("R")
            }
        }
    }
}
