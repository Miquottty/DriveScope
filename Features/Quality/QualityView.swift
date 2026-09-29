import DriveDomain
import DriveReplay
import DriveStorage
import SwiftData
import SwiftUI

/// Log-quality screen (PLAN §11 "Quality (Debug)"): figures computed from one session's binary files.
struct QualityView: View {
    /// The session to report on first (e.g. the one selected in the iPad sidebar); nil = the most recent.
    var sessionID: UUID?

    @Environment(AppModel.self) private var model
    @Environment(AppLanguage.self) private var appLanguage
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Query(sort: \DriveSession.startedAt, order: .reverse) private var allSessions: [DriveSession]
    @State private var selectedID: UUID?
    @State private var loaded: Loaded?

    init(sessionID: UUID? = nil) {
        self.sessionID = sessionID
        _selectedID = State(initialValue: sessionID)
    }

    private struct Loaded {
        let id: UUID
        let report: QualityReport?
    }

    /// The session being recorded has no finished files to inspect yet.
    private var sessions: [DriveSession] { allSessions.filter { $0.state != .recording } }
    private var session: DriveSession? { sessions.first { $0.id == selectedID } ?? sessions.first }

    var body: some View {
        let format = SessionFormat(language: appLanguage)

        Group {
            if horizontalSizeClass == .regular {
                iPadBody(format)
            } else {
                phoneBody(format)
            }
        }
        .task(id: session?.id) {
            guard let id = session?.id else {
                loaded = nil
                return
            }
            let report = await Self.load(files: SessionFiles(root: model.filesRoot, sessionID: id))
            guard !Task.isCancelled else { return }
            loaded = Loaded(id: id, report: report)
        }
        .onChange(of: sessionID) { _, id in
            if let id { selectedID = id }
        }
    }

