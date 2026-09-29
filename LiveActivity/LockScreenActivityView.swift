import AppIntents
import SwiftUI
import WidgetKit

/// The non–Dynamic Island presentation: Lock Screen / banner (mock 6), StandBy (mock 9) and the `.small` family
/// used by the CarPlay Dashboard and the Apple Watch Smart Stack (mock 10, right).
struct LockScreenActivityView: View {
    let state: DriveActivityState

    @Environment(\.activityFamily) private var family
    @Environment(\.isActivityFullscreen) private var isFullscreen

    var body: some View {
        Group {
            if family == .small {
                SmallActivityView(state: state)
                    .activityBackgroundTint(WidgetTheme.hudBackground)
            } else if isFullscreen {
                StandByActivityView(state: state)
                    .activityBackgroundTint(WidgetTheme.hudBackground)
            } else {
                LockScreenCard(state: state)
                    // Mock 6 draws the card in the surface color; StandBy / small / the island are true black.
                    .activityBackgroundTint(WidgetTheme.surface)
            }
        }
        .activitySystemActionForegroundColor(WidgetTheme.textPrimary)
        .environment(\.locale, state.locale)
    }
}

/// Mock 6: header (REC · DriveScope · clock) over SPEED / DIST / GPS and the MARK / STOP buttons.
private struct LockScreenCard: View {
    let state: DriveActivityState

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                StatusLabel(state: state)
                Spacer(minLength: 8)
                ElapsedClock(state: state, size: 22)
            }
            HStack {
                HStack(spacing: 18) {
                    MetricColumn(label: "SPEED", value: "\(ActivityFormat.speed(state.speedKmh)) km/h")
                    MetricColumn(label: "DIST", value: "\(ActivityFormat.distance(state.distanceKm)) km")
                    MetricColumn(label: "GPS", value: state.gpsText, valueColor: state.gpsColor)
                }
                .opacity(state.status == .interrupted ? 0.45 : 1)
                Spacer(minLength: 8)
                if state.status.isLive || state.status == .interrupted {
                    ActivityActionButtons(state: state)
                } else {
                    // Keeps the card height when the buttons go away.
                    Color.clear.frame(width: 1, height: 44)
                }
            }
        }
        .padding(.vertical, 14)
        .padding(.horizontal, 16)
    }
}

/// Mock 9 is the Lock Screen view as StandBy shows it, scaled 200 % by the system — so every size here is half
/// the mock's. Glanceable only: no buttons.
private struct StandByActivityView: View {
    let state: DriveActivityState

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                StatusLabel(state: state, dotSize: 9, fontSize: 11, spacing: 7, glow: 7, detailScale: 10 / 11)
                Spacer(minLength: 8)
                ElapsedClock(state: state, size: 22)
            }
            HStack(alignment: .bottom) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(verbatim: ActivityFormat.speed(state.speedKmh))
                        .font(.hudNumber(size: 48, weight: .medium))
                        .tracking(-48 * 0.04)
                        .foregroundStyle(WidgetTheme.textPrimary)
                    Text(verbatim: "km/h")
                        .font(.system(size: 12))
                        .foregroundStyle(WidgetTheme.textSecondary)
                }
                .lineLimit(1)
                Spacer(minLength: 8)
                HStack(spacing: 18) {
                    MetricColumn(label: "DIST", value: "\(ActivityFormat.distance(state.distanceKm)) km", labelSize: 8, valueSize: 18, gap: 2)
                    MetricColumn(label: "LAT G", value: ActivityFormat.signedG(state.lateralG), valueColor: WidgetTheme.accent, labelSize: 8, valueSize: 18, gap: 2)
                    MetricColumn(label: "GPS", value: state.gpsText, valueColor: state.gpsColor, labelSize: 8, valueSize: 18, gap: 2)
                }
            }
            .opacity(state.status == .interrupted ? 0.45 : 1)
        }
        .padding(.vertical, 14)
        .padding(.horizontal, 16)
        .background(WidgetTheme.background, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).stroke(WidgetTheme.surface, lineWidth: 0.5))
    }
}

/// Mock 10 (right): REC + clock, the speed large, distance and GPS at the foot.
/// The Watch Smart Stack gives this family a card only ~80 pt tall (measured on a 45 mm Series 9), so the three rows
/// are sized to fit ~76 pt; at the mock's 52 pt speed the header and footer were clipped by the card.
struct SmallActivityView: View {
    let state: DriveActivityState

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                StatusLabel(state: state, dotSize: 7, fontSize: 10, spacing: 5, showsDetail: false)
                Spacer(minLength: 4)
                ElapsedClock(state: state, size: 11, weight: .regular, color: WidgetTheme.textSecondary)
            }
            Spacer(minLength: 0)
            HStack(alignment: .center, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(verbatim: ActivityFormat.speed(state.speedKmh))
                        .font(.hudNumber(size: 28, weight: .medium))
                        .tracking(-28 * 0.03)
                        .foregroundStyle(WidgetTheme.textPrimary)
                        .minimumScaleFactor(0.6)
                    Text(verbatim: "km/h")
                        .font(.system(size: 10))
                        .foregroundStyle(WidgetTheme.textSecondary)
                }
                Spacer(minLength: 4)
                if state.status.isLive {
                    // The Watch Smart Stack draws this family: Double Tap needs a primary action here (PLAN §10.1 W2).
                    Button(intent: MarkIntent()) {
                        Image(systemName: "flag")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(WidgetTheme.textPrimary)
                            .frame(width: 28, height: 28)
                            .background(WidgetTheme.dividerStrong, in: Circle())
                            // The Watch shows nothing else when a Double Tap lands.
                            .overlay(alignment: .topTrailing) { MarkCountBadge(count: state.markCount) }
                    }
                    .buttonStyle(.plain)
                    .handGestureShortcut(.primaryAction)
                    .accessibilityLabel(Text("Add Marker"))
                }
            }
            .lineLimit(1)
            Spacer(minLength: 0)
            HStack {
                Text(verbatim: "\(ActivityFormat.distance(state.distanceKm)) km")
                    .foregroundStyle(WidgetTheme.textTertiary)
                Spacer(minLength: 4)
                Text(verbatim: state.gpsText)
                    .foregroundStyle(state.gpsColor)
            }
            .font(.hudNumber(size: 11))
            .lineLimit(1)
        }
        .opacity(state.status == .interrupted ? 0.6 : 1)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}
