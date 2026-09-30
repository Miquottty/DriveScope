import DriveDomain
import DriveRecording
import DriveReplay
import DriveSensors
import DriveStorage
import Foundation
import Synchronization
import SwiftData
import Testing

/// Offline geocoder: names places by latitude band; can be switched to fail like a device without network.
final class FakeGeocoder: ReverseGeocoder {
    let failing = Mutex(false)
    func place(latitude: Double, longitude: Double, role: PlaceRole, locale: Locale) async throws -> PlaceMeta {
        if failing.withLock({ $0 }) { throw URLError(.notConnectedToInternet) }
        return PlaceMeta(locality: latitude < 36.45 ? "前橋市" : "渋川市", latitude: latitude, longitude: longitude, role: role)
    }
}

@MainActor
struct SessionFinalizerTests {
    /// PLAN §8: places for start / end / highest point and an automatic "A → B" title; offline leaves the
    /// session pending and a later retry completes it; a user-edited title is never overwritten.
    @Test func titlesFromPlacesAndRetriesWhenOffline() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "DriveScopeFinalizer-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SessionStore(context: .init(try SessionStore.makeContainer(inMemory: true)))
        let clock = SessionClock(startedAt: Date(timeIntervalSince1970: 1_790_000_000), startUptime: 0)
        let manifest = SessionManifest(sessionID: UUID(), clock: clock, timeZoneID: "Asia/Tokyo", preset: .gpsOnly, appVersion: "t", deviceModel: "t", osVersion: "t")
        let files = SessionFiles(root: root, sessionID: manifest.sessionID)
        let writer = try SampleWriter(files: files, kinds: [.location], createdAt: 0)
        let script = DriveScript.akagi
        for t in stride(from: 0.0, to: script.duration, by: 5) {
            let s = script.state(at: t)
            await writer.append(LocationSample(
                timestamp: clock.startedAt.timeIntervalSince1970 + t, latitude: s.latitude, longitude: s.longitude,
                altitude: s.altitude, receivedUptime: t, speed: Float(s.speed), course: Float(s.course),
                horizontalAccuracy: 5, verticalAccuracy: 5, speedAccuracy: 0.5, courseAccuracy: 3
            ), to: .location)
        }
        await writer.close()
        let session = try store.create(manifest: manifest)
        session.state = .stopped

        let geocoder = FakeGeocoder()
        geocoder.failing.withLock { $0 = true }
        let finalizer = SessionFinalizer(store: store, filesRoot: root, geocoder: geocoder, locale: { Locale(identifier: "ja") }, loopWord: { "ループ" })
        await finalizer.finalize(session)
        #expect(session.geocodePending)
        #expect(session.title.isEmpty)

        geocoder.failing.withLock { $0 = false }
        await finalizer.retryPending()
        #expect(!session.geocodePending)
        #expect(session.title == "前橋市 → 渋川市")
        // The highest point is the destination (Onuma), so it is not geocoded twice; via points are.
        #expect(session.viaPlaces.filter { $0.role == .via }.count == 2)
        #expect(!session.viaPlaces.contains { $0.role == .maxAltitude })

        session.title = "赤城峠"
        session.titleIsUserEdited = true
        await finalizer.finalize(session)
        #expect(session.title == "赤城峠")
        #expect(SessionTitle.make(start: session.startPlace, end: session.startPlace, loopWord: "Loop") == "前橋市 · Loop")
        // One-way within one town (~3 km) is neither a loop nor "A → A".
        let across = PlaceMeta(locality: "前橋市", latitude: 36.41, longitude: 139.08, role: .end)
        #expect(SessionTitle.make(start: session.startPlace, end: across, loopWord: "Loop") == "前橋市")
    }

    /// First real drive, after STOP: the live calibration came from the phone still in the hand, the phone spent a
    /// while out of the mount, and the manifest had lost the start's fraction of a second and had no end.
    /// Reprocessing solves the mount from the whole drive, ignores G out of the mount, and repairs the manifest.
    @Test func reprocessingSolvesMountAndRepairsLegacyManifest() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "DriveScopeReprocess-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        // Landscape in the holder (device −x up); in the hand: portrait, tilted toward the face.
        let truth = MountCalibration(rotation: [0, 0, -1, 0, -1, 0, -1, 0, 0], method: .manual, confidence: 1, calibratedAtElapsed: 0)
        let hand = MountCalibration(rotation: [1, 0, 0, 0, 0.6, -0.8, 0, 0.8, 0.6], method: .auto, confidence: 0.51, calibratedAtElapsed: 2)
        let offMount = 300.0..<330.0
        let startedAt = Date(timeIntervalSince1970: 1_790_728_557.8)
        let built = try await ScriptedSessionBuilder.write(
            script: .akagi, preset: .logger, duration: 600, root: root, mount: truth, startedAt: startedAt,
            calibrated: false, mountAt: { t in t < 15 || offMount.contains(t) ? hand : truth }
        )
        let files = SessionFiles(root: root, sessionID: built.manifest.sessionID)
        var legacy = try files.readManifest()
        legacy.clock.startedAt = Date(timeIntervalSince1970: 1_790_728_557)
        legacy.endedAt = nil
        legacy.calibration = hand
        try files.writeManifest(legacy)

        let store = SessionStore(context: .init(try SessionStore.makeContainer(inMemory: true)))
        let session = try store.create(manifest: built.manifest)
        session.state = .stopped
        session.endedAt = startedAt.addingTimeInterval(600)
        session.calibration = hand
        let finalizer = SessionFinalizer(store: store, filesRoot: root, geocoder: FakeGeocoder(), locale: { Locale(identifier: "ja") }, loopWord: { "ループ" })
        await finalizer.ensureSections(session)

        let repaired = try files.readManifest()
        #expect(abs(repaired.clock.startedAt.timeIntervalSince(startedAt)) < 0.001)
        #expect(repaired.endedAt != nil)
        let solved = try #require(session.calibration)
        #expect(solved.method == .auto)
        for row in 0..<3 {
            let dot = (0..<3).reduce(0.0) { $0 + solved.rotation[row * 3 + $1] * truth.rotation[row * 3 + $1] }
            #expect(dot > 0.98, "axis \(row)")
        }
        #expect(repaired.calibration == solved)

        let interpolator = TelemetryInterpolator(reader: try TelemetryReader(files: files), calibration: solved)
        #expect(interpolator.frame(at: 100).hasMotionG)
        #expect(interpolator.frame(at: 450).hasMotionG)
        #expect(!interpolator.frame(at: 315).hasMotionG)
        #expect(!interpolator.frame(at: 5).hasMotionG)
        if let peak = session.peakLateralElapsed { #expect(!offMount.contains(peak)) }
        #expect(session.sectionsVersion == SectionDetector.version)
    }
}
