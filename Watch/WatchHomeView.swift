import SwiftUI

/// The watch's one screen. Until the iPhone reports its state, it only says it is waiting.
struct WatchHomeView: View {
    var body: some View {
        VStack(spacing: 8) {
            Circle()
                .fill(WatchTheme.textMuted)
                .frame(width: 10, height: 10)
            Text(verbatim: "DriveScope")
                .font(.headline)
                .foregroundStyle(WatchTheme.textPrimary)
            Text("Waiting for iPhone")
                .font(.footnote)
                .foregroundStyle(WatchTheme.textSecondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(WatchTheme.hudBackground)
    }
}