    private func phoneBody(_ format: SessionFormat) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Quality")
                .font(.system(size: 28, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
                .padding(.horizontal, 20)
                .padding(.bottom, 10)
            if let session {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        picker(selected: session, format)
                        content(for: session, format)
                    }
                    .padding(.horizontal, 20)
                    .padding(.bottom, 16)
                    .readableWidth()
                }
                .scrollBounceBehavior(.basedOnSize)
            } else {
                emptyState
            }
        }
        .padding(.top, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Theme.background)
    }

    // MARK: Session picker

    private func picker(selected: DriveSession, _ format: SessionFormat) -> some View {
        Menu {
            Picker("Session", selection: Binding(get: { selected.id }, set: { selectedID = $0 })) {
                ForEach(sessions) { candidate in
                    Text(verbatim: "\(format.title(candidate)) · \(format.duration(candidate.duration))")
                        .tag(candidate.id)
                }
            }
        } label: {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: format.title(selected))
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)
                    Text(verbatim: format.metaLine(selected))
                        .font(.hudNumber(size: 12))
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.textMuted)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12))
            .contentShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("qualitySessionPicker")
    }

    // MARK: Report

    @ViewBuilder private func content(for session: DriveSession, _ format: SessionFormat) -> some View {
        if let loaded, loaded.id == session.id {
            if let report = loaded.report {
                reportSections(report, format)
            } else {
                Text("Could not read the log files.")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.rec)
            }
        } else {
            ProgressView()
                .tint(Theme.textSecondary)
                .frame(maxWidth: .infinity)
                .padding(.top, 40)
        }
    }

    @ViewBuilder private func reportSections(_ report: QualityReport, _ format: SessionFormat) -> some View {
        let none = "—"
        let interval: (TimeInterval?) -> String = { seconds in
            seconds.map { format.number($0, fraction: 2) + "\u{00A0}" + UnitDuration.seconds.symbol } ?? none
        }

        QualityCard(title: "Location") {
            QualityRow(label: "Samples", value: format.integer(report.location.count))
            QualityRow(label: "Mean interval", value: interval(report.location.meanInterval))
            QualityRow(label: "Max gap", value: report.location.maxGap.map { format.seconds($0).text } ?? none)
            QualityRow(label: "Accuracy P50", value: format.meters(report.accuracyP50).text)
            QualityRow(label: "Accuracy P95", value: format.meters(report.accuracyP95).text)
        }
        QualityCard(title: "Motion") {
            QualityRow(label: "Samples", value: report.motion.count > 0 ? format.integer(report.motion.count) : none)
            QualityRow(label: "Effective / preset", value: motionRate(report, format))
            QualityRow(label: "Dropped", value: report.motionDropRate.map { format.percent($0) } ?? none)
        }
        batteryCard(report.battery, format)
        QualityCard(title: "Altitude") {
            QualityRow(label: "Samples", value: format.integer(report.altitude.count))
            QualityRow(label: "Mean interval", value: interval(report.altitude.meanInterval))
        }
        QualityCard(title: "Storage") {
            QualityRow(
                label: "On disk",
                value: Int64(report.bytesOnDisk).formatted(.byteCount(style: .file).locale(appLanguage.locale))
            )
        }
        QualityCard(title: "Thermal") {
            QualityRow(
                label: "Max state",
                value: report.maxThermalState.map { EventFormat(language: appLanguage).thermalState($0) } ?? none
            )
        }
        eventsCard(report.events)
    }

    /// Drain from `batterySnapshot` events (PLAN §2.2.2, real-car test E). Needs ≥ 10 min unplugged per figure.
    private func batteryCard(_ battery: BatteryUsage, _ format: SessionFormat) -> some View {
        let drain: (Double?) -> String = { rate in
            rate.map { format.number($0, fraction: 1) + "\u{00A0}%/h" } ?? "—"
        }
        return QualityCard(title: "Battery") {
            QualityRow(label: "Overall", value: drain(battery.overall))
            QualityRow(label: "Screen on", value: drain(battery.screenOn))
            QualityRow(label: "Screen off", value: drain(battery.screenOff))
            if battery.overall == nil || battery.screenOn == nil || battery.screenOff == nil {
                Text("Not enough unplugged data (needs ≥ 10 min)")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textSecondary)
            }
        }
    }

    /// "49.8 / 50 Hz": what the stream delivered against what the preset asked for.
    private func motionRate(_ report: QualityReport, _ format: SessionFormat) -> String {
        let requested = report.preset.motion.hz
        guard requested > 0 else { return appLanguage.string("Off") }
        let actual = report.motion.effectiveHz.map { format.number($0, fraction: 1) } ?? "—"
        return "\(actual) / \(format.integer(Int(requested))) Hz"
    }

    private func eventsCard(_ events: [EventRecord]) -> some View {
        let eventFormat = EventFormat(language: appLanguage)
        return QualityCard(title: "Events") {
            if events.isEmpty {
                Text("No events recorded")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textSecondary)
            } else {
                LazyVStack(alignment: .leading, spacing: 6) {
                    ForEach(events.indices, id: \.self) { index in
                        let event = events[index]
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Text(verbatim: Self.clock(event.elapsed))
                                .font(.hudNumber(size: 12))
                                .foregroundStyle(Theme.textSecondary)
                            Text(eventFormat.name(event.kind))
                                .font(.system(size: 12))
                                .foregroundStyle(Theme.textPrimary)
                            Spacer(minLength: 8)
                            Text(verbatim: eventFormat.value(event))
                                .font(.hudNumber(size: 12))
                                .foregroundStyle(Theme.textTertiary)
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
            }
        }
    }

    // MARK: iPad (mock 15)

    /// Title and session picker, LOCATION / MOTION / BATTERY cards, and the full-width EVENTS table.
    private func iPadBody(_ format: SessionFormat) -> some View {
        GeometryReader { geometry in
            let contentWidth = geometry.size.width - 2 * IPadMetrics.margin
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    HStack(spacing: 16) {
                        Text("Quality")
                            .font(.system(size: 34, weight: .semibold))
                            .foregroundStyle(Theme.textPrimary)
                        Spacer(minLength: 16)
                        if let session { iPadPicker(selected: session, format) }
                    }
                    if let session {
                        iPadContent(for: session, format, contentWidth: contentWidth)
                    } else {
                        iPadEmptyState
                    }
                }
                .padding(.horizontal, IPadMetrics.margin)
                .padding(.top, 8)
                .padding(.bottom, 24)
                // The EVENTS card fills the rest of the screen, as in the mock.
                .frame(minHeight: geometry.size.height, alignment: .top)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .background(Theme.background)
    }

    private func iPadPicker(selected: DriveSession, _ format: SessionFormat) -> some View {
        let shape = RoundedRectangle(cornerRadius: 12)
        return Menu {
            Picker("Session", selection: Binding(get: { selected.id }, set: { selectedID = $0 })) {
                ForEach(sessions) { candidate in
                    Text(verbatim: "\(format.title(candidate)) · \(format.shortDate(candidate)) · \(format.duration(candidate.duration))")
                        .tag(candidate.id)
                }
            }
        } label: {
            HStack(spacing: 10) {
                Text(verbatim: "\(format.title(selected)) · \(format.shortDate(selected))")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.textTertiary)
            }
            .padding(.horizontal, 16)
            .frame(minHeight: IPadMetrics.minTouch)
            .background(Theme.surface, in: shape)
            .overlay(shape.strokeBorder(Theme.dividerStrong, lineWidth: 1.5))
            .contentShape(shape)
            .cardHoverEffect(cornerRadius: 12)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("qualitySessionPicker")
    }

    @ViewBuilder private func iPadContent(for session: DriveSession, _ format: SessionFormat, contentWidth: CGFloat) -> some View {
        if let loaded, loaded.id == session.id {
            if let report = loaded.report {
                iPadReport(report, session: session, format, contentWidth: contentWidth)
            } else {
                Text("Could not read the log files.")
                    .font(.system(size: 15))
                    .foregroundStyle(Theme.rec)
            }
        } else {
            ProgressView()
                .tint(Theme.textSecondary)
                .frame(maxWidth: .infinity)
                .padding(.top, 60)
        }
    }

    @ViewBuilder private func iPadReport(
        _ report: QualityReport, session: DriveSession, _ format: SessionFormat, contentWidth: CGFloat
    ) -> some View {
        // Three cards side by side need ~240 pt each for "Mean interval   1.00 s" at 16 pt.
        let columns = contentWidth >= 720
            ? AnyLayout(HStackLayout(alignment: .top, spacing: 16))
            : AnyLayout(VStackLayout(spacing: 16))
        columns {
            iPadLocationCard(report, format)
            iPadMotionCard(report, session: session, format)
            iPadBatteryCard(report, format)
        }
        .fixedSize(horizontal: false, vertical: true)
        IPadEventsCard(
            events: report.events, bytesOnDisk: report.bytesOnDisk, compact: contentWidth < 640, clock: Self.clock
        )
    }

    private func iPadLocationCard(_ report: QualityReport, _ format: SessionFormat) -> some View {
        let none = "—"
        let interval: (TimeInterval?) -> String = { seconds in
            seconds.map { format.number($0, fraction: 2) + "\u{00A0}" + UnitDuration.seconds.symbol } ?? none
        }
        let accuracy = "\(format.number(report.accuracyP50, fraction: 1)) / \(format.meters(report.accuracyP95).text)"
        return IPadQualityCard(title: "Location") {
            IPadQualityRow(label: "Samples", value: format.integer(report.location.count))
            IPadQualityRow(label: "Mean interval", value: interval(report.location.meanInterval))
            IPadQualityRow(label: "Max gap", value: report.location.maxGap.map { format.seconds($0).text } ?? none)
            IPadQualityRow(label: Text(verbatim: "P50 / P95"), value: accuracy)
            // Barometer stream: sample count and mean interval.
            IPadQualityRow(
                label: "Altitude",
                value: "\(format.integer(report.altitude.count)) · \(interval(report.altitude.meanInterval))"
            )
        }
    }

    private func iPadMotionCard(_ report: QualityReport, session: DriveSession, _ format: SessionFormat) -> some View {
        let none = "—"
        let calibration = session.calibration.map { "\($0.method.rawValue) · \(format.number($0.confidence, fraction: 2))" }
        return IPadQualityCard(title: "Motion") {
            IPadQualityRow(label: "Samples", value: report.motion.count > 0 ? format.integer(report.motion.count) : none)
            IPadQualityRow(label: "Effective", value: motionRate(report, format))
            IPadQualityRow(label: "Dropped", value: report.motionDropRate.map { format.percent($0) } ?? none)
            IPadQualityRow(label: "Calibration", value: calibration ?? none)
        }
    }

    private func iPadBatteryCard(_ report: QualityReport, _ format: SessionFormat) -> some View {
        let battery = report.battery
        let drain: (Double?) -> String = { rate in
            rate.map { format.number($0, fraction: 1) + "\u{00A0}%/h" } ?? "—"
        }
        return IPadQualityCard(title: "Battery") {
            IPadQualityRow(label: "Overall", value: drain(battery.overall))
            IPadQualityRow(label: "Screen on", value: drain(battery.screenOn))
            IPadQualityRow(label: "Screen off", value: drain(battery.screenOff))
            IPadQualityRow(
                label: "Thermal max",
                value: report.maxThermalState.map { EventFormat(language: appLanguage).thermalState($0) } ?? "—"
            )
            if battery.overall == nil || battery.screenOn == nil || battery.screenOff == nil {
                Text("Not enough unplugged data (needs ≥ 10 min)")
                    .font(.system(size: 14))
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var iPadEmptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "waveform.path.ecg")
                .font(.system(size: 40))
                .foregroundStyle(Theme.textSecondary)
            Text("No drives yet")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
            Text("Recorded drives appear here.")
                .font(.system(size: 15))
                .foregroundStyle(Theme.textTertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.bottom, 60)
    }

    /// Elapsed time as hh:mm:ss.
    private static func clock(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded()))
        return String(format: "%02d:%02d:%02d", total / 3600, total % 3600 / 60, total % 60)
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "waveform.path.ecg")
                .font(.system(size: 34))
                .foregroundStyle(Theme.textMuted)
            Text("No drives yet")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
            Text("Recorded drives appear here.")
                .font(.system(size: 13))
                .foregroundStyle(Theme.textSecondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.bottom, 60)
    }

    /// Reads every fix and event of a long session; keep it off the main actor.
    @concurrent nonisolated private static func load(files: SessionFiles) async -> QualityReport? {
        try? QualityReport.make(files: files)
    }
}

