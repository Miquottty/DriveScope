import DriveDomain
import DriveStorage
import Foundation
import SwiftData
import Testing

@MainActor
struct SessionStoreTests {
    func fix(_ i: Int, accuracy: Float = 5) -> LocationSample {
        LocationSample(
            timestamp: 1_790_000_000 + Double(i), latitude: 36.0 + Double(i) * 1e-4, longitude: 139.0, altitude: 100,
            receivedUptime: Double(i), speed: 10, course: 90, horizontalAccuracy: accuracy, verticalAccuracy: 4,
            speedAccuracy: 0.5, courseAccuracy: 3
        )
    }

    /// Summary, `.codable` attributes (places, route) and markers must survive a save + refetch, and delete must
    /// take the session folder with it.
    @Test func roundTripAndDelete() throws {
        let container = try SessionStore.makeContainer(inMemory: true)
        let store = SessionStore(context: ModelContext(container))
        let root = FileManager.default.temporaryDirectory.appending(path: "DriveScopeStoreTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }

        let clock = SessionClock(startedAt: Date(timeIntervalSince1970: 1_790_000_000), startUptime: 4242)
        let manifest = SessionManifest(
            sessionID: UUID(), clock: clock, timeZoneID: "Asia/Tokyo", preset: .logger,
            appVersion: "1.0", deviceModel: "iPhone18,1", osVersion: "27.2"
        )
        let files = SessionFiles(root: root, sessionID: manifest.sessionID)
        try files.createDirectory()
        try Data([1, 2, 3]).write(to: files.url(for: .location))

        let session = try store.create(manifest: manifest)
        #expect(session.state == .recording)
        #expect(session.clock == clock)
        try store.addMarker(kind: .mark, elapsed: 30, date: clock.date(elapsed: 30), label: "later", to: session)
        try store.addMarker(kind: .sync, elapsed: 5, date: clock.date(elapsed: 5), to: session)

        var summary = SessionSummary()
        summary.duration = 3600
        summary.distance = 42_000
        summary.locationSampleCount = 3600
        summary.batteryUsagePerHour = 7.5
        session.startPlace = PlaceMeta(locality: "Maebashi", latitude: 36.39, longitude: 139.06, role: .start)
        session.viaPlaces = [PlaceMeta(name: "Pass", latitude: 36.5, longitude: 138.9, role: .via)]
        session.calibration = .identity
        let route = [RoutePoint(latitude: 36.39, longitude: 139.06), RoutePoint(latitude: 36.5, longitude: 138.9)]
        try store.finish(session, state: .stopped, endedAt: clock.date(elapsed: 3600), summary: summary, routePreview: route)

        // A fresh context proves the values were persisted, not just cached on the live object.
        let reread = SessionStore(context: ModelContext(container))
        let loaded = try #require(reread.session(id: manifest.sessionID))
        #expect(loaded.summary == summary)
        #expect(loaded.routePreview == route)
        #expect(loaded.startPlace?.locality == "Maebashi")
        #expect(loaded.viaPlaces.count == 1)
        #expect(loaded.calibration == .identity)
        #expect(loaded.sortedMarkers.map(\.kind) == [.sync, .mark])
        #expect(reread.sessions(in: .stopped).count == 1)
        #expect(reread.sessions(in: .recording).isEmpty)

        try reread.delete(loaded, filesRoot: root)
        #expect(reread.session(id: manifest.sessionID) == nil)
        #expect(!FileManager.default.fileExists(atPath: files.directory.path))
        let orphanMarkers = try reread.context.fetch(FetchDescriptor<Marker>())
        #expect(orphanMarkers.isEmpty)
    }

    @Test func routePreviewDownsamplesKeepingEnds() {
        var fixes = (0..<1000).map { fix($0) }
        fixes[500] = fix(500, accuracy: 80)  // dropped: too inaccurate
        fixes[0] = fix(0, accuracy: -1)  // dropped: invalid; first usable is #1
        let route = SessionStore.routePreview(from: fixes, maxPoints: 200)
        #expect(route.count == 200)
        #expect(route.first?.latitude == fix(1).latitude)
        #expect(route.last?.latitude == fix(999).latitude)

        #expect(SessionStore.routePreview(from: (0..<10).map { fix($0) }).count == 10)
    }
}
