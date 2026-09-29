#if DEBUG
import DriveDomain
import DriveRecording
import DriveSensors
import DriveStorage
import Foundation

/// `-SeedSession <seconds>`: writes a scripted Logger drive (Akagi) with SYNC / MARK markers, for UI tests and for
/// checking that long logs open instantly (`-SeedSession 7200`). Skipped when an identical seed already exists.
enum DebugSeed {
    static func seedIfRequested(store: SessionStore, filesRoot: URL, arguments: [String] = ProcessInfo.processInfo.arguments) async {
        guard let flag = arguments.firstIndex(of: "-SeedSession"), arguments.indices.contains(flag + 1),
              let duration = TimeInterval(arguments[flag + 1]), duration >= 60 else { return }
        guard !store.allSessions().contains(where: { $0.appVersion == "script" && $0.duration == duration }) else { return }
        do {
            let written = try await write(duration: duration, root: filesRoot)
            let session = try store.create(manifest: written.manifest)
            // `DriveSession(manifest:)` does not copy the calibration; the recorder sets it at STOP.
            session.calibration = written.manifest.calibration
            session.title = "Akagi (seed)"
            try store.finish(
                session, state: .stopped, endedAt: written.manifest.clock.date(elapsed: duration),
                summary: written.summary, routePreview: written.preview
            )
            for (kind, elapsed) in [(MarkerKind.sync, 12.0), (.mark, 762.0), (.mark, duration * 0.55)] where elapsed < duration {
                try store.addMarker(kind: kind, elapsed: elapsed, date: written.manifest.clock.date(elapsed: elapsed), to: session)
            }
        } catch {
            assertionFailure("Seeding failed: \(error)")
        }
    }

    /// Off the main actor: `ScriptedSessionBuilder.write` is nonisolated(nonsending) and would otherwise run its
    /// sample loop (360 k motion samples for 2 h at 50 Hz) on the caller's actor.
    @concurrent
    nonisolated private static func write(
        duration: TimeInterval, root: URL
    ) async throws -> (manifest: SessionManifest, summary: SessionSummary, preview: [RoutePoint]) {
        try await ScriptedSessionBuilder.write(script: .akagi, preset: .logger, duration: duration, root: root)
    }
}
#endif
