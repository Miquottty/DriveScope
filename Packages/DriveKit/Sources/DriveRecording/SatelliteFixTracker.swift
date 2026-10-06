import DriveDomain
import Foundation

/// Whether a run has a satellite fix (PLAN §9.3). Before the first lock — minutes under a roof — Core Location may
/// deliver only Wi‑Fi / cell fixes, which carry no speed: the HUD must not call that "good". Shared by the
/// recording engine and the Home screen's pre-START search so both judge fixes the same way.
public struct SatelliteFixTracker: Sendable {
    /// Fixes stamped this long before the run are still accepted (a fix computed just before START).
    public static let staleFixTolerance: TimeInterval = 2

    /// Unix time the run (START, resume, or the Home search) began.
    private let runStartedAt: TimeInterval
    private let runStartUptime: TimeInterval
    /// Seconds from the run's start to its first satellite fix.
    public private(set) var firstFixAfter: TimeInterval?
    private var lastSatelliteUptime: TimeInterval?

    public init(runStartedAt: TimeInterval, runStartUptime: TimeInterval) {
        self.runStartedAt = runStartedAt
        self.runStartUptime = runStartUptime
    }

    /// Core Location hands over its cached fix first — on a device seen 2 minutes old, elsewhere — which is not a
    /// sample of this run (nor a sign that GPS is alive).
    public func isStale(_ location: LocationSample) -> Bool {
        location.timestamp < runStartedAt - Self.staleFixTolerance
    }

    /// Feeds a fix received at `uptime`. Returns the seconds since the run began when this is the run's first
    /// satellite fix, nil otherwise.
    public mutating func add(_ location: LocationSample, uptime: TimeInterval) -> TimeInterval? {
        guard !isStale(location), location.isSatelliteFix else { return nil }
        lastSatelliteUptime = uptime
        guard firstFixAfter == nil else { return nil }
        let after = max(0, uptime - runStartUptime)
        firstFixAfter = after
        return after
    }

    /// Acquiring until the first satellite fix, however long that takes; once locked, searching after
    /// `searchingAfter` seconds without one (even while Wi‑Fi fixes keep arriving).
    public func status(now: TimeInterval, searchingAfter: TimeInterval) -> TelemetrySnapshot.GPSStatus {
        guard let lastSatelliteUptime else { return .acquiring }
        return now - lastSatelliteUptime > searchingAfter ? .searching : .good
    }
}
