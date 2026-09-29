import DriveDomain
import DriveExport
import DriveRecording
import DriveStorage
import SwiftData
import SwiftUI

/// Export sheet (PLAN §5, §12): Logger files (lossless JSON, GPX) and Vlog files (CSV at 30 fps / 10 Hz).
/// Each format is generated on demand into a temporary folder and handed to the share sheet.
struct ExportView: View {
    let sessionID: UUID

    @Environment(AppModel.self) private var model
    @Environment(AppLanguage.self) private var appLanguage
    @Environment(\.dismiss) private var dismiss
    @Environment(\.iPadSheet) private var iPadSheet
    @Query private var sessions: [DriveSession]
    @State private var tab = ExportTab.logger
    /// nil until the old exports are cleared and the session size is known.
    @State private var binaryBytes: Int?
    @State private var exporting: ExportKind?
    @State private var results: [ExportKind: ExportedFile] = [:]
    @State private var failure: Failure?

    private enum ExportTab: Hashable {
        case logger, vlog
    }

    private struct Failure: Identifiable {
        let id = UUID()
        let message: String
    }

    init(sessionID: UUID) {
        self.sessionID = sessionID
        _sessions = Query(filter: #Predicate<DriveSession> { $0.id == sessionID })
    }

    var body: some View {
        NavigationStack {
            Group {
                if let session = sessions.first {
                    content(session)
                } else {
                    ContentUnavailableView("Session not found", systemImage: "questionmark.folder")
                }
            }
            .background(Theme.background)
            .navigationTitle("Export")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .disabled(exporting != nil)
                        .accessibilityIdentifier("exportDone")
                }
            }
        }
        .relocalizing(appLanguage)
        // A form sheet on iPad is sized by `presentationSizing`; the half-height detent is a phone affordance.
        .presentationDetents(iPadSheet ? [.large] : [.medium, .large])
        .presentationBackground(Theme.background)
        .presentationDragIndicator(.visible)
        .interactiveDismissDisabled(exporting != nil)
        .alert(
            "Export failed", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } }),
            presenting: failure
        ) { _ in
            Button("OK") {}
        } message: { failure in
            Text(verbatim: failure.message)
        }
        .task(id: sessionID) {
            guard binaryBytes == nil else { return }
            binaryBytes = await ExportRunner.prepare(files: SessionFiles(root: model.filesRoot, sessionID: sessionID))
        }
    }

    // MARK: Content

    private func content(_ session: DriveSession) -> some View {
        let format = SessionFormat(language: appLanguage)
        let estimate = ExportEstimate(
            binaryBytes: binaryBytes, duration: session.duration, locationFixCount: session.locationSampleCount
        )
        return ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                header(session, format)
                Picker("Export type", selection: $tab) {
                    Text(verbatim: "Logger").tag(ExportTab.logger)
                    Text(verbatim: "Vlog").tag(ExportTab.vlog)
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("exportTabs")
                if tab == .vlog { syncNote(session) }
                ForEach(options(for: tab)) { option in
                    OptionRow(
                        option: option,
                        estimate: estimate.bytes(for: option.kind).map(sizeText) ?? "—",
                        phase: phase(of: option.kind),
                        canStart: exporting == nil && binaryBytes != nil
                    ) {
                        export(option.kind, of: session)
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 8)
            .padding(.bottom, 20)
        }
        .scrollBounceBehavior(.basedOnSize)
    }

    private func header(_ session: DriveSession, _ format: SessionFormat) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(verbatim: format.title(session))
                .font(.system(size: iPadSheet ? 17 : 15, weight: iPadSheet ? .semibold : .medium))
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(1)
            Text(verbatim: format.metaLine(session))
                .font(.hudNumber(size: iPadSheet ? 14 : 12))
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The Vlog CSV's time zero is the first SYNC marker; without one it falls back to the session start.
    private func syncNote(_ session: DriveSession) -> some View {
        let sync = session.markers.filter { $0.kind == .sync }.map(\.elapsed).min()
        return HStack(spacing: 8) {
            Image(systemName: sync == nil ? "info.circle" : "checkmark.circle.fill")
                .foregroundStyle(sync == nil ? Theme.textSecondary : Theme.good)
            if let sync {
                Text("t = 0 at SYNC \(Self.timecode(sync))")
            } else {
                Text("No SYNC marker — t = 0 at session start")
            }
        }
        .font(.system(size: iPadSheet ? 15 : 13))
        .foregroundStyle(Theme.textTertiary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("exportSyncNote")
    }

    private func options(for tab: ExportTab) -> [ExportOption] {
        switch tab {
        case .logger:
            [
                ExportOption(
                    kind: .json, title: "JSON", identifier: "exportJSON",
                    detail: "Lossless master with all raw streams, events and places"
                ),
                ExportOption(
                    kind: .gpx, title: "GPX", identifier: "exportGPX",
                    detail: "Track and markers, for maps and other apps"
                ),
            ]
        case .vlog:
            [
                ExportOption(
                    kind: .csv30, title: "CSV · 30 fps", identifier: "exportCSV30",
                    detail: "Vlog track at 30 fps, one row per video frame"
                ),
                ExportOption(
                    kind: .csv10, title: "CSV · 10 Hz", identifier: "exportCSV10",
                    detail: "Vlog track at 10 Hz, smaller files"
                ),
            ]
        }
    }

    private func phase(of kind: ExportKind) -> OptionRow.Phase {
        if exporting == kind { return .working }
        if let file = results[kind] { return .done(file, sizeText(file.bytes)) }
        return .idle
    }

    private func sizeText(_ bytes: Int) -> String {
        Int64(bytes).formatted(.byteCount(style: .file).locale(appLanguage.locale))
    }

    /// "00:00:12": SYNC position on the session timeline.
    private static func timecode(_ elapsed: TimeInterval) -> String {
        let total = max(0, Int(elapsed.rounded()))
        return String(format: "%02d:%02d:%02d", total / 3600, total % 3600 / 60, total % 60)
    }

    // MARK: Export

    /// Session facts that live in SwiftData; read here on the main actor and handed over as a Sendable copy.
    private func metadata(for session: DriveSession) -> ExportMetadata {
        ExportMetadata(
            title: session.title,
            notes: session.notes ?? "",
            places: [session.startPlace, session.endPlace].compactMap { $0 } + session.viaPlaces,
            markers: session.sortedMarkers.map {
                ExportMarker(kind: $0.kind, elapsed: $0.elapsed, date: $0.date, label: $0.label)
            },
            summary: session.summary,
            sections: session.sections
        )
    }

    private func export(_ kind: ExportKind, of session: DriveSession) {
        guard exporting == nil else { return }
        exporting = kind
        let files = SessionFiles(root: model.filesRoot, sessionID: session.id)
        Task {
            await model.finalizer.ensureSections(session)
            let metadata = metadata(for: session)
            do {
                results[kind] = try await ExportRunner.run(kind, files: files, metadata: metadata)
            } catch {
                failure = Failure(message: error.localizedDescription)
            }
            exporting = nil
        }
    }
}

private struct ExportOption: Identifiable {
    let kind: ExportKind
    let title: String
    let identifier: String
    let detail: LocalizedStringKey

    var id: ExportKind { kind }
}

/// One export format: title, description, estimated size, and the Export → Share action.
private struct OptionRow: View {
    enum Phase {
        case idle
        case working
        /// The file and its formatted size.
        case done(ExportedFile, String)
    }

    let option: ExportOption
    /// Formatted estimate ("3.2 MB").
    let estimate: String
    let phase: Phase
    let canStart: Bool
    let onExport: () -> Void

    /// iPad type scale and 52 pt buttons (design/mock/README.md "iPad の視認性ルール").
    @Environment(\.iPadSheet) private var iPadSheet

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(verbatim: option.title)
                    .font(.system(size: iPadSheet ? 17 : 16, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                Text(option.detail)
                    .font(.system(size: iPadSheet ? 15 : 13))
                    .foregroundStyle(iPadSheet ? Theme.textTertiary : Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(verbatim: footer)
                    .font(.hudNumber(size: iPadSheet ? 14 : 12))
                    .foregroundStyle(Theme.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            action
        }
        .padding(iPadSheet ? 18 : 14)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: iPadSheet ? IPadMetrics.cardRadius : 14))
    }

    private var buttonFont: Font { .system(size: iPadSheet ? 16 : 14, weight: .semibold) }
    private var buttonHeight: CGFloat { iPadSheet ? IPadMetrics.minTouch : 40 }

    /// The estimate before exporting; the actual file name and size afterwards.
    private var footer: String {
        if case .done(let file, let size) = phase { return "\(file.name) · \(size)" }
        return "≈ \(estimate)"
    }

    @ViewBuilder private var action: some View {
        switch phase {
        case .idle:
            Button(action: onExport) {
                Text("Export")
                    .font(buttonFont)
                    .foregroundStyle(Theme.textPrimary)
                    .frame(minWidth: 72, minHeight: buttonHeight)
                    .padding(.horizontal, 6)
                    .background(Theme.background, in: RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.dividerStrong, lineWidth: 1.5))
            }
            .buttonStyle(.plain)
            .disabled(!canStart)
            .opacity(canStart ? 1 : 0.4)
            .accessibilityIdentifier(option.identifier)
        case .working:
            ProgressView()
                .tint(Theme.accent)
                .frame(minWidth: 84, minHeight: buttonHeight)
                .accessibilityLabel("Exporting…")
        case .done(let file, _):
            ShareLink(item: file.url) {
                Label("Share", systemImage: "square.and.arrow.up")
                    .font(buttonFont)
                    .foregroundStyle(Theme.background)
                    .frame(minWidth: 72, minHeight: buttonHeight)
                    .padding(.horizontal, 6)
                    .background(Theme.accent, in: RoundedRectangle(cornerRadius: 10))
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier(option.identifier.replacingOccurrences(of: "export", with: "share"))
        }
    }
}
