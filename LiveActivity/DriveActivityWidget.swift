import ActivityKit
import SwiftUI
import WidgetKit

/// Live Activity for a running recording (PLAN §10, mock 6 / 9 / 10).
struct DriveActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: DriveActivityAttributes.self) { context in
            LockScreenActivityView(state: context.state, isStale: context.isStale)
        } dynamicIsland: { context in
            let state = context.state
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    StatusLabel(state: state, fontSize: 11)
                        .padding(.leading, 6)
                        .frame(maxHeight: .infinity)
                        .environment(\.locale, state.locale)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    ElapsedClock(state: state, size: 20)
                        .padding(.trailing, 6)
                        .frame(maxHeight: .infinity)
                        .environment(\.locale, state.locale)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    ExpandedBottomRow(state: state, isStale: context.isStale)
                        .environment(\.locale, state.locale)
                }
            } compactLeading: {
                CompactLeading(state: state)
            } compactTrailing: {
                CompactTrailing(state: state)
            } minimal: {
                StatusDot(status: state.status, size: 8)
            }
            .keylineTint(WidgetTheme.rec)
        }
        .supplementalActivityFamilies([.small])
    }
}

/// Mock 10 (expanded): speed large, DIST / GPS, MARK / STOP.
private struct ExpandedBottomRow: View {
    let state: DriveActivityState
    let isStale: Bool

    var body: some View {
        HStack(alignment: .bottom) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(verbatim: ActivityFormat.speed(state.speedKmh))
                    .font(.hudNumber(size: 40, weight: .medium))
                    .foregroundStyle(WidgetTheme.textPrimary)
                Text(verbatim: "km/h")
                    .font(.system(size: 12))
                    .foregroundStyle(WidgetTheme.textSecondary)
            }
            .lineLimit(1)
            .opacity(isStale && state.status.isLive ? 0.45 : 1)
            Spacer(minLength: 6)
            HStack(spacing: 16) {
                MetricColumn(label: "DIST", value: "\(ActivityFormat.distance(state.distanceKm)) km", labelSize: 9, valueSize: 15)
                MetricColumn(label: "GPS", value: state.gpsText, valueColor: state.gpsColor, labelSize: 9, valueSize: 15)
            }
            .opacity(isStale && state.status.isLive ? 0.45 : 1)
            Spacer(minLength: 6)
            if state.status.isLive {
                ActivityActionButtons(markCount: state.markCount)
            }
        }
        .padding(.horizontal, 6)
        .padding(.top, 4)
    }
}

/// "● REC"; landscape (limited width) degrades to the dot alone (PLAN §10).
private struct CompactLeading: View {
    let state: DriveActivityState
    @Environment(\.isDynamicIslandLimitedInWidth) private var isLimitedInWidth

    var body: some View {
        if isLimitedInWidth {
            StatusDot(status: state.status, size: 8)
        } else {
            StatusLabel(state: state, dotSize: 8, fontSize: 10, spacing: 6, showsDetail: false)
        }
    }
}

/// Clock; landscape (limited width) shows the speed instead.
private struct CompactTrailing: View {
    let state: DriveActivityState
    @Environment(\.isDynamicIslandLimitedInWidth) private var isLimitedInWidth

    var body: some View {
        if isLimitedInWidth {
            Text(verbatim: ActivityFormat.speed(state.speedKmh))
                .font(.hudNumber(size: 13, weight: .medium))
                .foregroundStyle(WidgetTheme.good)
        } else {
            ElapsedClock(state: state, size: 13)
        }
    }
}
