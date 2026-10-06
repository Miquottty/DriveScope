import DriveDomain
import DriveRecording
import Testing

struct SatelliteFixTrackerTests {
    /// A start under a roof, as recorded on 2026-10-06: the cached fix, then Wi‑Fi fixes (no speed) for a while,
    /// then the lock. Wi‑Fi alone must never read as "good", and the lock time is reported once per run.
    @Test func acquiringUntilFirstSatelliteFixThenSearchingWhenItStops() {
        let start = 1_791_279_509.0
        var tracker = SatelliteFixTracker(runStartedAt: start, runStartUptime: 1_000)
        func fix(at t: Double, speed: Float) -> LocationSample {
            LocationSample(
                timestamp: start + t, latitude: 36.3, longitude: 139.4, altitude: 30, receivedUptime: 1_000 + t,
                speed: speed, course: -1, horizontalAccuracy: speed < 0 ? 9.7 : 3, verticalAccuracy: 10,
                speedAccuracy: speed < 0 ? -1 : 0.3, courseAccuracy: -1
            )
        }

        // The cached fix is from minutes ago: ignored even though it carries a speed.
        let cached = fix(at: -120, speed: 0)
        #expect(tracker.isStale(cached))
        #expect(tracker.add(cached, uptime: 1_000) == nil)
        #expect(tracker.status(now: 1_000, searchingAfter: 15) == .acquiring)

        // Wi‑Fi fixes for six minutes: still acquiring, never searching, however good their accuracy.
        for t in stride(from: 0.0, through: 360, by: 6) {
            #expect(tracker.add(fix(at: t, speed: -1), uptime: 1_000 + t) == nil)
        }
        #expect(tracker.status(now: 1_366, searchingAfter: 15) == .acquiring)

        #expect(tracker.add(fix(at: 373, speed: 12.7), uptime: 1_373) == 373)
        #expect(tracker.add(fix(at: 374, speed: 12.8), uptime: 1_374) == nil)
        #expect(tracker.firstFixAfter == 373)
        #expect(tracker.status(now: 1_375, searchingAfter: 15) == .good)

        // Satellites lost while Wi‑Fi continues (a parking garage): searching after 15 s, good again on the next fix.
        _ = tracker.add(fix(at: 380, speed: -1), uptime: 1_380)
        #expect(tracker.status(now: 1_389, searchingAfter: 15) == .good)
        #expect(tracker.status(now: 1_390, searchingAfter: 15) == .searching)
        #expect(tracker.add(fix(at: 395, speed: 3), uptime: 1_395) == nil)
        #expect(tracker.status(now: 1_395, searchingAfter: 15) == .good)
    }
}
