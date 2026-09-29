import DriveRecording
import SwiftUI

/// Top row of the HUD: pulsing REC dot, elapsed time, and the GPS badge (mock artboards 2 and 8).
struct RecordingHeader: View {
    var elapsed: TimeInterval
    var gpsStatus: TelemetrySnapshot.GPSStatus
    var horizontalAccuracy: Double?
    /// "50 Hz · Logger" — landscape only in the mock.
    var presetLabel: String?
    var isRecording = true
    var style = Style.phone

    struct Style {
        var dotSize: CGFloat = 10
        var recSize: CGFloat = 13
        var recTracking: CGFloat = 1.3
        var elapsedSize: CGFloat = 20
        var elapsedLeading: CGFloat = 6
        var leadingSpacing: CGFloat = 8
        var trailingSpacing: CGFloat = 14
        var presetSize: CGFloat = 12
        var presetColor = Theme.textSecondary
        /// iPad: the preset sits in a surface chip like the GPS badge.
        var presetIsChip = false
        var badge = HUDGPSBadge.Style()

        static let phone = Style()
        /// Mock artboards 12 / 16: 30 pt elapsed, 16 pt preset chip, 18 pt GPS chip.
        static let pad = Style(
            dotSize: 14, recSize: 18, recTracking: 18 * 0.12, elapsedSize: 30, elapsedLeading: 8, leadingSpacing: 12,
            trailingSpacing: 10, presetSize: 16, presetColor: Theme.textTertiary, presetIsChip: true,
            badge: HUDGPSBadge.Style(
                iconSize: 18, textSize: 18, spacing: 8, verticalPadding: 8, horizontalPadding: 14, cornerRadius: 10))
    }

    var body: some View {
        HStack {
            HStack(spacing: style.leadingSpacing) {
                RecDot(isPulsing: isRecording, size: style.dotSize)
                Text(verbatim: "REC")
                    .font(.system(size: style.recSize, weight: .semibold))
                    .tracking(style.recTracking)
                    .foregroundStyle(Theme.rec)
                Text(verbatim: HUDFormat.elapsed(elapsed))
                    .font(.hudNumber(size: style.elapsedSize, weight: .medium))
                    .foregroundStyle(Theme.textPrimary)
                    .padding(.leading, style.elapsedLeading)
            }
            .accessibilityElement(children: .combine)
            Spacer(minLength: 8)
            HStack(spacing: style.trailingSpacing) {
                if let presetLabel {
                    Text(verbatim: presetLabel)
                        .font(.hudNumber(size: style.presetSize))
                        .foregroundStyle(style.presetColor)
                        .padding(.vertical, style.presetIsChip ? style.badge.verticalPadding : 0)
                        .padding(.horizontal, style.presetIsChip ? style.badge.horizontalPadding : 0)
                        .background(style.presetIsChip ? Theme.surface : .clear,
                                    in: RoundedRectangle(cornerRadius: style.badge.cornerRadius))
                }
                HUDGPSBadge(quality: GPSQuality(status: gpsStatus, accuracy: horizontalAccuracy),
                            accuracy: horizontalAccuracy, style: style.badge)
            }
        }
        .lineLimit(1)
    }
}

private struct RecDot: View {
    var isPulsing: Bool
    var size: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let dot = Circle()
            .fill(Theme.rec)
            .frame(width: size, height: size)
            .shadow(color: Theme.rec, radius: size / 2)
        if isPulsing, !reduceMotion {
            dot.phaseAnimator([1.0, 0.3]) { view, opacity in
                view.opacity(opacity)
            } animation: { _ in
                .easeInOut(duration: 0.8)
            }
        } else {
            dot.opacity(isPulsing ? 1 : 0.4)
        }
    }
}

struct HUDGPSBadge: View {
    struct Style {
        var iconSize: CGFloat = 11
        var textSize: CGFloat = 13
        var spacing: CGFloat = 6
        var verticalPadding: CGFloat = 5
        var horizontalPadding: CGFloat = 9
        var cornerRadius: CGFloat = 8
    }

    var quality: GPSQuality
    var accuracy: Double?
    var style = Style()

    var body: some View {
        HStack(spacing: style.spacing) {
            Image(systemName: "scope")
                .font(.system(size: style.iconSize, weight: .semibold))
            Text(verbatim: text)
                .font(.hudNumber(size: style.textSize, weight: .medium))
        }
        .foregroundStyle(color)
        .padding(.vertical, style.verticalPadding)
        .padding(.horizontal, style.horizontalPadding)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: style.cornerRadius))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(verbatim: "GPS \(text)"))
    }

    private var text: String {
        switch quality {
        case .acquiring: "ACQUIRING"
        case .searching: "GPS SEARCHING"
        case .good, .fair, .poor:
            accuracy.map { "±\(Int($0.rounded())) m" } ?? HUDFormat.placeholder
        }
    }

    private var color: Color {
        switch quality {
        case .good: Theme.good
        case .fair, .acquiring: Theme.accent
        case .poor, .searching: Theme.rec
        }
    }
}
