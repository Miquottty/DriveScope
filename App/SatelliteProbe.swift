import DriveDomain
import DriveRecording
import DriveSensors
import Foundation
import Observation

/// The Home screen's satellite search before START (PLAN §11): runs Core Location while Home is on screen so the
/// GPS cell can say whether satellites are locked, and the lock may already be there when recording starts.
/// Judged by `SatelliteFixTracker`, like the HUD.
@MainActor
@Observable
final class SatelliteProbe {
    /// nil while not searching.
    private(set) var status: TelemetrySnapshot.GPSStatus?
    /// Latest satellite fix's horizontal accuracy (m); Wi‑Fi fixes don't count.
    private(set) var accuracy: Double?
    @ObservationIgnored private var tracker: SatelliteFixTracker?

    /// Same threshold as the HUD (watchdog stage 1).
    private static let searchingAfter = RecordingWatchdog.Policy().gpsSearching

    /// Searches until the calling task is cancelled (Home gone, app in the background, START).
    func run(source: any LocationSource) async {
        tracker = SatelliteFixTracker(runStartedAt: Date().timeIntervalSince1970, runStartUptime: Self.uptime)
        accuracy = nil
        refresh()
        // Re-judged every second as well: "searching" comes from silence, not from a fix.
        let ticker = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                refresh()
            }
        }
        // Ends when the calling task is cancelled; the stream's termination stops Core Location.
        for await location in source.locations() { add(location) }
        ticker.cancel()
        tracker = nil
        status = nil
        accuracy = nil
    }

    private func add(_ location: LocationSample) {
        guard var tracker else { return }
        _ = tracker.add(location, uptime: Self.uptime)
        if !tracker.isStale(location), location.isSatelliteFix { accuracy = Double(location.horizontalAccuracy) }
        self.tracker = tracker
        refresh()
    }

    private func refresh() {
        status = tracker?.status(now: Self.uptime, searchingAfter: Self.searchingAfter)
    }

    private static var uptime: TimeInterval { ProcessInfo.processInfo.systemUptime }
}
