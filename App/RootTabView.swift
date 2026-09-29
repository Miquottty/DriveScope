import SwiftUI

struct RootTabView: View {
    var body: some View {
        TabView {
            Tab("Record", systemImage: "record.circle") {
                HomeView()
            }
            Tab("Sessions", systemImage: "list.bullet.rectangle") {
                SessionsView()
            }
            Tab("Quality", systemImage: "waveform.path.ecg") {
                QualityView()
            }
        }
        .tint(Theme.accent)
    }
}
