import SwiftUI

/// The watch's one screen (PLAN §19 W3). Recording: REC + clock, speed, a large MARK (Double Tap), STOP behind a
/// confirmation. Otherwise the iPhone's status. HUD words (REC, MARK, STOP, km/h) stay English as on the iPhone.
struct WatchHomeView: View {
    @State private var link = WatchLinkModel()
    @State private var confirmingStop = false

    var body: some View {
        Group {
            if let state = link.state, state.phase != .idle {
                recording(state)
            } else {
                idle
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(WatchTheme.hudBackground)
        .environment(\.locale, Locale(identifier: link.state?.languageCode ?? Locale.current.identifier))
        .sensoryFeedback(.success, trigger: link.acknowledged)
        .sensoryFeedback(.error, trigger: link.failed)
        .confirmationDialog("Stop recording?", isPresented: $confirmingStop) {
            Button("Stop", role: .destructive) { link.send(.stop) }
        }
    }

    private var idle: some View {
        VStack(spacing: 8) {
            Circle()
                .fill(WatchTheme.textMuted)
                .frame(width: 10, height: 10)
            Text(verbatim: "DriveScope")
                .font(.headline)
                .foregroundStyle(WatchTheme.textPrimary)
            Text(link.state == nil ? "Waiting for iPhone" : "Not recording")
                .font(.footnote)
                .foregroundStyle(WatchTheme.textSecondary)
                .multilineTextAlignment(.center)
        }
    }

    private func recording(_ state: WatchState) -> some View {
        let live = state.phase == .recording
        return VStack(spacing: 6) {
            HStack(spacing: 5) {
                Circle()
                    .fill(live ? WatchTheme.rec : WatchTheme.textMuted)
                    .frame(width: 7, height: 7)
                Text(verbatim: live ? (state.gpsSearching ? "GPS" : "REC") : "SAVING")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(live ? WatchTheme.rec : WatchTheme.textSecondary)
                Spacer(minLength: 4)
                if live {
                    Text(timerInterval: state.timerStart...Date.distantFuture, countsDown: false)
                        .font(.hudNumber(size: 13))
                        .foregroundStyle(WatchTheme.textSecondary)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 60, alignment: .trailing)
                }
            }
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(verbatim: state.speedKmh.map { String(Int($0)) } ?? "--")
                    .font(.hudNumber(size: 38, weight: .medium))
                    .foregroundStyle(WatchTheme.textPrimary)
                    .minimumScaleFactor(0.6)
                Text(verbatim: "km/h")
                    .font(.system(size: 11))
                    .foregroundStyle(WatchTheme.textSecondary)
                Spacer(minLength: 0)
            }
            .lineLimit(1)
            if live {
                markButton(state)
                Button {
                    confirmingStop = true
                } label: {
                    Text(verbatim: "STOP")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(WatchTheme.onRec)
                        .frame(maxWidth: .infinity, minHeight: 30)
                        .background(WatchTheme.rec, in: Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("Stop Recording"))
            }
        }
        .padding(.horizontal, 4)
    }

    private func markButton(_ state: WatchState) -> some View {
        Button {
            link.send(.mark)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "flag.fill")
                Text(verbatim: "MARK")
                if state.markCount > 0 {
                    Text(verbatim: "\(state.markCount)")
                        .font(.hudNumber(size: 12, weight: .semibold))
                        .foregroundStyle(WatchTheme.hudBackground)
                        .padding(.horizontal, 5)
                        .frame(minWidth: 18, minHeight: 18)
                        .background(WatchTheme.accent, in: Capsule())
                }
            }
            .font(.system(size: 17, weight: .semibold))
            .foregroundStyle(WatchTheme.textPrimary)
            .frame(maxWidth: .infinity, minHeight: 48)
            .background(WatchTheme.dividerStrong, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .opacity(link.isReachable && !link.markInFlight ? 1 : 0.55)
        }
        .buttonStyle(.plain)
        // Double Tap with the hand on the wheel (PLAN §10.1 W2 / §19 W3).
        .handGestureShortcut(.primaryAction)
        .accessibilityLabel(Text("Add Marker"))
    }
}
