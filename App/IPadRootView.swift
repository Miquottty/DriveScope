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
                .navigationSplitViewColumnWidth(min: 300, ideal: 340, max: 400)
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
            SettingsView()
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
                Label("Record", systemImage: "record.circle")
                    .tag(IPadDestination.record)
                Label("Quality", systemImage: "waveform.path.ecg")
                    .tag(IPadDestination.quality)
            }
            ForEach(sections) { section in
                Section {
                    ForEach(section) { session in
                        IPadSessionRow(session: session, format: format, isRecording: recorder.session?.id == session.id)
                            .tag(IPadDestination.session(session.id))
                            .contextMenu {
                                if recorder.session?.id != session.id {
                                    Button("Delete", systemImage: "trash", role: .destructive) { pendingDelete = session }
                                }
                            }
                    }
                } header: {
                    Text(verbatim: format.monthTitle(section.title))
                }
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .background(Theme.background)
        .navigationTitle(Text(verbatim: "DriveScope"))
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showingSettings = true
                } label: {
                    Label("Settings", systemImage: "gearshape")
                }
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
            SessionDetailView(sessionID: id)
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

/// Sidebar row: route thumbnail, title, date and the key figures.
private struct IPadSessionRow: View {
    let session: DriveSession
    let format: SessionFormat
    let isRecording: Bool

    var body: some View {
        if session.isDeleted || session.modelContext == nil {
            EmptyView()
        } else {
            HStack(spacing: 12) {
                RouteThumbnail(points: session.routePreview, size: CGSize(width: 48, height: 40), dashed: session.state == .recovered)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(verbatim: format.title(session))
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(Theme.textPrimary)
                            .lineLimit(1)
                        if isRecording {
                            Text(verbatim: "REC")
                                .font(.hudNumber(size: 10, weight: .semibold))
                                .foregroundStyle(Theme.rec)
                        } else if session.state == .recovered {
                            Text(verbatim: "RECOVERED")
                                .font(.hudNumber(size: 10, weight: .semibold))
                                .foregroundStyle(Theme.accent)
                        }
                    }
                    Text(verbatim: format.metaLine(session))
                        .font(.hudNumber(size: 11))
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                }
            }
            .padding(.vertical, 4)
            .accessibilityElement(children: .combine)
        }
    }
}
