import DriveDomain
import DriveRecording
import DriveStorage
import SwiftData
import SwiftUI

/// What the iPad sidebar selects: the Record dashboard, the Quality report, or one session.
enum IPadDestination: Hashable {
    case record
    case quality
    case session(UUID)
}

/// iPad layout: a sidebar that is both the app's navigation (Record / Quality) and the session library (by month,
/// like Mail), and a detail pane that shows the dashboard, the report, or the selected session.
struct IPadRootView: View {
    let permission: LocationPermission

    @Environment(AppModel.self) private var model
    @Environment(AppLanguage.self) private var appLanguage
    @Environment(RecordingController.self) private var recorder
    @Query(sort: \DriveSession.startedAt, order: .reverse, sectionBy: \DriveSession.monthSection)
    private var sections: SectionedResults<DriveSession, String>
    @State private var selection: IPadDestination? = .record
    @State private var columnVisibility = NavigationSplitViewVisibility.all
    @State private var showingSettings = false
    @State private var pendingDelete: DriveSession?

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            sidebar
                .navigationSplitViewColumnWidth(min: 300, ideal: 320, max: 400)
        } detail: {
            NavigationStack {
                detail
            }
            .relocalizing(appLanguage)
        }
        .navigationSplitViewStyle(.balanced)
        .tint(Theme.accent)
        .fullScreenCover(isPresented: .constant(isRecordingUIVisible)) {
            RecordingView()
        }
        .sheet(isPresented: $showingSettings) {
            SettingsView(permission: permission)
                .iPadFormSheet()
        }
        .recoveryPrompt { selection = .session($0) }
        .onChange(of: recorder.phase) { _, phase in
            guard phase == .stopped else { return }
            if let id = recorder.lastFinishedSessionID { selection = .session(id) }
            recorder.acknowledgeStopped()
        }
        .confirmationDialog(
            "Delete this session?",
            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                if let session = pendingDelete { delete(session) }
                pendingDelete = nil
            }
        }
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        let format = SessionFormat(language: appLanguage)
        return List(selection: $selection) {
            Section {
                IPadNavRow(title: "Record", systemImage: "record.circle", isSelected: selection == .record)
                    .sidebarRow(isSelected: selection == .record)
                    .tag(IPadDestination.record)
                IPadNavRow(title: "Quality", systemImage: "waveform.path.ecg", isSelected: selection == .quality)
                    .sidebarRow(isSelected: selection == .quality)
                    .tag(IPadDestination.quality)
            }
            ForEach(sections.newestMonthFirst) { section in
                Section {
                    ForEach(section) { session in
                        IPadSessionRow(session: session, format: format, isRecording: recorder.session?.id == session.id)
                            .sidebarRow(isSelected: selection == .session(session.id))
                            .tag(IPadDestination.session(session.id))
                            .contextMenu {
                                if recorder.session?.id != session.id {
                                    Button("Delete", systemImage: "trash", role: .destructive) { pendingDelete = session }
                                }
                            }
                    }
                } header: {
                    // "SEPTEMBER 2026" / "2026年9月"
                    Text(verbatim: format.monthTitle(section.title))
                        .iPadLabel()
                        .padding(.leading, 2)
                }
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .background(Theme.panel)
        // The title still names the window and the column for VoiceOver; the bar draws the mock's quieter 24 pt
        // brand instead, so the detail's 34 pt page title leads.
        .navigationTitle(Text(verbatim: "DriveScope"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(removing: .title)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Text(verbatim: "DriveScope")
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .fixedSize()
                    .padding(.leading, 6)
                    .accessibilityAddTraits(.isHeader)
            }
            .sharedBackgroundVisibility(.hidden)
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showingSettings = true
                } label: {
                    Label("Settings", systemImage: "gearshape")
                }
                .tint(Theme.textTertiary)
                .accessibilityIdentifier("settingsButton")
            }
        }
        .relocalizing(appLanguage)
    }

    // MARK: - Detail

    @ViewBuilder private var detail: some View {
        switch selection ?? .record {
        case .record:
            HomeView(
                permission: permission,
                onOpenSession: { selection = .session($0) },
                onShowAllSessions: { columnVisibility = .all }
            )
        case .quality:
            QualityView()
        case .session(let id):
            SessionDetailView(sessionID: id, onDeleted: { selection = .record })
                .id(id)
        }
    }

    private var isRecordingUIVisible: Bool {
        switch recorder.phase {
        case .preparing, .recording, .stopping, .finalizing: true
        case .idle, .stopped, .interrupted: false
        }
    }

    private func delete(_ session: DriveSession) {
        if selection == .session(session.id) { selection = .record }
        try? model.store.delete(session, filesRoot: model.filesRoot)
    }
}

/// Record / Quality: 52 pt rows, amber icon when selected (mock 11).
private struct IPadNavRow: View {
    let title: LocalizedStringKey
    let systemImage: String
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: systemImage)
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(isSelected ? Theme.accent : Theme.textTertiary)
                .frame(width: 24)
            Text(title)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
        }
        .frame(maxWidth: .infinity, minHeight: IPadMetrics.minTouch, alignment: .leading)
    }
}

/// Sidebar row: route thumbnail, title with badge, date and the key figures.
private struct IPadSessionRow: View {
    let session: DriveSession
    let format: SessionFormat
    let isRecording: Bool

    var body: some View {
        if session.isDeleted || session.modelContext == nil {
            EmptyView()
        } else {
            HStack(spacing: 12) {
                IPadRouteThumbnail(points: session.routePreview, dashed: session.state == .recovered)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 8) {
                        Text(verbatim: format.title(session))
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(Theme.textPrimary)
                            .lineLimit(1)
                        if isRecording {
                            SidebarBadge(text: "REC", tint: Theme.rec)
                        } else if session.state == .recovered {
                            SidebarBadge(text: "RECOVERED", tint: Theme.accent)
                        }
                    }
                    Text(verbatim: meta)
                        .font(.hudNumber(size: 13))
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                }
            }
            .padding(.vertical, 10)
            .accessibilityElement(children: .combine)
        }
    }

    /// "Sep 29 · 42:31 · 38.6 km"
    private var meta: String {
        [format.shortDate(session), format.duration(session.duration), format.distance(meters: session.distance).text]
            .joined(separator: " · ")
    }
}

/// Outlined RECOVERED / REC tag. Stays English in both languages, like the HUD labels.
private struct SidebarBadge: View {
    let text: String
    let tint: Color

    var body: some View {
        Text(verbatim: text)
            .font(.system(size: 11, weight: .semibold))
            .tracking(0.9)
            .foregroundStyle(tint)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(tint, lineWidth: 1))
            .fixedSize()
    }
}

private extension View {
    /// Mock sidebar selection: a #1F252C rounded pill instead of the system highlight.
    func sidebarRow(isSelected: Bool) -> some View {
        listRowInsets(EdgeInsets(top: 0, leading: 12, bottom: 0, trailing: 12))
            .listRowSeparator(.hidden)
            .listRowBackground(
                RoundedRectangle(cornerRadius: 12)
                    .fill(isSelected ? Theme.divider : Color.clear)
            )
    }
}
