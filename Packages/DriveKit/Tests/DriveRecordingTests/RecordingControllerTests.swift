import DriveDomain
import DriveRecording
import DriveSensors
import DriveStorage
import Foundation
import SwiftData
import Testing

@MainActor
struct RecordingControllerTests {
    /// START → record a scripted drive at 100× through the real engine and writer → MARK → STOP: the state machine,
    /// the files on disk and the persisted statistics must agree with the script.
    @Test func recordsScriptedDriveEndToEnd() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "DriveScopeRecording-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SessionStore(context: .init(try SessionStore.makeContainer(inMemory: true)))
        let controller = RecordingController(
            store: store, filesRoot: root,
            environment: AppEnvironment(appVersion: "test", deviceModel: "test", osVersion: "test"),
            makeSuite: { ScriptPlayback.suite(script: .akagi, rate: 100, label: "test") }
        )

        await controller.start(preset: .logger)
        #expect(controller.phase == .recording)
        let id = try #require(controller.session?.id)

        // Progress-based waits (not fixed sleeps) so slower CI runners behave the same.
        try await waitUntil { controller.live.snapshot.locationCount > 120 }
        await controller.mark(.sync)
        try await waitUntil { controller.live.snapshot.locationCount >= 230 }
        await controller.stop()
        #expect(controller.phase == .stopped)

        let session = try #require(store.session(id: id))
        let files = SessionFiles(root: root, sessionID: id)
        let locations = try files.locations()
        let motion = try files.deviceMotion()
        let events = try files.events()

        // ≥ 230 s of drive at 1 Hz GPS and 50 Hz motion.
        #expect(session.state == .stopped)
        #expect((220...400).contains(locations.count))
        #expect(session.locationSampleCount == locations.count)
        #expect(Double(motion.count) > session.duration * 50 * 0.9)
        #expect(session.motionDropRate < 0.1)
        #expect(session.markers.count == 1 && session.markers.first?.kind == .sync)
        #expect(events.contains { $0.kind == .marker && $0.aux == 1 })

        // Distance along the script, within GPS noise.
        let scripted = DriveScript.akagi.state(at: session.duration).distance
        #expect(abs(session.distance - scripted) < scripted * 0.1 + 30)
        #expect(!session.routePreview.isEmpty)
        #expect(try files.readManifest().altitudeBaseline != nil)
        // The scripted stop-and-go at ~1 km lets the engine calibrate the mount (persisted in both places).
        #expect(session.calibration != nil)
        #expect(try files.readManifest().calibration == session.calibration)
        #expect(events.contains { $0.kind == .calibrationUpdated })
    }

    private func waitUntil(timeout: TimeInterval = 30, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else {
                Issue.record("condition not met within \(timeout) s")
                return
            }
            try await Task.sleep(for: .milliseconds(50))
        }
    }
}
