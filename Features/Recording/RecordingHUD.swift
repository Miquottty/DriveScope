import DriveDomain
import DriveRecording
import SwiftUI

/// The Recording HUD layout, independent of `RecordingController` so it can be previewed with a fixed snapshot.
/// One view for both orientations (PLAN §11 rows 2 and 8): width > height → the 3-column landscape artboard,
/// otherwise the portrait artboard. iPad-sized windows get `RecordingHUDIPadLayout` (artboards 12 and 16).
struct RecordingHUD: View {
    var snapshot: TelemetrySnapshot
    var preset: CapturePreset?
    /// `stopping` / `finalizing`: buttons are disabled and STOP shows progress.
    var isSaving = false
    var onMark: () async -> Void = {}
    var onSync: () async -> Void = {}
    var onStop: () async -> Void = {}
    /// Manual "rotate 90°" when the auto calibration picked the wrong axis (PLAN §7-4).
    var onRotateMount: () async -> Void = {}
    /// Unplugged and < 20 %: suggest a lighter preset for the next session (PLAN §2.2.1 — never switch mid-session).
    var batteryLow = false

    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.verticalSizeClass) private var verticalSizeClass

    var body: some View {
        // Regular × regular is an iPad-sized window. A Plus / Max iPhone in landscape is regular × compact and keeps
        // the phone artboard.
        if horizontalSizeClass == .regular, verticalSizeClass == .regular {
            RecordingHUDIPadLayout(
                snapshot: snapshot, preset: preset, isSaving: isSaving, onMark: onMark, onSync: onSync,
                onStop: onStop, onRotateMount: onRotateMount, batteryLow: batteryLow)
        } else {
            phone
        }
    }

    private var phone: some View {
        GeometryReader { proxy in
            if proxy.size.width > proxy.size.height {
                landscape(size: proxy.size)
            } else {
                portrait(size: proxy.size)
            }
        }
        .background(Theme.hudBackground.ignoresSafeArea())
        .overlay(alignment: .top) {
            if batteryLow {
                Text("Low battery — consider Eco or GPS Only next time")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.accent)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(Theme.surface, in: Capsule())
                    .padding(.top, 52)
            }
        }
    }

    // MARK: - Portrait (artboard 2, 390×844; 2c 440×956)

    /// Read from the mount while driving: speed first, then REC time, then G. Nothing is sized for one screen — the
    /// speed follows the width (three digits and km/h always fit) and the G meter takes whatever height is left,
    /// so a Pro Max gets a bigger meter instead of an empty band above the buttons.
    private func portrait(size: CGSize) -> some View {
        let speedSize = min(180, (size.width - 40 - 60) / 1.8, size.height * 0.215)
        return VStack(spacing: 0) {
            header(presetLabel: nil, style: .phoneLarge)

            VStack(spacing: 8) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    speedText(size: speedSize, tracking: -0.04)
                    Text(verbatim: "km/h")
                        .font(.system(size: 22, weight: .medium))
                        .foregroundStyle(Theme.textSecondary)
                }
                caption("GPS SPEED", size: 12, color: Theme.textSecondary)
            }
            .padding(.top, 18)

            metricRow
                .padding(.top, 22)

            HStack(spacing: 12) {
                TelemetryValue(label: "LATERAL", value: HUDFormat.signedG(snapshot.lateralG), unit: "G",
                               style: .gForceStacked, valueColor: Theme.accent)
                    .frame(maxWidth: .infinity)
                TelemetryValue(label: "LONG", value: HUDFormat.signedG(snapshot.longitudinalG), unit: "G",
                               style: .gForceStacked)
                    .frame(maxWidth: .infinity)
            }
            .padding(.top, 18)

            // Fixed-size dot and a "1.0 G" label (the iPad drawing): scaled with the meter, the dot would balloon.
            GMeterView(lateralG: snapshot.lateralG, longitudinalG: snapshot.longitudinalG,
                       style: .pad(dotRadius: 10, labelSize: 12))
                .frame(maxWidth: .infinity, minHeight: 120, maxHeight: .infinity)
                .overlay(alignment: .bottomTrailing) {
                    calibrationControl.padding(.bottom, 4)
                }
                .padding(.top, 8)

            HStack(spacing: 12) {
                markButton(height: 64)
                syncButton(height: 64)
            }
            .padding(.top, 12)
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

    // MARK: - Landscape (artboard 8, 844×390; 8b 956×440)

    /// Same priorities as portrait: the metrics move to one line under the header, leaving two columns laid on the
    /// buttons' 1:1:2 grid — speed centered over MARK + SYNC, G over STOP. Speed and meter follow the space.
    private func landscape(size: CGSize) -> some View {
        VStack(spacing: 0) {
            header(presetLabel: preset.map(HUDFormat.presetLabel), style: .phoneLarge)
            metricRow
                .padding(.top, 8)

            GeometryReader { proxy in
                let unit = (proxy.size.width - 2 * 12) / 4
                let speedWidth = 2 * unit + 12
                // Three digits must fit the column; the digits plus the km/h row must fit the height.
                let speedSize = min(240, speedWidth / 1.8, (proxy.size.height - 36) / 0.74)
                HStack(spacing: 12) {
                    VStack(spacing: 10) {
                        speedText(size: speedSize, tracking: -0.04)
                        HStack(alignment: .firstTextBaseline, spacing: 12) {
                            Text(verbatim: "km/h")
                                .font(.system(size: 22, weight: .medium))
                                .foregroundStyle(Theme.textSecondary)
                            caption("GPS SPEED", size: 12, color: Theme.textSecondary)
                        }
                    }
                    .frame(width: speedWidth)

                    HStack(spacing: 20) {
                        VStack(alignment: .trailing, spacing: 12) {
                            TelemetryValue(label: "LATERAL", value: HUDFormat.signedG(snapshot.lateralG), unit: "G",
                                           style: .gForceStacked, valueColor: Theme.accent, alignment: .trailing)
                            TelemetryValue(label: "LONG", value: HUDFormat.signedG(snapshot.longitudinalG), unit: "G",
                                           style: .gForceStacked, alignment: .trailing)
                            calibrationControl
                        }
                        .fixedSize()
                        GMeterView(lateralG: snapshot.lateralG, longitudinalG: snapshot.longitudinalG,
                                   style: .pad(dotRadius: 10, labelSize: 12))
                    }
                    .frame(width: 2 * unit)
                }
                .frame(maxHeight: .infinity)
            }
            .padding(.top, 10)

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
            .padding(.top, 10)
        }
        .padding(.top, 10)
    }

    // MARK: - Pieces

    private func header(presetLabel: String?, style: RecordingHeader.Style = .phone) -> some View {
        RecordingHeader(
            elapsed: snapshot.elapsed, gpsStatus: snapshot.gpsStatus,
            horizontalAccuracy: snapshot.horizontalAccuracy, presetLabel: presetLabel, isRecording: !isSaving,
            style: style)
    }

    private func speedText(size: CGFloat, tracking: CGFloat) -> some View {
        Text(verbatim: HUDFormat.speedKmh(snapshot.speed))
            .font(.hudNumber(size: size, weight: .medium))
            .tracking(size * tracking)
            .foregroundStyle(Theme.textPrimary)
            .lineLimit(1)
            .minimumScaleFactor(0.5)
            // The mock sets line-height ~0.8; SF Mono's line box has much more room above and below the digits,
            // which would push GPS SPEED and the rest of the HUD down.
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

    /// ALT / COURSE / DIST on one line between hairlines.
    private var metricRow: some View {
        HStack(alignment: .firstTextBaseline) {
            InlineTelemetryValue(label: "ALT", value: HUDFormat.altitude(snapshot.altitude), unit: "m")
            Spacer(minLength: 8)
            InlineTelemetryValue(label: "COURSE", value: HUDFormat.course(snapshot.course),
                                 unit: HUDFormat.courseUnit(snapshot.course))
            Spacer(minLength: 8)
            InlineTelemetryValue(label: "DIST", value: HUDFormat.distanceKm(snapshot.distance), unit: "km")
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 2)
        .overlay(alignment: .top) { Theme.divider.frame(height: 1) }
        .overlay(alignment: .bottom) { Theme.divider.frame(height: 1) }
    }

    /// "GPS EST." until the mount is calibrated (lateral g from GPS only); then "CAL" with the 90° correction.
    @ViewBuilder private var calibrationControl: some View {
        if snapshot.isCalibrated {
            Button {
                Task { await onRotateMount() }
            } label: {
                Label {
                    Text(verbatim: "CAL · 90°")
                } icon: {
                    Image(systemName: "rotate.right")
                }
                .font(.hudNumber(size: 11, weight: .medium))
                .foregroundStyle(Theme.textSecondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .overlay(Capsule().stroke(Theme.dividerStrong))
            }
            .buttonStyle(.plain)
            .disabled(isSaving)
            .accessibilityLabel(Text("Rotate mount 90°"))
            .accessibilityIdentifier("rotateMountButton")
        } else {
            Text(verbatim: "GPS EST.")
                .font(.hudNumber(size: 11, weight: .medium))
                .foregroundStyle(Theme.textMuted)
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

#Preview("Portrait · 188 km/h, Pro Max size", traits: .fixedLayout(width: 440, height: 860)) {
    var fast = TelemetrySnapshot.mock
    fast.speed = 188 / 3.6
    return RecordingHUD(snapshot: fast, preset: .logger)
}

#Preview("Portrait · small phone", traits: .fixedLayout(width: 375, height: 647)) {
    RecordingHUD(snapshot: .mock, preset: .logger)
}

#Preview("Acquiring") {
    RecordingHUD(snapshot: TelemetrySnapshot(), preset: .gpsOnly)
}

#Preview("Saving") {
    RecordingHUD(snapshot: .mock, preset: .logger, isSaving: true)
}

#Preview("iPad landscape", traits: .fixedLayout(width: 1210, height: 834)) {
    RecordingHUD(snapshot: .mock, preset: .logger)
        .environment(\.horizontalSizeClass, .regular)
        .environment(\.verticalSizeClass, .regular)
}

#Preview("iPad portrait", traits: .fixedLayout(width: 834, height: 1210)) {
    RecordingHUD(snapshot: .mock, preset: .logger, batteryLow: true)
        .environment(\.horizontalSizeClass, .regular)
        .environment(\.verticalSizeClass, .regular)
}
#endif