/// A titled surface box in the style of Session Detail's "Log Quality".
private struct QualityCard<Content: View>: View {
    let title: LocalizedStringKey
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 10))
                .tracking(1)
                .textCase(.uppercase)
                .foregroundStyle(Theme.textSecondary)
            content
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12))
    }
}

private struct QualityRow: View {
    let label: LocalizedStringKey
    let value: String

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .font(.system(size: 12))
                .foregroundStyle(Theme.textSecondary)
            Spacer(minLength: 8)
            Text(verbatim: value)
                .font(.hudNumber(size: 12))
                .foregroundStyle(Theme.textTertiary)
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - iPad parts

/// iPad report card: 13 pt caps title, 16 pt rows (mock 15).
private struct IPadQualityCard<Content: View>: View {
    let title: LocalizedStringKey
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).iPadLabel()
            VStack(alignment: .leading, spacing: 9) {
                content
            }
        }
        .iPadCard(fillHeight: true)
    }
}

private struct IPadQualityRow: View {
    let label: Text
    let value: String

    init(label: LocalizedStringKey, value: String) {
        self.label = Text(label)
        self.value = value
    }

    init(label: Text, value: String) {
        self.label = label
        self.value = value
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            label
                .font(.system(size: 16))
                .foregroundStyle(Theme.textTertiary)
                .layoutPriority(1)
            Spacer(minLength: 12)
            Text(verbatim: value)
                .font(.hudNumber(size: 16))
                .foregroundStyle(Theme.textPrimary)
                .minimumScaleFactor(0.7)
        }
        .lineLimit(1)
        .accessibilityElement(children: .combine)
    }
}

