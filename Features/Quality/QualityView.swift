import DriveDomain
import DriveReplay
import DriveStorage
import SwiftData
import SwiftUI

/// Log-quality screen (PLAN §11 "Quality (Debug)"): figures computed from one session's binary files.
struct QualityView: View {
    @Environment(AppModel.self) private var model
    @Environment(AppLanguage.self) private var appLanguage
    @Query(sort: \DriveSession.startedAt, order: .reverse) private var allSessions: [DriveSession]
    @State private var selectedID: UUID?
    @State private var loaded: Loaded?

    private struct Loaded {
        let id: UUID
        let report: QualityReport?
    }

    /// The session being recorded has no finished files to inspect yet.
    private var sessions: [DriveSession] { allSessions.filter { $0.state != .recording } }
    private var session: DriveSession? { sessions.first { $0.id == selectedID } ?? sessions.first }

    var body: some View {
        let format = SessionFormat(language: appLanguage)

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
        .task(id: session?.id) {
            guard let id = session?.id else {
                loaded = nil
                return
            }
            let report = await Self.load(files: SessionFiles(root: model.filesRoot, sessionID: id))
            guard !Task.isCancelled else { return }
            loaded = Loaded(id: id, report: report)
        }
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
