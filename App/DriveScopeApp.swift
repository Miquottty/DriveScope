import SwiftData
import SwiftUI

@main
struct DriveScopeApp: App {
    @State private var appLanguage = AppLanguage()
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            RootTabView()
                .environment(appLanguage)
                .environment(model)
                .environment(model.recorder)
                .environment(model.battery)
                .modelContainer(model.container)
                .environment(\.locale, appLanguage.locale)
                .preferredColorScheme(.dark)
        }
    }
}
