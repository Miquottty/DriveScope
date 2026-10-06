#if canImport(SwiftData)
import DriveDomain
import DriveStorage
import Foundation

/// Compresses finished sessions (V1.1, PLAN §4.4): on demand from Session Detail, and a sweep of sessions older
/// than the setting at launch and after each STOP. One session at a time, off the main actor; never the live
/// session, never while recording, never in Low Power Mode.
@MainActor
public final class SessionArchiveService {
    private let store: SessionStore
    private let filesRoot: URL
    private let recorder: RecordingController
    private var sweeping = false

    public init(store: SessionStore, filesRoot: URL, recorder: RecordingController) {
        self.store = store
        self.filesRoot = filesRoot
        self.recorder = recorder
    }

    /// false when the session isn't eligible or archiving failed (the raw files are then untouched).
    @discardableResult
    public func archive(_ session: DriveSession) async -> Bool {
        guard session.state == .stopped || session.state == .recovered, session.archivedAt == nil,
              session.id != recorder.session?.id else { return false }
        do {
            try await Self.run(SessionFiles(root: filesRoot, sessionID: session.id))
        } catch {
            return false
        }
        session.archivedAt = Date()
        try? store.save()
        return true
    }

    /// Archives every finished session that ended more than `days` ago (0 = off).
    public func sweep(olderThanDays days: Int, now: Date = Date()) async {
        guard days > 0, !sweeping else { return }
        sweeping = true
        defer { sweeping = false }
        let cutoff = now.addingTimeInterval(-Double(days) * 86_400)
        for session in store.allSessions() where session.archivedAt == nil && (session.endedAt ?? session.startedAt) < cutoff {
            guard recorder.phase == .idle || recorder.phase == .stopped, !ProcessInfo.processInfo.isLowPowerModeEnabled else { return }
            await archive(session)
        }
    }

    @concurrent nonisolated private static func run(_ files: SessionFiles) async throws {
        try SessionArchiver.archive(files)
    }
}
#endif