/// TIME / EVENT / VALUE / SOURCE table (mock 15). Rows are lazy: a long drive logs a battery snapshot every 5 min.
private struct IPadEventsCard: View {
    let events: [EventRecord]
    let bytesOnDisk: Int
    /// Narrow widths (portrait with the sidebar open): no SOURCE column; a marker's source moves into VALUE.
    let compact: Bool
    let clock: (TimeInterval) -> String

    @Environment(AppLanguage.self) private var appLanguage

    private var columns: (time: CGFloat, value: CGFloat, source: CGFloat) {
        compact ? (86, 150, 0) : (120, 220, 140)
    }

    var body: some View {
        let eventFormat = EventFormat(language: appLanguage)
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text("Events").iPadLabel()
                Spacer(minLength: 12)
                Text(verbatim: summary)
                    .font(.system(size: 14))
                    .foregroundStyle(Theme.textTertiary)
                    .lineLimit(1)
            }
            if events.isEmpty {
                Text("No events recorded")
                    .font(.system(size: 15))
                    .foregroundStyle(Theme.textSecondary)
                    .padding(.top, 14)
            } else {
                row(Text("Time"), Text("Event"), Text("Value"), Text("Source"))
                    .font(.system(size: 13, weight: .semibold))
                    .tracking(1)
                    .textCase(.uppercase)
                    .foregroundStyle(Theme.textSecondary)
                    .padding(.top, 8)
                    .padding(.bottom, 8)
                LazyVStack(spacing: 0) {
                    ForEach(events.indices, id: \.self) { index in
                        let event = events[index]
                        row(
                            Text(verbatim: clock(event.elapsed)).font(.hudNumber(size: 15)).foregroundStyle(Theme.textTertiary),
                            Text(eventFormat.name(event.kind)).foregroundStyle(Theme.textPrimary),
                            Text(verbatim: eventFormat.value(event, includingSource: compact))
                                .font(.hudNumber(size: 15)).foregroundStyle(Theme.textPrimary),
                            Text(verbatim: eventFormat.source(event.source)).foregroundStyle(Theme.textTertiary)
                        )
                        .font(.system(size: 15))
                        .padding(.vertical, 10)
                        .overlay(alignment: .top) {
                            Rectangle().fill(Theme.divider).frame(height: 1)
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
            }
        }
        .iPadCard(fillHeight: true)
    }

    private func row(_ time: some View, _ event: some View, _ value: some View, _ source: some View) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            time.frame(width: columns.time, alignment: .leading)
            event.frame(maxWidth: .infinity, alignment: .leading)
            value.frame(width: columns.value, alignment: .leading)
            if !compact {
                source.frame(width: columns.source, alignment: .leading)
            }
        }
        .lineLimit(1)
        .minimumScaleFactor(0.85)
    }

    /// "6 events · 41.3 MB on disk"
    private var summary: String {
        let size = Int64(bytesOnDisk).formatted(.byteCount(style: .file).locale(appLanguage.locale))
        return appLanguage.string("\(events.count) events") + " · " + appLanguage.string("\(size) on disk")
    }
}
