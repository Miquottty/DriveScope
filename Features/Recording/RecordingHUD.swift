import DriveDomain
import DriveRecording
import SwiftUI

/// The Recording HUD layout, independent of `RecordingController` so it can be previewed with a fixed snapshot.
/// One view for both orientations (PLAN §11 rows 2 and 8): width > height → the 3-column landscape artboard,
/// otherwise the portrait artboard.
struct RecordingHUD: View {
    var snapshot: TelemetrySnapshot
    var preset: CapturePreset?
    /// `stopping` / `finalizing`: buttons are disabled and STOP shows progress.
    var isSaving = false
    var onMark: () async -> Void = {}
    var onSync: () async -> Void = {}
    var onStop: () async -> Void = {}

    var body: some View {
        GeometryReader { proxy in
            if proxy.size.width > proxy.size.height {
                landscape
            } else {
                portrait
            }
        }
        .background(Theme.hudBackground.ignoresSafeArea())
    }

    // MARK: - Portrait (artboard 2, 390×844)

    private var portrait: some View {
        VStack(spacing: 0) {
            header(presetLabel: nil)

            VStack(spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    speedText(size: 132, tracking: -0.04)
                    Text(verbatim: "km/h")
                        .font(.system(size: 20, weight: .medium))
                        .foregroundStyle(Theme.textSecondary)
                }
                caption("GPS SPEED", size: 12, color: Theme.textSecondary)
            }
            .padding(.top, 36)

            HStack(alignment: .top, spacing: 12) {
                altitude(.metric).frame(maxWidth: .infinity)
                course(.metric).frame(maxWidth: .infinity)
                distance(.metric).frame(maxWidth: .infinity)
            }
            .padding(.top, 30)

            gForces(style: .gForce, meterSize: 150, spacing: 28, valueSpacing: 14)
                .padding(.top, 28)

            Spacer(minLength: 16)

            HStack(spacing: 12) {
                markButton(height: 64)
                syncButton(height: 64)
            }
            Text("MARK = bookmark this moment · SYNC = clap / flash for camera sync")
                .font(.system(size: 11))
                .foregroundStyle(Theme.textMuted)
                .multilineTextAlignment(.center)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
                .padding(.top, 6)
            stopButton(height: 68, cornerRadius: 16, fontSize: 18, squareSize: 16)
                .padding(.top, 16)
        }
        .padding(.horizontal, 20)
        .padding(.top, 4)
    }

    // MARK: - Landscape (artboard 8, 844×390)

    private var landscape: some View {
        VStack(spacing: 10) {
            header(presetLabel: preset.map(HUDFormat.presetLabel))

            HStack(alignment: .center, spacing: 24) {
                VStack(alignment: .leading, spacing: 10) {
                    speedText(size: 150, tracking: -0.05)
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text(verbatim: "km/h")
                            .font(.system(size: 18, weight: .medium))
                            .foregroundStyle(Theme.textSecondary)
                        caption("GPS SPEED", size: 11, color: Theme.textMuted)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                // The meter column keeps its natural width; the outer columns share the rest equally, so it stays centered.
                gForces(style: .gForceLarge, meterSize: 170, spacing: 18, valueSpacing: 12)
                    .fixedSize()

                VStack(alignment: .trailing, spacing: 14) {
                    altitude(.metricLarge, alignment: .trailing)
                    course(.metricLarge, alignment: .trailing)
                    distance(.metricLarge, alignment: .trailing)
                }
                .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .frame(maxHeight: .infinity)

            // Mock grid: 1fr 1fr 2fr.
            GeometryReader { proxy in
                let unit = (proxy.size.width - 2 * 12) / 4
                HStack(spacing: 12) {
                    markButton(height: 56).frame(width: unit)
                    syncButton(height: 56).frame(width: unit)
                    stopButton(height: 56, cornerRadius: 14, fontSize: 17, squareSize: 14)
                }
            }
            .frame(height: 56)
        }
        .padding(.top, 18)
    }

    // MARK: - Pieces

    private func header(presetLabel: String?) -> some View {
        RecordingHeader(
            elapsed: snapshot.elapsed, gpsStatus: snapshot.gpsStatus,
            horizontalAccuracy: snapshot.horizontalAccuracy, presetLabel: presetLabel, isRecording: !isSaving)
    }

    private func speedText(size: CGFloat, tracking: CGFloat) -> some View {
        Text(verbatim: HUDFormat.speedKmh(snapshot.speed))
            .font(.hudNumber(size: size, weight: .medium))
            .tracking(size * tracking)
            .foregroundStyle(Theme.textPrimary)
            .lineLimit(1)
            .minimumScaleFactor(0.5)
            // The mock sets line-height 1 (0.9 landscape); SF Mono's line box has much more room above and
            // below the digits, which would push GPS SPEED and the rest of the HUD down.
            .padding(.top, -size * 0.09)
            .padding(.bottom, -size * 0.17)
            .accessibilityLabel(Text(verbatim: "\(HUDFormat.speedKmh(snapshot.speed)) km/h"))
            .accessibilityIdentifier("speedValue")
    }

    private func caption(_ text: String, size: CGFloat, color: Color) -> some View {
        Text(verbatim: text)
            .font(.system(size: size))
            .tracking(size * 0.1)
            .foregroundStyle(color)
    }

    private func altitude(_ style: TelemetryValue.Style, alignment: HorizontalAlignment = .center) -> some View {
        TelemetryValue(label: "ALT", value: HUDFormat.altitude(snapshot.altitude), unit: "m",
                       style: style, alignment: alignment)
    }

    private func course(_ style: TelemetryValue.Style, alignment: HorizontalAlignment = .center) -> some View {
        TelemetryValue(label: "COURSE", value: HUDFormat.course(snapshot.course),
                       unit: HUDFormat.courseUnit(snapshot.course), style: style, alignment: alignment)
    }

    private func distance(_ style: TelemetryValue.Style, alignment: HorizontalAlignment = .center) -> some View {
        TelemetryValue(label: "DIST", value: HUDFormat.distanceKm(snapshot.distance), unit: "km",
                       style: style, alignment: alignment)
    }

    private func gForces(
        style: TelemetryValue.Style, meterSize: CGFloat, spacing: CGFloat, valueSpacing: CGFloat
    ) -> some View {
        HStack(spacing: spacing) {
            VStack(alignment: .trailing, spacing: valueSpacing) {
                TelemetryValue(label: "LATERAL", value: HUDFormat.signedG(snapshot.lateralG), unit: "G",
                               style: style, valueColor: Theme.accent, alignment: .trailing)
                TelemetryValue(label: "LONG", value: HUDFormat.signedG(snapshot.longitudinalG), unit: "G",
                               style: style, alignment: .trailing)
            }
            .fixedSize()
            GMeterView(lateralG: snapshot.lateralG, longitudinalG: snapshot.longitudinalG)
                .frame(width: meterSize, height: meterSize)
        }
    }

    private func markButton(height: CGFloat) -> some View {
        HUDActionButton(title: "MARK", systemImage: "flag", height: height, isEnabled: !isSaving, action: onMark)
            .handGestureShortcut(.primaryAction)
            .accessibilityIdentifier("markButton")
    }

    private func syncButton(height: CGFloat) -> some View {
        HUDActionButton(title: "SYNC", systemImage: "bolt", height: height, isEnabled: !isSaving, action: onSync)
            .accessibilityIdentifier("syncButton")
    }

    private func stopButton(height: CGFloat, cornerRadius: CGFloat, fontSize: CGFloat, squareSize: CGFloat) -> some View {
        StopButton(height: height, cornerRadius: cornerRadius, fontSize: fontSize, squareSize: squareSize,
                   isSaving: isSaving, action: onStop)
            .accessibilityIdentifier("stopButton")
    }
}

#if DEBUG
private extension TelemetrySnapshot {
    /// The mock's dummy values (artboards 2 and 8).
    static var mock: TelemetrySnapshot {
        var snapshot = TelemetrySnapshot()
        snapshot.elapsed = 24 * 60 + 38
        snapshot.speed = 72 / 3.6
        snapshot.altitude = 684
        snapshot.course = 276
        snapshot.distance = 18_400
        snapshot.horizontalAccuracy = 3
        snapshot.gpsStatus = .good
        snapshot.lateralG = 0.21
        snapshot.longitudinalG = -0.08
        return snapshot
    }
}

#Preview("Portrait") {
    RecordingHUD(snapshot: .mock, preset: .logger)
}

#Preview("Landscape", traits: .landscapeLeft) {
    RecordingHUD(snapshot: .mock, preset: .logger)
}

#Preview("Acquiring") {
    RecordingHUD(snapshot: TelemetrySnapshot(), preset: .gpsOnly)
}

#Preview("Saving") {
    RecordingHUD(snapshot: .mock, preset: .logger, isSaving: true)
}
#endif
