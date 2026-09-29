import SwiftUI

struct HomeView: View {
    @State private var showingSettings = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(verbatim: "DriveScope")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                Spacer()
                Button {
                    showingSettings = true
                } label: {
                    Image(systemName: "gearshape")
                        .font(.system(size: 20))
                        .foregroundStyle(Theme.textTertiary)
                        .frame(width: 44, height: 44)
                        .background(Theme.surface, in: Circle())
                }
                .accessibilityLabel("Settings")
                .accessibilityIdentifier("settingsButton")
            }
            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.top, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.background)
        .sheet(isPresented: $showingSettings) {
            SettingsView()
        }
    }
}
