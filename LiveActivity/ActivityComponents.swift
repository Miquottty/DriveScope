import AppIntents
import SwiftUI
import WidgetKit

typealias DriveActivityState = DriveActivityAttributes.ContentState

/// Text for the Live Activity. Digits are Latin in both languages (PLAN §13), so no locale is involved.
enum ActivityFormat {
    static let placeholder = "--"

    /// `hh:mm:ss`, for the frozen clock once recording has ended.
    static func elapsed(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        return String(format: "%02d:%02d:%02d", total / 3600, total / 60 % 60, total % 60)
    }

    static func speed(_ kmh: Double?) -> String {
        guard let kmh else { return placeholder }
        return String(Int(max(0, kmh).rounded()))
    }

    static func distance(_ km: Double) -> String {
        String(format: "%.1f", max(0, km))
    }

    static func accuracy(_ meters: Double?) -> String {
        guard let meters else { return placeholder }
        return "±\(Int(meters.rounded())) m"
    }

    /// "+0.21" / "−0.08" (typographic minus, as in the mock).
    static func signedG(_ g: Double) -> String {
        let rounded = (g * 100).rounded() / 100
        return (rounded < 0 ? "\u{2212}" : "+") + String(format: "%.2f", abs(rounded))
    }
}

extension DriveActivityState {
    /// GPS value text: "±3 m", or "--" while there is no fix.
    var gpsText: String {
        status == .gpsSearching ? ActivityFormat.placeholder : ActivityFormat.accuracy(gpsAccuracyM)
    }

    /// Same thresholds as the HUD's GPS badge: ≤ 10 m good, ≤ 30 m usable, worse or searching → red.
    var gpsColor: Color {
        if status == .gpsSearching { return WidgetTheme.rec }
        guard let gpsAccuracyM else { return WidgetTheme.textMuted }
        return gpsAccuracyM <= 10 ? WidgetTheme.good : gpsAccuracyM <= 30 ? WidgetTheme.accent : WidgetTheme.rec
    }

    var locale: Locale { Locale(identifier: languageCode) }

    /// Width a ticking clock of `font` points needs ("24:38" vs "1:24:38"). `Text(timerInterval:)` otherwise
    /// claims all the width it is offered.
    func clockWidth(fontSize: CGFloat) -> CGFloat {
        let characters: CGFloat = status.isLive ? (elapsed >= 3500 ? 7 : 5) : 8
        return ceil(characters * fontSize * 0.62)
    }
}

/// The red REC dot; muted while saving, green once saved.
struct StatusDot: View {
    let status: DriveActivityState.Status
    var size: CGFloat = 9
    var glow: CGFloat = 0

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: size, height: size)
            .shadow(color: glow > 0 ? color : .clear, radius: glow / 2)
    }

    private var color: Color {
        switch status {
        case .recording, .gpsSearching: WidgetTheme.rec
        case .saving, .interrupted: WidgetTheme.textMuted
        case .saved: WidgetTheme.good
        }
    }
}

/// "● REC  DriveScope" — the status word changes while saving / GPS searching.
struct StatusLabel: View {
    let state: DriveActivityState
    var dotSize: CGFloat = 9
    var fontSize: CGFloat = 12
    var spacing: CGFloat = 8
    var glow: CGFloat = 0
    /// StandBy sets the app name slightly smaller than the REC word (mock 9: 22 / 20 px).
    var detailScale: CGFloat = 1
    var showsDetail = true

    var body: some View {
        HStack(spacing: spacing) {
            StatusDot(status: state.status, size: dotSize, glow: glow)
            Text(verbatim: word)
                .font(.system(size: fontSize, weight: .semibold))
                .tracking(fontSize * 0.08)
                .foregroundStyle(wordColor)
            if showsDetail {
                Text(verbatim: detail)
                    .font(.system(size: fontSize * detailScale))
                    .foregroundStyle(state.status == .gpsSearching ? WidgetTheme.rec : WidgetTheme.textSecondary)
            }
        }
        .lineLimit(1)
        .accessibilityElement(children: .combine)
    }

    private var word: String {
        switch state.status {
        case .recording, .gpsSearching: "REC"
        case .saving: "SAVING"
        case .saved: "SAVED"
        case .interrupted: "NO DATA"
        }
    }

