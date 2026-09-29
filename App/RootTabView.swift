import DriveDomain
import DriveRecording
import SwiftUI

struct RootTabView: View {
    private enum AppTab: Hashable {
        case record, sessions, quality
    }

    @Environment(RecordingController.self) private var recorder
    @State private var selection = AppTab.record
    @State private var sessionsNavigation = SessionsNavigation()
    @State private var locationPermission = LocationPermission()

    var body: some View {
        TabView(selection: $selection) {
            Tab("Record", systemImage: "record.circle", value: AppTab.record) {
                HomeView(
                    permission: locationPermission,
                    onOpenSession: { showSession($0) },
                    onShowAllSessions: { selection = .sessions }
                )
            }
            Tab("Sessions", systemImage: "list.bullet.rectangle", value: AppTab.sessions) {
                SessionsView(navigation: sessionsNavigation)
            }
            Tab("Quality", systemImage: "waveform.path.ecg", value: AppTab.quality) {
                QualityView()
            }
        }
        .tint(Theme.accent)
        .fullScreenCover(isPresented: .constant(isRecordingUIVisible)) {
            RecordingView()
        }
        .onChange(of: recorder.phase) { _, phase in
            guard phase == .stopped else { return }
            if let id = recorder.lastFinishedSessionID { showSession(id) }
            recorder.acknowledgeStopped()
        }
    }

    /// The HUD stays up from START until the session is finalized; the recorder owns when that ends.
    private var isRecordingUIVisible: Bool {
        switch recorder.phase {
        case .preparing, .recording, .stopping, .finalizing: true
        case .idle, .stopped, .interrupted: false
        }
    }

    private func showSession(_ id: UUID) {
        selection = .sessions
        sessionsNavigation.path = [id]
    }
}
