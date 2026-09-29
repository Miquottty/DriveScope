import SwiftUI

/// iPad (regular width) gets its own split-view layout; iPhone — and iPad in narrow multitasking — the tab layout.
struct AdaptiveRootView: View {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var locationPermission = LocationPermission()

    var body: some View {
        if horizontalSizeClass == .regular {
            IPadRootView(permission: locationPermission)
        } else {
            RootTabView(permission: locationPermission)
        }
    }
}
