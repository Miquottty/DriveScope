import SwiftUI

/// Apple Watch companion (PLAN §19 W3). The iPhone app does all the recording; the watch shows its state and sends
/// MARK / STOP over WatchConnectivity.
@main
struct DriveScopeWatchApp: App {
    var body: some Scene {
        WindowGroup {
            WatchHomeView()
        }
    }
}
