import CoreLocation
import CoreMotion
import DriveDomain
import DriveRecording
import DriveStorage
import SwiftData
import SwiftUI
import UIKit

struct HomeView: View {
    let permission: LocationPermission
    var onOpenSession: (UUID) -> Void = { _ in }
    var onShowAllSessions: () -> Void = {}

    @Environment(AppModel.self) private var model
    @Environment(RecordingController.self) private var recorder
    @Environment(AppLanguage.self) private var appLanguage
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openURL) private var openURL
    @AppStorage("capturePreset") private var presetRaw = CapturePreset.default.rawValue
    @Query(HomeView.recentDescriptor) private var recent: [DriveSession]

    @State private var showingSettings = false
    @State private var power = PowerStatus.read()
    @State private var isStarting = false
    @State private var issue: StartIssue?

    private static var recentDescriptor: FetchDescriptor<DriveSession> {
        var descriptor = FetchDescriptor<DriveSession>(sortBy: [SortDescriptor(\.startedAt, order: .reverse)])
        descriptor.fetchLimit = 3
        return descriptor
    }

    private enum StartIssue {
        case denied
        case imprecise
    }

    private var preset: CapturePreset { CapturePreset(rawValue: presetRaw) ?? .default }
    private var isSimulated: Bool { model.sensorEnvironment.source != .device }
    private var needsPermission: Bool { model.sensorEnvironment.needsLocationPermission }

    /// PLAN §9.2: START is not possible from the background.
    private var canStart: Bool {
        scenePhase == .active && !isStarting && (recorder.phase == .idle || recorder.phase == .stopped)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                header
                sensorStatus.padding(.top, 22)
                startArea
                recentSessions
            }
            .padding(.horizontal, 20)
            .padding(.top, 8)
        }
        .scrollBounceBehavior(.basedOnSize)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.background)
        .sheet(isPresented: $showingSettings) {
            SettingsView()
        }
        .task {
            UIDevice.current.isBatteryMonitoringEnabled = true
            power = PowerStatus.read()
        }
        .onReceive(NotificationCenter.default.publisher(for: UIDevice.batteryLevelDidChangeNotification)) { _ in
            power = PowerStatus.read()
        }
        .onReceive(NotificationCenter.default.publisher(for: UIDevice.batteryStateDidChangeNotification)) { _ in
            power = PowerStatus.read()
        }
        .onReceive(NotificationCenter.default.publisher(for: .NSProcessInfoPowerStateDidChange)) { _ in
            power = PowerStatus.read()
        }
        .onChange(of: permission.canRecord) { _, allowed in
            if allowed, issue == .denied { issue = nil }
        }
        .onChange(of: permission.isPrecise) { _, precise in
            if precise, issue == .imprecise { issue = nil }
        }
    }

    // MARK: Header

    private var header: some View {
        HStack {
            Text(verbatim: "DriveScope")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
            Spacer()
            Button {
                showingSettings = true
            } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 20))
                    .foregroundStyle(Theme.textTertiary)
                    .frame(width: 44, height: 44)
                    .background(Theme.surface, in: Circle())
            }
            .accessibilityLabel("Settings")
            .accessibilityIdentifier("settingsButton")
        }
    }

    // MARK: Sensor status

    private var sensorStatus: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Sensor Status")
                .font(.system(size: 12, weight: .medium))
                .tracking(0.96)
                .textCase(.uppercase)
                .foregroundStyle(Theme.textSecondary)
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 10) {
                GridRow {
                    gpsCell
                    motionCell
                }
                GridRow {
                    barometerCell
                    powerCell
                }
            }
            Divider().overlay(Theme.divider)
            HStack {
                Text("Background location")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textSecondary)
                Spacer()
                let background = backgroundStatus
                Text(background.text)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(background.tint)
            }
            if power.isLowPower {
                Label("Low Power Mode is on. GPS updates may be reduced; charge or turn it off for long drives.", systemImage: "bolt.badge.exclamationmark")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.accent)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 16))
        .accessibilityIdentifier("sensorStatus")
    }

    private var gpsCell: some View {
        let precise = permission.isPrecise || !needsPermission
        let preciseText = precise ? Text("Precise") : Text("Approximate")
        let cell: (Text, Color, Text?)
        if recorder.phase == .recording, let accuracy = recorder.live.snapshot.horizontalAccuracy {
            cell = (
                Text(verbatim: "±\(accuracy.formatted(.number.precision(.fractionLength(1)).locale(appLanguage.locale))) m"),
                accuracy <= 10 ? Theme.good : Theme.textPrimary, preciseText
            )
        } else if !needsPermission {
            cell = (Text("Simulated"), Theme.good, preciseText)
        } else {
            switch permission.authorizationStatus {
            case .authorizedWhenInUse, .authorizedAlways:
                cell = (Text("Ready"), precise ? Theme.good : Theme.accent, preciseText)
            case .denied:
                cell = (Text("Denied"), Theme.rec, nil)
            case .restricted:
                cell = (Text("Restricted"), Theme.rec, nil)
            default:
                cell = (Text("Not asked"), Theme.textPrimary, Text("Asked on START"))
            }
        }
        return StatusCell(label: Text(verbatim: "GPS"), value: cell.0, tint: cell.1, detail: cell.2)
    }

    private var motionCell: some View {
        let hz = preset.motion.hz
        return StatusCell(
            label: Text("Motion"),
            value: hz > 0 ? Text(verbatim: "\(Int(hz)) Hz") : Text("Off"),
            tint: hz > 0 ? Theme.good : Theme.textPrimary,
            detail: hz > 0 ? (isSimulated ? Text("Simulated") : Text("Ready")) : nil
        )
    }

    private var barometerCell: some View {
        let available = CMAltimeter.isRelativeAltitudeAvailable()
        let value: Text = isSimulated ? Text("Simulated") : (available ? Text("Available") : Text("Unavailable"))
        return StatusCell(
            label: Text("Barometer"), value: value,
            tint: isSimulated || !available ? Theme.textPrimary : Theme.good, detail: nil
        )
    }

    private var powerCell: some View {
        let level = power.level.map { "\(Int(($0 * 100).rounded()))%" } ?? "—"
        return StatusCell(
            label: Text("Power"), value: Text(verbatim: level), tint: Theme.textPrimary,
            detail: power.isCharging ? Text("Charging") : nil
        )
    }

    private var backgroundStatus: (text: LocalizedStringKey, tint: Color) {
        if !permission.backgroundAvailable { return ("Not configured", Theme.rec) }
        if !needsPermission { return ("Simulated · OK", Theme.good) }
        switch permission.authorizationStatus {
        case .authorizedAlways: return ("Always · OK", Theme.good)
        case .authorizedWhenInUse: return ("While Using · OK", Theme.good)
        case .denied, .restricted: return ("Location off", Theme.rec)
        default: return ("Asked on START", Theme.textSecondary)
        }
    }

    // MARK: START

    private var startArea: some View {
        VStack(spacing: 18) {
            Button {
                Task { await start() }
            } label: {
                VStack(spacing: 4) {
                    Text("START")
                        .font(.system(size: 30, weight: .semibold))
                        .tracking(1.8)
                        .foregroundStyle(Theme.background)
                    Text("Record drive")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Theme.background.opacity(0.7))
                }
                .frame(width: 188, height: 188)
                .background(Theme.accent, in: Circle())
                .padding(10)
                .background(Theme.accent.opacity(0.08), in: Circle())
            }
            .buttonStyle(.plain)
            .disabled(!canStart)
            .opacity(canStart ? 1 : 0.4)
            .accessibilityLabel("Start recording")
            .accessibilityIdentifier("startButton")

            Text(verbatim: presetSummary)
                .font(.hudNumber(size: 12, weight: .medium))
                .foregroundStyle(Theme.textTertiary)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(Theme.surface, in: Capsule())
                .accessibilityIdentifier("presetLabel")

            if let issue {
                issueCard(issue)
            } else if let error = recorder.lastError {
                Text(verbatim: error)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.rec)
                    .multilineTextAlignment(.center)
            }

            Text("Mount the phone, then start. Forward direction is detected automatically on the first acceleration.")
                .font(.system(size: 12))
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 280)
        }
        .frame(maxWidth: .infinity, minHeight: 300)
        .padding(.vertical, 12)
    }

    private var presetSummary: String {
        let hz = preset.motion.hz
        return hz > 0 ? "\(preset.displayName) · \(Int(hz)) Hz" : preset.displayName
    }

    private func issueCard(_ issue: StartIssue) -> some View {
        VStack(spacing: 8) {
            switch issue {
            case .denied:
                Text("Location access is off. DriveScope needs it to record your route and speed.")
            case .imprecise:
                Text("Precise Location is off. Turn it on for DriveScope to record an accurate route.")
            }
            Button("Open Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
            }
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(Theme.accent)
            .accessibilityIdentifier("openSettingsButton")
        }
        .font(.system(size: 12))
        .foregroundStyle(Theme.textTertiary)
        .multilineTextAlignment(.center)
        .padding(12)
        .frame(maxWidth: .infinity)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12))
    }

    private func start() async {
        guard canStart else { return }
        isStarting = true
        defer { isStarting = false }
        issue = nil
        if needsPermission {
            if permission.authorizationStatus == .notDetermined { await permission.requestWhenInUse() }
            guard permission.canRecord else { issue = .denied; return }
            guard await permission.ensureFullAccuracy() else { issue = .imprecise; return }
        }
        // Ask for notifications (watchdog / dead-man) before recording, not over the HUD. Denial doesn't block START.
        await RecordingNotifications.requestAuthorizationIfNeeded()
        await recorder.start(preset: preset)
    }

    // MARK: Recent

    @ViewBuilder private var recentSessions: some View {
        if !recent.isEmpty {
            let format = SessionFormat(language: appLanguage)
            VStack(spacing: 10) {
                HStack {
                    Text("Recent")
                        .font(.system(size: 12, weight: .medium))
                        .tracking(0.96)
                        .textCase(.uppercase)
                        .foregroundStyle(Theme.textSecondary)
                    Spacer()
                    Button("All sessions", action: onShowAllSessions)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Theme.accent)
                        .accessibilityIdentifier("allSessionsButton")
                }
                ForEach(recent) { session in
                    Button {
                        onOpenSession(session.id)
                    } label: {
                        HStack(spacing: 12) {
                            RouteThumbnail(
                                points: session.routePreview, size: CGSize(width: 44, height: 36),
                                dashed: session.state == .recovered
                            )
                            VStack(alignment: .leading, spacing: 2) {
                                Text(verbatim: format.title(session))
                                    .font(.system(size: 14, weight: .medium))
                                    .foregroundStyle(Theme.textPrimary)
                                    .lineLimit(1)
                                Text(verbatim: recentMeta(session, format))
                                    .font(.hudNumber(size: 12))
                                    .foregroundStyle(Theme.textSecondary)
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.85)
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 12)
                        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12))
                        .contentShape(RoundedRectangle(cornerRadius: 12))
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("recentSession")
                }
            }
            .padding(.bottom, 14)
        }
    }

    private func recentMeta(_ session: DriveSession, _ format: SessionFormat) -> String {
        [
            format.shortDate(session), format.duration(session.duration),
            format.distance(meters: session.distance).text,
            appLanguage.string("max \(format.speed(metersPerSecond: session.maxSpeed).value)"),
        ].joined(separator: " · ")
    }
}

private struct StatusCell: View {
    let label: Text
    let value: Text
    let tint: Color
    let detail: Text?

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            label
                .font(.system(size: 11))
                .textCase(.uppercase)
                .foregroundStyle(Theme.textSecondary)
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                value
                    .font(.hudNumber(size: 18, weight: .medium))
                    .foregroundStyle(tint)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                detail
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

/// Battery / Low Power Mode. The simulator reports level -1 and state unknown, shown as "—".
private struct PowerStatus {
    var level: Float?
    var isCharging: Bool
    var isLowPower: Bool

    @MainActor
    static func read() -> PowerStatus {
        let device = UIDevice.current
        let level: Float? = device.batteryLevel >= 0 ? device.batteryLevel : nil
        return PowerStatus(
            level: level,
            isCharging: device.batteryState == .charging || device.batteryState == .full,
            isLowPower: ProcessInfo.processInfo.isLowPowerModeEnabled
        )
    }
}
