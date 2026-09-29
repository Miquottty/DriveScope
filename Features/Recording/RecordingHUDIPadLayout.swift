import DriveDomain
import DriveRecording
import SwiftUI

/// iPad Recording HUD (mock artboards 12 landscape, 16 portrait): one hero speed, three large tiles, the G section
/// and 92 / 100 pt buttons with M / S keyboard keys. Like the phone HUD, width > height picks the landscape
/// arrangement. Sizes are the mock's points on an 11" iPad (safe area 1210 × 790 / 834 × 1166); smaller windows
/// (iPad mini, Stage Manager) scale uniformly down, larger screens keep the mock sizes and gain space.
struct RecordingHUDIPadLayout: View {
    var snapshot: TelemetrySnapshot
    var preset: CapturePreset?
    var isSaving: Bool
    var onMark: () async -> Void
    var onSync: () async -> Void
    var onStop: () async -> Void
    var onRotateMount: () async -> Void
    var batteryLow: Bool

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            if size.width > size.height {
                landscape(scale: min(1.2, size.width / 1210, size.height / 790), width: size.width)
            } else {
                portrait(scale: min(1.2, size.width / 834, size.height / 1166), width: size.width)
            }
        }
        .background(Theme.hudBackground.ignoresSafeArea())
        // Keeps first responder inside the HUD (not in the sidebar behind the cover), so the M / S shortcuts
        // resolve against this screen.
        .background(alignment: .topLeading) {
            KeyCommandResponder()
                .frame(width: 1, height: 1)
                .accessibilityHidden(true)
        }
    }

    // MARK: - Landscape (artboard 12)

    private func landscape(scale s: CGFloat, width: CGFloat) -> some View {
        VStack(spacing: 22 * s) {
            header(scale: s)
            HStack(alignment: .center, spacing: 28 * s) {
                VStack(alignment: .leading, spacing: 26 * s) {
                    HStack(alignment: .firstTextBaseline, spacing: 14 * s) {
                        speedText(size: 260 * s)
                        VStack(alignment: .leading, spacing: 6 * s) {
                            unitText(size: 32 * s)
                            caption("GPS SPEED", scale: s)
                        }
                    }
                    tiles(scale: s)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                // The meter column keeps its natural width (≈ 506 pt); the speed column takes the rest.
                gSection(meterSize: 320 * s, spacing: 26 * s, scale: s)
                    .fixedSize()
            }
            .frame(maxHeight: .infinity)
            buttons(height: 92 * s, rowWidth: width - 2 * 36 * s, scale: s)
        }
        .padding(.horizontal, 36 * s)
        .padding(.top, 4 * s)
        .padding(.bottom, 10 * s)
    }

    // MARK: - Portrait (artboard 16)

    private func portrait(scale s: CGFloat, width: CGFloat) -> some View {
        VStack(spacing: 30 * s) {
            header(scale: s)
            VStack(spacing: 4 * s) {
                HStack(alignment: .firstTextBaseline, spacing: 14 * s) {
                    speedText(size: 280 * s)
                    unitText(size: 34 * s)
                }
                caption("GPS SPEED", scale: s)
            }
            .padding(.top, 12 * s)
            tiles(scale: s)
            gSection(meterSize: 340 * s, spacing: 40 * s, scale: s)
                .frame(maxHeight: .infinity)
            buttons(height: 100 * s, rowWidth: width - 2 * 36 * s, scale: s)
        }
        .padding(.horizontal, 36 * s)
        .padding(.top, 16 * s)
        .padding(.bottom, 16 * s)
    }

    // MARK: - Pieces

    private func header(scale s: CGFloat) -> some View {
        VStack(spacing: 12 * s) {
            RecordingHeader(
                elapsed: snapshot.elapsed, gpsStatus: snapshot.gpsStatus,
                horizontalAccuracy: snapshot.horizontalAccuracy, presetLabel: preset.map(HUDFormat.presetChip),
                isRecording: !isSaving, style: .pad)
            if batteryLow {
                // Unplugged and < 20 %: suggest a lighter preset for the next session (PLAN §2.2.1).
                Text("Low battery — consider Eco or GPS Only next time")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(Theme.accent)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
                    .background(Theme.surface, in: Capsule())
            }
        }
    }

    private func speedText(size: CGFloat) -> some View {
        Text(verbatim: HUDFormat.speedKmh(snapshot.speed))
            .font(.hudNumber(size: size, weight: .medium))
            .tracking(size * -0.05)
            .foregroundStyle(Theme.textPrimary)
            .lineLimit(1)
            .minimumScaleFactor(0.5)
            // Mock line-height 0.9: trim SF Mono's taller line box so the tiles sit where the artboard has them.
            .padding(.top, -size * 0.09)
            .padding(.bottom, -size * 0.17)
            .accessibilityLabel(Text(verbatim: "\(HUDFormat.speedKmh(snapshot.speed)) km/h"))
            .accessibilityIdentifier("speedValue")
    }

    private func unitText(size: CGFloat) -> some View {
        Text(verbatim: "km/h")
            .font(.system(size: size, weight: .medium))
            .foregroundStyle(Theme.textTertiary)
    }

    private func caption(_ text: String, scale s: CGFloat) -> some View {
        Text(verbatim: text)
            .font(.system(size: 15 * s, weight: .semibold))
            .tracking(15 * s * 0.1)
            .foregroundStyle(Theme.textSecondary)
    }

    private func tiles(scale s: CGFloat) -> some View {
        HStack(spacing: 14 * s) {
            tile("ALT", HUDFormat.altitude(snapshot.altitude), unit: "m", scale: s)
            tile("COURSE", HUDFormat.course(snapshot.course), unit: HUDFormat.courseUnit(snapshot.course), scale: s)
            tile("DIST", HUDFormat.distanceKm(snapshot.distance), unit: "km", scale: s)
        }
    }

    private func tile(_ label: String, _ value: String, unit: String, scale s: CGFloat) -> some View {
        let shape = RoundedRectangle(cornerRadius: 16 * s)
        return TelemetryValue(label: label, value: value, unit: unit, style: .padTile.scaled(s), alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 16 * s)
            .padding(.horizontal, 20 * s)
            .background(HUDButtonStyle.fill, in: shape)
            .overlay(shape.strokeBorder(Theme.divider, lineWidth: 1.5))
    }

    private func gSection(meterSize: CGFloat, spacing: CGFloat, scale s: CGFloat) -> some View {
        HStack(spacing: spacing) {
            VStack(alignment: .trailing, spacing: 18 * s) {
                TelemetryValue(label: "LATERAL", value: HUDFormat.signedG(snapshot.lateralG), unit: "G",
                               style: .padGForce.scaled(s), valueColor: Theme.accent, alignment: .trailing)
                TelemetryValue(label: "LONG", value: HUDFormat.signedG(snapshot.longitudinalG), unit: "G",
                               style: .padGForce.scaled(s), alignment: .trailing)
                calibrationControl
            }
            .fixedSize()
            GMeterView(lateralG: snapshot.lateralG, longitudinalG: snapshot.longitudinalG,
                       style: .pad(dotRadius: meterSize / 28, labelSize: 15))
                .frame(width: meterSize, height: meterSize)
        }
    }

    /// "GPS EST." until the mount is calibrated (lateral g from GPS only); then "CAL · 90°", which rotates the
    /// calibration by 90° when the auto calibration picked the wrong axis (PLAN §7-4).
    @ViewBuilder private var calibrationControl: some View {
        if snapshot.isCalibrated {
            Button {
                Task { await onRotateMount() }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "rotate.right")
                        .font(.system(size: 15, weight: .medium))
                    Text(verbatim: "CAL · 90°")
                        .font(.hudNumber(size: 14))
                }
                .foregroundStyle(Theme.textTertiary)
                .padding(.horizontal, 14)
                .frame(height: 40)
                .overlay(Capsule().strokeBorder(Theme.dividerStrong, lineWidth: 1.5))
                // 40 pt visible, 52 pt to the finger.
                .contentShape(Capsule().inset(by: -6))
            }
            .buttonStyle(HUDButtonStyle())
            .disabled(isSaving)
            .accessibilityLabel(Text("Rotate mount 90°"))
            .accessibilityIdentifier("rotateMountButton")
        } else {
            Text(verbatim: "GPS EST.")
                .font(.hudNumber(size: 14, weight: .medium))
                .foregroundStyle(Theme.textSecondary)
                .frame(height: 40)
        }
    }

    /// Mock: MARK 1 : SYNC 1 : STOP 1.6. STOP has no keyboard key — it only stops on a deliberate hold.
    private func buttons(height: CGFloat, rowWidth: CGFloat, scale s: CGFloat) -> some View {
        let spacing = 16 * s
        let unit = max(0, rowWidth - 2 * spacing) / 3.6
        return HStack(spacing: spacing) {
            HUDActionButton(title: "MARK", systemImage: "flag", height: height, isEnabled: !isSaving,
                            metrics: .pad, key: "m", action: onMark)
                .handGestureShortcut(.primaryAction)
                .accessibilityIdentifier("markButton")
                .frame(width: unit)
            HUDActionButton(title: "SYNC", systemImage: "bolt", height: height, isEnabled: !isSaving,
                            metrics: .pad, key: "s", action: onSync)
                .accessibilityIdentifier("syncButton")
                .frame(width: unit)
            StopButton(height: height, cornerRadius: 18, fontSize: 24, squareSize: 20, squareRadius: 4,
                       isSaving: isSaving, caption: "HOLD 0.8 s", action: onStop)
                .accessibilityIdentifier("stopButton")
        }
    }
}

private extension TelemetryValue.Style {
    /// Uniformly smaller for windows below the 11" artboard.
    func scaled(_ s: CGFloat) -> Self {
        guard s < 1 else { return self }
        var style = self
        style.valueSize *= s
        style.unitSize *= s
        style.unitGap *= s
        style.labelSize *= s
        style.spacing *= s
        return style
    }
}
