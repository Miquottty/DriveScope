import SwiftUI

/// iPad (regular × regular) gets its own split-view layout; iPhone in either orientation — and iPad in narrow
/// multitasking — the tab layout.
struct AdaptiveRootView: View {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @State private var locationPermission = LocationPermission()

    var body: some View {
        if LayoutClass.isPad(horizontalSizeClass, verticalSizeClass) {
            IPadRootView(permission: locationPermission)
        } else {
            RootTabView(permission: locationPermission)
        }
    }
}
