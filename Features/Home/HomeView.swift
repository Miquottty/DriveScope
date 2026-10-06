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
    @Environment(BatteryMonitor.self) private var battery
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openURL) private var openURL
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @AppStorage("capturePreset") private var presetRaw = CapturePreset.default.rawValue
    @Query(HomeView.recentDescriptor) private var recent: [DriveSession]

    @State private var showingSettings = false
    @State private var isLowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled
    @State private var batterySuggestionDismissed = false
    @State private var isStarting = false
    @State private var issue: StartIssue?
    @State private var probe = SatelliteProbe()

    private static var recentDescriptor: FetchDescriptor<DriveSession> {
        var descriptor = FetchDescriptor<DriveSession>(sortBy: [SortDescriptor(\.startedAt, order: .reverse)])
        descriptor.fetchLimit = 3
        return descriptor
    }

    enum StartIssue {
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

    /// Search for satellites while Home is on screen and idle (PLAN §11). Never asks for permission: that stays
    /// with START.
    private var probeShouldRun: Bool {
        scenePhase == .active && !isStarting && (recorder.phase == .idle || recorder.phase == .stopped)
            && needsPermission && permission.canRecord && permission.isPrecise
    }

    /// The GPS cell's value while satellites are tracked — by the recording or by the Home search; nil otherwise.
    /// Wi‑Fi fixes before the lock show as searching, never as an accuracy.
    static func satelliteValue(
        status: TelemetrySnapshot.GPSStatus?, accuracy: Double?, locale: Locale
    ) -> (value: Text, tint: Color)? {
        switch status {
        case nil:
            return nil
        case .good?:
            guard let accuracy else { return (Text("Searching"), Theme.accent) }
            let text = Text(verbatim: "±\(accuracy.formatted(.number.precision(.fractionLength(1)).locale(locale))) m")
            return (text, accuracy <= 10 ? Theme.good : Theme.textPrimary)
        case .acquiring?, .searching?:
            return (Text("Searching"), Theme.accent)
        }
    }

    private var satelliteValue: (value: Text, tint: Color)? {
        let recording = recorder.phase == .recording
        let snapshot = recorder.live.snapshot
        return Self.satelliteValue(
            status: recording ? snapshot.gpsStatus : probe.status,
            accuracy: recording ? snapshot.horizontalAccuracy : probe.accuracy,
            locale: appLanguage.locale
        )
    }

    var body: some View {
        Group {
            if LayoutClass.isPad(horizontalSizeClass, verticalSizeClass) {
                iPadDashboard
            } else if verticalSizeClass == .compact {
                phoneLandscapeDashboard
            } else {
                phoneDashboard
            }
        }
        .sheet(isPresented: $showingSettings) {
            SettingsView(permission: permission)
        }
        .onReceive(NotificationCenter.default.publisher(for: .NSProcessInfoPowerStateDidChange)) { _ in
            isLowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled
        }
        .task(id: probeShouldRun) {
            guard probeShouldRun, let source = model.sensorEnvironment.makeProbeSource() else { return }
            await probe.run(source: source)
        }
        .onChange(of: permission.canRecord) { _, allowed in
            if allowed, issue == .denied { issue = nil }
        }
        .onChange(of: permission.isPrecise) { _, precise in
            if precise, issue == .imprecise { issue = nil }
        }
    }

    /// iPad (mock 11). The sidebar carries the app name and Settings, so there is no header here.
    private var iPadDashboard: some View {
        HomeIPadLayout(
            permission: permission,
            presetRaw: $presetRaw,
            canStart: canStart,
            issue: issue,
            isLowPowerMode: isLowPowerMode,
            batterySuggestionPercent: showsBatterySuggestion ? Int(((battery.level ?? 0) * 100).rounded()) : nil,
            satelliteValue: satelliteValue,
            recent: recent.filter { !$0.isDeleted && $0.modelContext != nil },
            onStart: { Task { await start() } },
            onDismissBatterySuggestion: { withAnimation { batterySuggestionDismissed = true } },
            onOpenSession: onOpenSession,
            onShowAllSessions: onShowAllSessions
        )
    }

    private var phoneDashboard: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                header
                sensorStatus(columns: 2).padding(.top, 22)
                batterySuggestion.padding(.top, 14)
                startArea
                recentSessions()
            }
            .padding(.horizontal, 20)
            .padding(.top, 8)
            .readableWidth()
        }
        .scrollBounceBehavior(.basedOnSize)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.background)
    }

    /// iPhone landscape (mock 1b / 1c): START on the left, sized to the height; status and recent sessions on the
    /// right, scrolling if a long language or a warning makes them taller than the screen.
    private var phoneLandscapeDashboard: some View {
        GeometryReader { proxy in
            let startSize = min(200, max(140, proxy.size.height - 120))
            let side = proxy.size.width - (startSize + 70) - 28
            HStack(alignment: .center, spacing: 28) {
                VStack(spacing: 14) {
                    startButton(size: startSize)
                    presetChip
                    startIssue
                    Text("Mount the phone, then start. Forward direction is detected automatically on the first acceleration.")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textSecondary)
                        .multilineTextAlignment(.center)
                }
                .frame(width: startSize + 70)
                .frame(maxHeight: .infinity)

                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        header
                        sensorStatus(columns: 4)
                        batterySuggestion
                        recentSessions(columns: side >= 480 ? 2 : 1)
                    }
                    .padding(.vertical, 8)
                }
                .scrollBounceBehavior(.basedOnSize)
                .scrollIndicators(.hidden)
            }
        }
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.background)
    }

    @ViewBuilder private var batterySuggestion: some View {
        if showsBatterySuggestion {
            LowBatterySuggestion(
                percent: Int(((battery.level ?? 0) * 100).rounded()),
                onSelect: { preset in
                    withAnimation { presetRaw = preset.rawValue }
                },
                onDismiss: {
                    withAnimation { batterySuggestionDismissed = true }
                }
            )
            .transition(.opacity)
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

    /// Two columns in portrait; one row of four in landscape.
    private func sensorStatus(columns: Int) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Sensor Status")
                .font(.system(size: 12, weight: .medium))
                .tracking(0.96)
                .textCase(.uppercase)
                .foregroundStyle(Theme.textSecondary)
            Grid(alignment: .leading, horizontalSpacing: columns > 2 ? 12 : 10, verticalSpacing: 10) {
                if columns > 2 {
                    GridRow(alignment: .top) {
                        gpsCell
                        motionCell
                        barometerCell
                        powerCell
                    }
                    .environment(\.statusCellStacked, true)
                } else {
                    GridRow {
                        gpsCell
                        motionCell
                    }
                    GridRow {
                        barometerCell
                        powerCell
                    }
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
            if isLowPowerMode {
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
        if let live = satelliteValue {
            cell = (live.value, live.tint, preciseText)
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
        let level = battery.level.map { "\(Int(($0 * 100).rounded()))%" } ?? "—"
        return StatusCell(
            label: Text("Power"), value: Text(verbatim: level), tint: Theme.textPrimary,
            detail: battery.isCharging ? Text("Charging") : nil
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
            startButton(size: 188)
            presetChip
            startIssue
            Text("Mount the phone, then start. Forward direction is detected automatically on the first acceleration.")
                .font(.system(size: 12))
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 280)
        }
        .frame(maxWidth: .infinity, minHeight: 300)
        .padding(.vertical, 12)
    }

    private func startButton(size: CGFloat) -> some View {
        Button {
            Task { await start() }
        } label: {
            VStack(spacing: 4) {
                // English in every language, like the HUD's MARK / SYNC / STOP; the line below says it in words.
                Text(verbatim: "START")
                    .font(.system(size: size * 0.16, weight: .semibold))
                    .tracking(size * 0.0096)
                    .foregroundStyle(Theme.background)
                Text("Record drive")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.background.opacity(0.7))
            }
            .frame(width: size, height: size)
            .background(Theme.accent, in: Circle())
            .padding(size * 0.053)
            .background(Theme.accent.opacity(0.08), in: Circle())
        }
        .buttonStyle(.plain)
        .disabled(!canStart)
        .opacity(canStart ? 1 : 0.4)
        .accessibilityLabel("Start recording")
        .accessibilityIdentifier("startButton")
    }

    private var presetChip: some View {
        Text(verbatim: presetSummary)
            .font(.hudNumber(size: 12, weight: .medium))
            .foregroundStyle(Theme.textTertiary)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(Theme.surface, in: Capsule())
            .accessibilityIdentifier("presetLabel")
    }

    @ViewBuilder private var startIssue: some View {
        if let issue {
            issueCard(issue)
        } else if let error = recorder.lastError {
            Text(verbatim: error)
                .font(.system(size: 12))
                .foregroundStyle(Theme.rec)
                .multilineTextAlignment(.center)
        }
    }

    /// PLAN §2.2.1: suggest only, never switch automatically. Nothing to suggest once the preset is already light.
    private var showsBatterySuggestion: Bool {
        let idle = recorder.phase == .idle || recorder.phase == .stopped
        return battery.isLow && !batterySuggestionDismissed && idle && preset != .eco && preset != .gpsOnly
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

    /// One column in portrait. Landscape shows only what fits beside START: one card, or two side by side.
    @ViewBuilder private func recentSessions(columns: Int? = nil) -> some View {
        // A session deleted elsewhere can be re-rendered once before the query drops it.
        let sessions = recent.filter { !$0.isDeleted && $0.modelContext != nil }
        if !sessions.isEmpty {
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
                if let columns {
                    HStack(spacing: 10) {
                        ForEach(sessions.prefix(columns)) { recentRow($0, format) }
                    }
                } else {
                    ForEach(sessions) { recentRow($0, format) }
                }
            }
            .padding(.bottom, 14)
        }
    }

    private func recentRow(_ session: DriveSession, _ format: SessionFormat) -> some View {
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

    private func recentMeta(_ session: DriveSession, _ format: SessionFormat) -> String {
        [
            format.shortDate(session), format.duration(session.duration),
            format.distance(meters: session.distance).text,
            appLanguage.string("max \(format.speed(metersPerSecond: session.maxSpeed).value)"),
        ].joined(separator: " · ")
    }
}

private extension EnvironmentValues {
    /// Landscape Home's four narrow status columns: the detail goes under the value instead of beside it.
    @Entry var statusCellStacked = false
}

private struct StatusCell: View {
    let label: Text
    let value: Text
    let tint: Color
    let detail: Text?

    @Environment(\.statusCellStacked) private var stacked

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            label
                .font(.system(size: 11))
                .textCase(.uppercase)
                .foregroundStyle(Theme.textSecondary)
            if stacked {
                valueText
                detailText
            } else {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    valueText
                    detailText
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private var valueText: some View {
        value
            .font(.hudNumber(size: 18, weight: .medium))
            .foregroundStyle(tint)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
    }

    private var detailText: some View {
        detail
            .font(.system(size: 11))
            .foregroundStyle(Theme.textSecondary)
            .lineLimit(1)
    }
}

/// Amber card above START when the battery is low and unplugged (PLAN §2.2.1).
private struct LowBatterySuggestion: View {
    let percent: Int
    let onSelect: (CapturePreset) -> Void
    let onDismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "battery.25percent")
                .font(.system(size: 18))
                .foregroundStyle(Theme.accent)
                .frame(height: 20)
            VStack(alignment: .leading, spacing: 10) {
                Text("Battery \(percent)% — switch to Eco or GPS Only?")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Theme.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    option(.eco, id: "suggestEcoButton")
                    option(.gpsOnly, id: "suggestGPSOnlyButton")
                }
            }
            Spacer(minLength: 0)
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.textSecondary)
                    .frame(width: 32, height: 32)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss")
            .accessibilityIdentifier("dismissBatterySuggestionButton")
            .offset(x: 6, y: -6)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.accent.opacity(0.35)))
        .accessibilityIdentifier("batterySuggestion")
    }

    private func option(_ preset: CapturePreset, id: String) -> some View {
        Button {
            onSelect(preset)
        } label: {
            Text(verbatim: preset.displayName)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.accent)
                .padding(.horizontal, 14)
                .frame(minHeight: 34)
                .background(Theme.accent.opacity(0.16), in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(id)
    }
}

#Preview("Low battery") {
    LowBatterySuggestion(percent: 17, onSelect: { _ in }, onDismiss: {})
        .padding(20)
        .background(Theme.background)
        .preferredColorScheme(.dark)
}
