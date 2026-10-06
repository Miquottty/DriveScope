import DriveDomain
import DriveRecording
import DriveReplay
import DriveSensors
import DriveStorage
import Foundation
import SwiftData
import Testing

@MainActor
struct RecordingControllerTests {
    /// START → record a scripted drive at 100× through the real engine and writer → SYNC / MARK → STOP: the state machine,
    /// the files on disk and the persisted statistics must agree with the script. Core Location's cached fix
    /// (delivered first, 2 min old, elsewhere) must not become part of the drive, and the satellite lock after
    /// 10 s of Wi‑Fi-only fixes is logged once.
    @Test func recordsScriptedDriveEndToEnd() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "DriveScopeRecording-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SessionStore(context: .init(try SessionStore.makeContainer(inMemory: true)))
        let controller = RecordingController(
            store: store, filesRoot: root,
            environment: AppEnvironment(appVersion: "test", deviceModel: "test", osVersion: "test"),
            makeSuite: {
                var suite = ScriptPlayback.suite(script: .akagi, rate: 100, label: "test")
                let coarse = CoarseStartLocationSource(inner: suite.location, clock: suite.clock, delay: 10)
                suite.location = CachedFixFirst(inner: coarse, clock: suite.clock)
                return suite
            }
        )

        await controller.start(preset: .logger)
        #expect(controller.phase == .recording)
        let id = try #require(controller.session?.id)

        // Progress-based waits (not fixed sleeps) so slower CI runners behave the same.
        try await waitUntil { controller.live.snapshot.locationCount > 120 }
        // SYNC (V1.2): the marker sits at the beep's onset, the tap goes to the event value.
        let tapped = Date(timeIntervalSince1970: 1_790_000_100.5)
        let beep = SyncBeep(onsetUptime: ProcessInfo.processInfo.systemUptime + 0.1, outputLatency: 0.012, route: .wireless)
        await controller.sync(beep: beep, pressedAt: tapped)
        await controller.mark(.highlight)
        // A watch MARK (V1.1): marker at the iPhone's receive time, the wrist's press time in the event value.
        let pressed = Date(timeIntervalSince1970: 1_790_000_123.25)
        await controller.mark(.mark, source: .watch, pressedAt: pressed)
        try await waitUntil { controller.live.snapshot.locationCount >= 230 }
        await controller.stop()
        #expect(controller.phase == .stopped)

        let session = try #require(store.session(id: id))
        let files = SessionFiles(root: root, sessionID: id)
        let locations = try files.locations()
        let motion = try files.deviceMotion()
        let events = try files.events()

        #expect(locations.allSatisfy { $0.timestamp >= session.startedAt.timeIntervalSince1970 - 2 })
        // ≥ 230 s of drive at 1 Hz GPS and 50 Hz motion.
        #expect(session.state == .stopped)
        #expect((220...400).contains(locations.count))
        #expect(session.locationSampleCount == locations.count)
        #expect(Double(motion.count) > session.duration * 50 * 0.9)
        #expect(session.motionDropRate < 0.1)
        // The beep is ahead of the tap, so the markers' order depends on the 100× clock: compare as a set.
        #expect(Set(session.sortedMarkers.map(\.kind)) == [.sync, .highlight, .mark])
        // events.bin tells the kinds apart by aux (JSON export, Quality); file order is call order.
        let markerEvents = events.filter { $0.kind == .marker }
        #expect(markerEvents.map(\.aux) == [1, 2, 0])
        #expect(markerEvents.map(\.source) == [.phone, .phone, .watch])
        let syncMark = markerEvents[0]
        let beepEvent = try #require(events.first { $0.kind == .syncBeep })
        #expect(syncMark.value == tapped.timeIntervalSince1970)
        #expect(beepEvent.elapsed == syncMark.elapsed && beepEvent.aux == 1 && beepEvent.value == 0.012)
        #expect(session.sortedMarkers.contains { $0.kind == .sync && $0.elapsed == syncMark.elapsed })
        let watchMark = try #require(events.first { $0.kind == .marker && $0.source == .watch })
        #expect(watchMark.value == pressed.timeIntervalSince1970 && watchMark.elapsed > 0)

        let lock = try #require(events.first { $0.kind == .satelliteAcquired })
        #expect(events.count { $0.kind == .satelliteAcquired } == 1)
        // Both after the 10 s of Wi‑Fi fixes; the upper bound is loose because at 100× a few ms of runner lag
        // are seconds of script time (the event is stamped on receipt, the Quality figure on the fix).
        #expect((9...20).contains(lock.value))
        let report = try QualityReport.make(files: files)
        #expect((9...20).contains(try #require(report.firstSatelliteFix)))

        // Distance along the script, within GPS noise.
        let scripted = DriveScript.akagi.state(at: session.duration).distance
        #expect(abs(session.distance - scripted) < scripted * 0.1 + 30)
        #expect(!session.routePreview.isEmpty)
        #expect(try files.readManifest().altitudeBaseline != nil)
        // Exports take `endedAt` from the manifest, which must agree with SwiftData (it was left null).
        let manifestEnd = try #require(files.readManifest().endedAt)
        let sessionEnd = try #require(session.endedAt)
        #expect(abs(manifestEnd.timeIntervalSince(sessionEnd)) < 0.001)
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

/// Core Location's habit on a device: the first fix delivered is the cached one, minutes old and elsewhere.
private struct CachedFixFirst: LocationSource {
    let inner: any LocationSource
    let clock: any TelemetryClock

    func locations() -> AsyncStream<LocationSample> {
        AsyncStream { continuation in
            continuation.yield(LocationSample(
                timestamp: clock.now.timeIntervalSince1970 - 120, latitude: 36.30, longitude: 139.00, altitude: 50,
                receivedUptime: clock.uptime, speed: 0, course: -1, horizontalAccuracy: 8, verticalAccuracy: 8,
                speedAccuracy: 1, courseAccuracy: -1
            ))
            let task = Task {
                for await location in inner.locations() { continuation.yield(location) }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
