import DriveDomain
import DriveRecording
import DriveStorage
import SwiftUI

/// The unfinished session offered for recovery. Text is copied out up front because `discard` deletes the model
/// while the sheet is still animating away.
struct RecoveryCandidate: Identifiable {
    let session: DriveSession
    let id: UUID
    let dateText: String
}

extension View {
    /// Offers to recover or discard sessions left unfinished by a crash or force quit (PLAN §9.2).
    func recoveryPrompt(onRecovered: @escaping (UUID) -> Void) -> some View {
        modifier(RecoveryPrompt(onRecovered: onRecovered))
    }
}

private struct RecoveryPrompt: ViewModifier {
    let onRecovered: (UUID) -> Void

    @Environment(RecordingController.self) private var recorder
    @Environment(AppLanguage.self) private var appLanguage
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var candidate: RecoveryCandidate?
    /// Sessions already offered in this launch: one dismissed without a choice is asked again next launch, not in a loop.
    @State private var offered: Set<UUID> = []

    func body(content: Content) -> some View {
        content
            .task { presentNext() }
            .onChange(of: recorder.phase) { _, phase in
                if phase == .idle {
                    presentNext()
                } else if let current = candidate {
                    // The dead-man notification resumed a recording under the sheet; the HUD takes over.
                    offered.remove(current.id)
                    candidate = nil
                }
            }
            .sheet(item: $candidate, onDismiss: presentNext) { current in
                let sheet = RecoverySheet(
                    candidate: current,
                    onRecovered: { id in
                        candidate = nil
                        onRecovered(id)
                    },
                    onDiscarded: { candidate = nil }
                )
                if horizontalSizeClass == .regular {
                    // iPad: a centered form-width card, as tall as its content.
                    sheet
                        .presentationSizing(.form.fitted(horizontal: false, vertical: true))
                        .environment(\.iPadSheet, true)
                } else {
                    sheet
                }
            }
    }

    /// The most recent unfinished session not yet offered. Never while a recording is live or starting.
    private func presentNext() {
        guard recorder.phase == .idle, candidate == nil,
              let session = recorder.unfinishedSessions().first(where: { !offered.contains($0.id) })
        else { return }
        offered.insert(session.id)
        candidate = RecoveryCandidate(
            session: session, id: session.id, dateText: SessionFormat(language: appLanguage).title(session)
        )
    }
}
