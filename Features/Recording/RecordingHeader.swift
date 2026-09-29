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

    var body: some View {
        HStack {
            HStack(spacing: 8) {
                RecDot(isPulsing: isRecording)
                Text(verbatim: "REC")
                    .font(.system(size: 13, weight: .semibold))
                    .tracking(1.3)
                    .foregroundStyle(Theme.rec)
                Text(verbatim: HUDFormat.elapsed(elapsed))
                    .font(.hudNumber(size: 20, weight: .medium))
                    .foregroundStyle(Theme.textPrimary)
                    .padding(.leading, 6)
            }
            .accessibilityElement(children: .combine)
            Spacer(minLength: 8)
            HStack(spacing: 14) {
                if let presetLabel {
                    Text(verbatim: presetLabel)
                        .font(.hudNumber(size: 12))
                        .foregroundStyle(Theme.textSecondary)
                }
                GPSBadge(quality: GPSQuality(status: gpsStatus, accuracy: horizontalAccuracy),
                         accuracy: horizontalAccuracy)
            }
        }
        .lineLimit(1)
    }
}

private struct RecDot: View {
    var isPulsing: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let dot = Circle()
            .fill(Theme.rec)
            .frame(width: 10, height: 10)
            .shadow(color: Theme.rec, radius: 5)
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

private struct GPSBadge: View {
    var quality: GPSQuality
    var accuracy: Double?

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "scope")
                .font(.system(size: 11, weight: .semibold))
            Text(verbatim: text)
                .font(.hudNumber(size: 13, weight: .medium))
        }
        .foregroundStyle(color)
        .padding(.vertical, 5)
        .padding(.horizontal, 9)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 8))
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
