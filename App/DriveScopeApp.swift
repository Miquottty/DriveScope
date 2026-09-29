import SwiftUI

@main
struct DriveScopeApp: App {
    @State private var appLanguage = AppLanguage()

    var body: some Scene {
        WindowGroup {
            RootTabView()
                .environment(appLanguage)
                .environment(\.locale, appLanguage.locale)
                .preferredColorScheme(.dark)
        }
    }
}