    private var wordColor: Color {
        switch state.status {
        case .recording, .gpsSearching: WidgetTheme.rec
        case .saving, .interrupted: WidgetTheme.textSecondary
        case .saved: WidgetTheme.good
        }
    }

    /// HUD wording stays English in both languages (as in the Recording HUD header).
    private var detail: String {
        state.status == .gpsSearching ? "GPS SEARCHING" : "DriveScope"
    }
}

/// Session clock: ticks on its own while recording, frozen afterwards.
struct ElapsedClock: View {
    let state: DriveActivityState
    let size: CGFloat
    var weight: Font.Weight = .medium
    var color: Color = WidgetTheme.textPrimary

    var body: some View {
        Group {
            if state.status.isLive {
                Text(timerInterval: state.timerStart...Date.distantFuture, countsDown: false)
            } else {
                Text(verbatim: ActivityFormat.elapsed(state.elapsed))
            }
        }
        .font(.hudNumber(size: size, weight: weight))
        .monospacedDigit()
        .foregroundStyle(color)
        .multilineTextAlignment(.trailing)
        .lineLimit(1)
        .frame(width: state.clockWidth(fontSize: size), alignment: .trailing)
    }
}

/// Caption over a value: "SPEED / 72 km/h". Labels are HUD abbreviations (English in both languages).
struct MetricColumn: View {
    let label: String
    let value: String
    var valueColor: Color = WidgetTheme.textPrimary
    var labelSize: CGFloat = 10
    var valueSize: CGFloat = 18
    var gap: CGFloat = 0

    var body: some View {
        VStack(alignment: .leading, spacing: gap) {
            Text(verbatim: label)
                .font(.system(size: labelSize))
                .tracking(labelSize * 0.1)
                .foregroundStyle(WidgetTheme.textSecondary)
            Text(verbatim: value)
                .font(.hudNumber(size: valueSize, weight: .medium))
                .foregroundStyle(valueColor)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .accessibilityElement(children: .combine)
    }
}

/// MARK (flag, dark) and STOP (red, white square) — `LiveActivityIntent`s run in the app process.
/// An interrupted activity keeps STOP only, which then opens the app (see below).
struct ActivityActionButtons: View {
    let state: DriveActivityState

    var body: some View {
        HStack(spacing: 8) {
            if state.status.isLive {
                Button(intent: MarkIntent()) {
                    Image(systemName: "flag")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(WidgetTheme.textPrimary)
                        .frame(width: 44, height: 44)
                        .background(WidgetTheme.dividerStrong, in: Circle())
                        .overlay(alignment: .topTrailing) { MarkCountBadge(count: state.markCount) }
                }
                .buttonStyle(.plain)
                // Apple Watch Double Tap (PLAN §10.1 W2).
                .handGestureShortcut(.primaryAction)
                .accessibilityLabel(Text("Add Marker"))
            }

            if state.status == .interrupted {
                // The process that owned this activity is gone, and iOS does not launch a force-quit app in the
                // background for an intent — StopRecordingIntent would do nothing. Opening the app does: launch
                // ends the leftover activity and offers the unfinished session for recovery.
                Link(destination: Self.openAppURL) { stopFace }
                    .accessibilityLabel(Text("Open DriveScope"))
            } else {
                Button(intent: StopRecordingIntent()) { stopFace }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text("Stop Recording"))
            }
        }
    }

    private static let openAppURL = URL(string: "drivescope://recovery")!

    private var stopFace: some View {
        RoundedRectangle(cornerRadius: 3)
            .fill(WidgetTheme.onRec)
            .frame(width: 14, height: 14)
            .frame(width: 44, height: 44)
            .background(WidgetTheme.rec, in: Circle())
    }

}

/// Confirms a MARK landed: the Live Activity is otherwise unchanged by it.
struct MarkCountBadge: View {
    let count: Int

    var body: some View {
        if count > 0 {
            Text(verbatim: "\(count)")
                .font(.hudNumber(size: 10, weight: .semibold))
                .foregroundStyle(WidgetTheme.hudBackground)
                .padding(.horizontal, 4)
                .frame(minWidth: 16, minHeight: 16)
                .background(WidgetTheme.accent, in: Capsule())
                .offset(x: 3, y: -3)
        }
    }
}
