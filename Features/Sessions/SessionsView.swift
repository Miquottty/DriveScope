import DriveRecording
import DriveDomain
import DriveStorage
import SwiftData
import SwiftUI

struct SessionsView: View {
    @Bindable var navigation: SessionsNavigation

    @Environment(AppModel.self) private var model
    @Environment(RecordingController.self) private var recorder
    @Environment(AppLanguage.self) private var appLanguage
    @Query(sort: \DriveSession.startedAt, order: .reverse, sectionBy: \DriveSession.monthSection)
    private var sections: SectionedResults<DriveSession, String>

    @State private var pendingDelete: DriveSession?
    @State private var deleteError: String?

    var body: some View {
        let format = SessionFormat(language: appLanguage)

        NavigationStack(path: $navigation.path) {
            VStack(alignment: .leading, spacing: 0) {
                header(format)
                if sections.isEmpty {
                    emptyState
                } else {
                    list(format)
                }
            }
            .padding(.top, 8)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Theme.background)
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(for: UUID.self) { SessionDetailView(sessionID: $0) }
        }
        .relocalizing(appLanguage)
        .confirmationDialog(
            "Delete this session?",
            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                if let session = pendingDelete { delete(session) }
                pendingDelete = nil
            }
        } message: {
            Text("The recorded data is removed from this device.")
        }
        .alert(
            "Could not delete the session",
            isPresented: Binding(get: { deleteError != nil }, set: { if !$0 { deleteError = nil } })
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(verbatim: deleteError ?? "")
        }
    }

    // MARK: Pieces

    private func header(_ format: SessionFormat) -> some View {
        let count = sections.reduce(0) { $0 + $1.count }
        let meters = sections.reduce(0.0) { total, section in total + section.reduce(0.0) { $0 + $1.distance } }
        return HStack(alignment: .firstTextBaseline) {
            Text("Sessions")
                .font(.system(size: 28, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
            Spacer()
            if count > 0 {
                Text(verbatim: appLanguage.string("\(count) drives") + " · " + format.distance(meters: meters).text)
                    .font(.hudNumber(size: 12))
                    .foregroundStyle(Theme.textSecondary)
            }
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 10)
    }

    private func list(_ format: SessionFormat) -> some View {
        List {
            ForEach(sections) { section in
                Section {
                    ForEach(section) { session in
                        SessionRow(session: session, format: format) {
                            navigation.path.append(session.id)
                        }
                        .listRowInsets(EdgeInsets(top: 4, leading: 20, bottom: 4, trailing: 20))
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            // The session being recorded right now keeps its files.
                            if recorder.session?.id != session.id {
                                Button("Delete", role: .destructive) { pendingDelete = session }
                                    .tint(Theme.rec)
                            }
                        }
                    }
                } header: {
                    Text(verbatim: format.monthTitle(section.title))
                        .font(.system(size: 12, weight: .medium))
                        .tracking(0.96)
                        .textCase(.uppercase)
                        .foregroundStyle(Theme.textSecondary)
                        .padding(.horizontal, 20)
                        .padding(.top, 10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .listRowInsets(EdgeInsets())
                }
            }
        }
        .listStyle(.plain)
        .listSectionSpacing(.compact)
        .scrollContentBackground(.hidden)
        .accessibilityIdentifier("sessionsList")
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "road.lanes")
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

    private func delete(_ session: DriveSession) {
        do {
            try model.store.delete(session, filesRoot: model.filesRoot)
        } catch {
            deleteError = String(describing: error)
        }
    }
}

private struct SessionRow: View {
    let session: DriveSession
    let format: SessionFormat
    let open: () -> Void

    var body: some View {
        // A session deleted from the detail screen: this row (off-screen under the pushed detail) can be re-evaluated
        // before the query drops it, and reading a deleted model traps.
        if session.isDeleted || session.modelContext == nil {
            EmptyView()
        } else {
            row
        }
    }

    private var row: some View {
        Button(action: open) {
            HStack(spacing: 12) {
                RouteThumbnail(points: session.routePreview, dashed: session.state == .recovered)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 8) {
                        Text(verbatim: format.title(session))
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(Theme.textPrimary)
                            .lineLimit(1)
                        badge
                    }
                    Text(verbatim: format.dateLine(session))
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textSecondary)
                    Text(verbatim: format.metaLine(session))
                        .font(.hudNumber(size: 12))
                        .foregroundStyle(Theme.textTertiary)
                        .lineLimit(2)
                        .padding(.top, 2)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.textMuted)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 14))
            .overlay {
                if session.state == .recovered {
                    RoundedRectangle(cornerRadius: 14).strokeBorder(Theme.accent.opacity(0.25), lineWidth: 1)
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("sessionRow")
    }

    @ViewBuilder private var badge: some View {
        switch session.state {
        case .recovered: SessionBadge(text: "RECOVERED", tint: Theme.accent)
        case .recording: SessionBadge(text: "REC", tint: Theme.rec)
        case .stopped, .discarded: EmptyView()
        }
    }
}

private struct SessionBadge: View {
    let text: String
    let tint: Color

    var body: some View {
        // HUD-style abbreviations stay English.
        Text(verbatim: text)
            .font(.system(size: 10, weight: .semibold))
            .tracking(0.8)
            .foregroundStyle(tint)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(tint.opacity(0.15), in: RoundedRectangle(cornerRadius: 4))
    }
}
