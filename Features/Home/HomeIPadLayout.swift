import CoreMotion
import DriveDomain
import DriveRecording
import DriveStorage
import SwiftUI
import UIKit

/// Record dashboard on iPad (mock 11): START card with inline preset pills beside a 2×3 sensor tile grid, and the
/// three most recent drives. `HomeView` owns the start flow and its state; this view only lays it out.
struct HomeIPadLayout: View {
    let permission: LocationPermission
    @Binding var presetRaw: String
    let canStart: Bool
    let issue: HomeView.StartIssue?
    let isLowPowerMode: Bool
    /// Battery percent while the low-battery suggestion applies (PLAN §2.2.1), else nil.
    let batterySuggestionPercent: Int?
    let recent: [DriveSession]
    let onStart: () -> Void
    let onDismissBatterySuggestion: () -> Void
    let onOpenSession: (UUID) -> Void
    let onShowAllSessions: () -> Void

    @Environment(AppModel.self) private var model
    @Environment(RecordingController.self) private var recorder
    @Environment(AppLanguage.self) private var appLanguage
    @Environment(BatteryMonitor.self) private var battery
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openURL) private var openURL
    /// Free space for new recordings; nil until measured.
    @State private var availableBytes: Int64?

    /// Content width below which the START card stacks above the tiles (portrait with the sidebar open).
    private static let sideBySideMinWidth: CGFloat = 760
    private static let rowSpacing: CGFloat = 20

    private var preset: CapturePreset { CapturePreset(rawValue: presetRaw) ?? .default }
    private var isSimulated: Bool { model.sensorEnvironment.source != .device }
    private var needsPermission: Bool { model.sensorEnvironment.needsLocationPermission }
    private var locale: Locale { appLanguage.locale }

    var body: some View {
        GeometryReader { geometry in
            let contentWidth = geometry.size.width - 2 * IPadMetrics.margin
            let wide = contentWidth >= Self.sideBySideMinWidth
            ScrollView {
                VStack(alignment: .leading, spacing: IPadMetrics.gap) {
                    header
                    if let percent = batterySuggestionPercent {
                        batterySuggestion(percent)
                            .transition(.opacity)
                    }
                    if wide {
                        HStack(alignment: .top, spacing: Self.rowSpacing) {
                            startCard(fillHeight: true)
                            sensorColumn
                                .frame(width: (contentWidth - Self.rowSpacing) / 2.05)
                        }
                        .frame(maxHeight: .infinity)
                    } else {
                        startCard(fillHeight: false)
                        sensorColumn
                    }
                    recentSection(wide: wide)
                }
                .padding(.horizontal, IPadMetrics.margin)
                .padding(.top, 8)
                .padding(.bottom, 24)
                // Fill the screen so the START card stretches and RECENT sits at the bottom, as in the mock.
                .frame(minHeight: geometry.size.height, alignment: .top)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .background(Theme.background)
        .task(id: StorageRefresh(phase: recorder.phase, scene: scenePhase)) {
            availableBytes = await Self.availableCapacity()
        }
    }

    // MARK: Header

    private var header: some View {
        let title = Text("Record")
            .font(.system(size: 34, weight: .semibold))
            .foregroundStyle(Theme.textPrimary)
        let hint = Text("Mount the iPhone or iPad, then START. Forward is found on the first acceleration.")
            .font(.system(size: 15))
            .foregroundStyle(Theme.textTertiary)
        return ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline, spacing: 16) {
                title
                Spacer(minLength: 16)
                hint.lineLimit(1)
            }
            VStack(alignment: .leading, spacing: 6) {
                title
                hint.fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: START and preset

    private func startCard(fillHeight: Bool) -> some View {
        VStack(spacing: 22) {
            startButton
            presetPicker
            if let issue {
                issueCard(issue)
            } else if let error = recorder.lastError {
                Text(verbatim: error)
                    .font(.system(size: 15))
                    .foregroundStyle(Theme.rec)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: fillHeight ? .infinity : nil)
        .padding(IPadMetrics.cardPadding)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: IPadMetrics.cardRadius))
    }

    private var startButton: some View {
        Button(action: onStart) {
            VStack(spacing: 2) {
                // English in every language, like the HUD's MARK / SYNC / STOP.
                Text(verbatim: "START")
                    .font(.system(size: 52, weight: .semibold))
                    .tracking(2.1)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                Text("Record drive")
                    .font(.system(size: 17, weight: .medium))
            }
            .foregroundStyle(Theme.background)
            .padding(.horizontal, 24)
            .frame(width: 260, height: 260)
            .background(Theme.accent, in: Circle())
            .padding(16)
            .background(Theme.accentHalo, in: Circle())
            .contentShape(.interaction, Circle())
            .contentShape(.hoverEffect, Circle())
            .hoverEffect(.lift)
        }
        .buttonStyle(.plain)
        .disabled(!canStart)
        .opacity(canStart ? 1 : 0.4)
        .accessibilityLabel("Start recording")
        .accessibilityIdentifier("startButton")
    }

    private var presetPicker: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Capture preset").iPadLabel()
            HStack(spacing: 8) {
                ForEach(CapturePreset.allCases) { option in
                    presetPill(option)
                }
            }
            Text(verbatim: costLine)
                .font(.system(size: 14))
                .foregroundStyle(Theme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func presetPill(_ option: CapturePreset) -> some View {
        let selected = option == preset
        let shape = RoundedRectangle(cornerRadius: 12)
        return Button {
            withAnimation(.snappy) { presetRaw = option.rawValue }
        } label: {
            VStack(spacing: 1) {
                Text(verbatim: option.displayName)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                Text(verbatim: Self.rateText(option))
                    .font(.hudNumber(size: 12))
                    .foregroundStyle(Theme.textTertiary)
            }
            .lineLimit(1)
            .minimumScaleFactor(0.75)
            .padding(.horizontal, 4)
            .frame(maxWidth: .infinity, minHeight: IPadMetrics.minTouch)
            .background(selected ? Theme.accentFill : Theme.panel, in: shape)
            .overlay(shape.strokeBorder(selected ? Theme.accent : Theme.dividerStrong, lineWidth: selected ? 2 : 1.5))
            .contentShape(shape)
            .cardHoverEffect(cornerRadius: 12)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("preset-\(option.rawValue)")
    }

    /// GPS Only records location at 1 Hz; the others are named by their motion rate.
    private static func rateText(_ preset: CapturePreset) -> String {
        let hz = Int(preset.motion.hz)
        return hz > 0 ? "\(hz) Hz" : "1 Hz"
    }

    /// "Logger · 50 Hz device motion · ≈ 14 MB/h · screen off ≈ 2.5–3 %/h"
    private var costLine: String {
        let hz = Int(preset.motion.hz)
        let motion = switch preset.motion {
        case .deviceMotion: appLanguage.string("\(hz) Hz device motion")
        case .accelerometer: appLanguage.string("\(hz) Hz accelerometer")
        case .none: appLanguage.string("GPS 1 Hz, no motion")
        }
        let megabytes = Double(preset.estimatedBytesPerHour) / 1_000_000
        let size = megabytes.formatted(.number.precision(.fractionLength(megabytes >= 10 ? 0 : 1)).locale(locale))
            + "\u{00A0}" + UnitInformationStorage.megabytes.symbol
        let drain = preset.estimatedScreenOffDrain
        let style = FloatingPointFormatStyle<Double>.number.precision(.fractionLength(0...1)).locale(locale)
        let range = "\(drain.lowerBound.formatted(style))–\(drain.upperBound.formatted(style))"
        return [
            preset.displayName, motion, "≈ " + appLanguage.string("\(size)/h"),
            appLanguage.string("screen off ≈ \(range) %/h"),
        ].joined(separator: " · ")
    }

    private func issueCard(_ issue: HomeView.StartIssue) -> some View {
        VStack(spacing: 6) {
            switch issue {
            case .denied:
                Text("Location access is off. DriveScope needs it to record your route and speed.")
            case .imprecise:
                Text("Precise Location is off. Turn it on for DriveScope to record an accurate route.")
            }
            Button("Open Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
            }
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(Theme.accent)
            .frame(minHeight: IPadMetrics.minTouch)
            .accessibilityIdentifier("openSettingsButton")
        }
        .font(.system(size: 15))
        .foregroundStyle(Theme.textTertiary)
        .multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .frame(maxWidth: .infinity)
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: 12))
    }

    // MARK: Sensor status

    private var sensorColumn: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Sensor Status").iPadLabel()
            Grid(horizontalSpacing: 12, verticalSpacing: 12) {
                GridRow {
                    gpsTile
                    motionTile
                }
                GridRow {
                    barometerTile
                    powerTile
                }
                GridRow {
                    backgroundTile
                    storageTile
                }
            }
            if isLowPowerMode {
                Label("Low Power Mode is on. GPS updates may be reduced; charge or turn it off for long drives.", systemImage: "bolt.badge.exclamationmark")
                    .font(.system(size: 15))
                    .foregroundStyle(Theme.accent)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("sensorStatus")
    }

    private var gpsTile: some View {
        let precise = permission.isPrecise
        let detail: Text = precise ? Text("Precise · full accuracy") : Text("Approximate")
        let tile: (value: Text, tint: Color, detail: Text)
        if !needsPermission {
            tile = (Text("Simulated"), Theme.good, Text("Scripted drive"))
        } else {
            switch permission.authorizationStatus {
            case .authorizedWhenInUse, .authorizedAlways:
                tile = (Text("Ready"), precise ? Theme.good : Theme.accent, detail)
            case .denied:
                tile = (Text("Denied"), Theme.rec, Text("Location off"))
            case .restricted:
                tile = (Text("Restricted"), Theme.rec, Text("Location off"))
            default:
                tile = (Text("Not asked"), Theme.textPrimary, Text("Asked on START"))
            }
        }
        return SensorTile(label: Text(verbatim: "GPS"), value: tile.value, tint: tile.tint, detail: tile.detail)
    }

    private var motionTile: some View {
        let hz = Int(preset.motion.hz)
        let detail: Text = switch preset.motion {
        case .deviceMotion: Text("Device motion")
        case .accelerometer: Text("Accelerometer only")
        case .none: Text("Not recorded")
        }
        return SensorTile(
            label: Text("Motion"), value: hz > 0 ? Text(verbatim: "\(hz) Hz") : Text("Off"), detail: detail
        )
    }

    private var barometerTile: some View {
        let available = CMAltimeter.isRelativeAltitudeAvailable()
        let value: Text = isSimulated ? Text("Simulated") : (available ? Text("Available") : Text("Unavailable"))
        return SensorTile(
            label: Text("Barometer"), value: value,
            detail: available || isSimulated ? Text("Relative altitude") : Text("Altitude from GPS")
        )
    }

    private var powerTile: some View {
        let level = battery.level.map { "\(Int(($0 * 100).rounded())) %" } ?? "—"
        let detail: Text? = if isLowPowerMode {
            Text("Low Power Mode")
        } else {
            switch battery.state {
            case .charging: Text("Charging")
            case .full: Text("Full")
            case .unplugged: Text("On battery")
            default: nil
            }
        }
        return SensorTile(
            label: Text("Power"), value: Text(verbatim: level), tint: battery.isLow ? Theme.accent : Theme.textPrimary,
            detail: detail
        )
    }

    private var backgroundTile: some View {
        let tile: (value: Text, tint: Color, detail: Text)
        if !permission.backgroundAvailable {
            tile = (Text("Off"), Theme.rec, Text("Not configured"))
        } else if !needsPermission {
            tile = (Text("OK"), Theme.good, Text("Simulated"))
        } else {
            switch permission.authorizationStatus {
            case .authorizedAlways: tile = (Text("OK"), Theme.good, Text("Always · location"))
            case .authorizedWhenInUse: tile = (Text("OK"), Theme.good, Text("While Using · location"))
            case .denied, .restricted: tile = (Text("Off"), Theme.rec, Text("Location off"))
            default: tile = (Text(verbatim: "—"), Theme.textPrimary, Text("Asked on START"))
            }
        }
        return SensorTile(label: Text("Background"), value: tile.value, tint: tile.tint, detail: tile.detail)
    }

    private var storageTile: some View {
        let value = availableBytes.map(storageText) ?? "—"
        let detail: Text
        if let availableBytes, preset.estimatedBytesPerHour > 0 {
            let hours = Double(availableBytes) / Double(preset.estimatedBytesPerHour)
            let hoursText = hours.formatted(.number.precision(.significantDigits(2)).locale(locale))
            detail = Text("free · ≈ \(hoursText) h \(preset.displayName)")
        } else {
            detail = Text("free")
        }
        return SensorTile(label: Text("Storage"), value: Text(verbatim: value), detail: detail)
    }

    /// "41 GB", "8.5 GB", "730 MB" (decimal units, like the Files app).
    private func storageText(_ bytes: Int64) -> String {
        let gigabytes = Double(bytes) / 1_000_000_000
        if gigabytes >= 1 {
            return gigabytes.formatted(.number.precision(.fractionLength(gigabytes >= 10 ? 0 : 1)).locale(locale))
                + "\u{00A0}" + UnitInformationStorage.gigabytes.symbol
        }
        let megabytes = Double(bytes) / 1_000_000
        return megabytes.formatted(.number.precision(.fractionLength(0)).locale(locale))
            + "\u{00A0}" + UnitInformationStorage.megabytes.symbol
    }

    private struct StorageRefresh: Equatable {
        var phase: RecorderPhase
        var scene: ScenePhase
    }

    /// `volumeAvailableCapacityForImportantUsage` asks the system about purgeable space and can take a while.
    @concurrent nonisolated private static func availableCapacity() async -> Int64? {
        let values = try? URL.homeDirectory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
    }

    // MARK: Low battery

    private func batterySuggestion(_ percent: Int) -> some View {
        let icon = Image(systemName: "battery.25percent")
            .font(.system(size: 24))
            .foregroundStyle(Theme.accent)
        let message = Text("Battery \(percent)% — switch to Eco or GPS Only?")
            .font(.system(size: 16, weight: .semibold))
            .foregroundStyle(Theme.textPrimary)
        let dismiss = Button(action: onDismissBatterySuggestion) {
            Image(systemName: "xmark")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Theme.textTertiary)
                .frame(width: IPadMetrics.minTouch, height: IPadMetrics.minTouch)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Dismiss")
        .accessibilityIdentifier("dismissBatterySuggestionButton")
        // One row when it fits; otherwise the choices wrap under the message (portrait with the sidebar open).
        return ViewThatFits(in: .horizontal) {
            HStack(spacing: 16) {
                icon
                message
                Spacer(minLength: 8)
                suggestionOption(.eco, id: "suggestEcoButton")
                suggestionOption(.gpsOnly, id: "suggestGPSOnlyButton")
                dismiss
            }
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 16) {
                    icon
                    message.fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 8)
                    dismiss
                }
                HStack(spacing: 12) {
                    suggestionOption(.eco, id: "suggestEcoButton")
                    suggestionOption(.gpsOnly, id: "suggestGPSOnlyButton")
                }
            }
        }
        .padding(.leading, IPadMetrics.cardPadding)
        .padding(.trailing, 8)
        .padding(.vertical, 8)
        .background(Theme.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: IPadMetrics.cardRadius))
        .overlay(RoundedRectangle(cornerRadius: IPadMetrics.cardRadius).strokeBorder(Theme.accent.opacity(0.35)))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("batterySuggestion")
    }

    private func suggestionOption(_ option: CapturePreset, id: String) -> some View {
        Button {
            withAnimation { presetRaw = option.rawValue }
        } label: {
            Text(verbatim: option.displayName)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Theme.accent)
                .padding(.horizontal, 20)
                .frame(minHeight: 44)
                .background(Theme.accent.opacity(0.16), in: Capsule())
                .contentShape(Capsule())
                .frame(minHeight: IPadMetrics.minTouch)
                .contentShape(.hoverEffect, Capsule())
                .hoverEffect(.highlight)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(id)
    }

    // MARK: Recent

    @ViewBuilder private func recentSection(wide: Bool) -> some View {
        if !recent.isEmpty {
            let format = SessionFormat(language: appLanguage)
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text("Recent").iPadLabel()
                    Spacer()
                    Button("All sessions", action: onShowAllSessions)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Theme.accent)
                        .frame(minHeight: IPadMetrics.minTouch)
                        .accessibilityIdentifier("allSessionsButton")
                }
                let layout = wide ? AnyLayout(HStackLayout(spacing: 16)) : AnyLayout(VStackLayout(spacing: 12))
                layout {
                    ForEach(recent) { session in
                        recentCard(session, format)
                    }
                    // Keep the three-column rhythm with fewer than three drives.
                    if wide {
                        ForEach(recent.count..<3, id: \.self) { _ in
                            Color.clear.frame(maxWidth: .infinity, maxHeight: 0)
                        }
                    }
                }
            }
        }
    }

    private func recentCard(_ session: DriveSession, _ format: SessionFormat) -> some View {
        Button {
            onOpenSession(session.id)
        } label: {
            HStack(spacing: 14) {
                IPadRouteThumbnail(
                    points: session.routePreview, size: CGSize(width: 88, height: 68), dashed: session.state == .recovered
                )
                VStack(alignment: .leading, spacing: 4) {
                    Text(verbatim: format.title(session))
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary)
                    Text(verbatim: "\(format.duration(session.duration)) · \(format.distance(meters: session.distance).text)")
                        .font(.hudNumber(size: 14))
                        .foregroundStyle(Theme.textTertiary)
                        .minimumScaleFactor(0.8)
                    Text(verbatim: format.shortDate(session))
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.textSecondary)
                }
                .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: IPadMetrics.cardRadius))
            .contentShape(RoundedRectangle(cornerRadius: IPadMetrics.cardRadius))
            .cardHoverEffect()
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("recentSession")
    }
}

/// One sensor tile: 13 pt caps label, 30 pt mono value, 14 pt detail (mock 11).
private struct SensorTile: View {
    let label: Text
    let value: Text
    var tint = Theme.textPrimary
    let detail: Text?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            label.iPadLabel()
            value
                .font(.hudNumber(size: 30, weight: .medium))
                .foregroundStyle(tint)
                .minimumScaleFactor(0.6)
            (detail ?? Text(verbatim: " "))
                .font(.system(size: 14))
                .foregroundStyle(Theme.textTertiary)
                .minimumScaleFactor(0.8)
        }
        .lineLimit(1)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 16)
        .padding(.horizontal, 18)
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: IPadMetrics.tileRadius))
        .overlay(RoundedRectangle(cornerRadius: IPadMetrics.tileRadius).strokeBorder(Theme.divider))
        .accessibilityElement(children: .combine)
    }
}
