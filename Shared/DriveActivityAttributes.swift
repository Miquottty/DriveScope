import ActivityKit
import Foundation

/// Shared between the app and the widget extension (PLAN §10). One set of attributes draws every surface:
/// Lock Screen, Dynamic Island, StandBy and the `.small` family (CarPlay / Watch Smart Stack).
/// `nonisolated`: ActivityKit uses the conformances off the main actor (both targets default to MainActor).
nonisolated struct DriveActivityAttributes: ActivityAttributes {
    nonisolated struct ContentState: Codable, Hashable {
        nonisolated enum Status: String, Codable, Hashable {
            case recording
            /// No GPS fix for > 15 s (watchdog stage 1). Recording continues.
            case gpsSearching
            /// STOP pressed; files are being finalized.
            case saving
            /// Final state, shown until the activity is dismissed.
            case saved
            /// Never sent by the app: the widget shows a live state past its stale date this way, because the app
            /// stopped updating it (suspended or killed) and a ticking REC clock would claim a recording that is not
            /// happening.
            case interrupted
        }

        /// Wall-clock instant at which elapsed was 0. The widget ticks `Text(timerInterval:)` from it, so the clock
        /// runs between updates (which come only every 2–5 s, and not at all while the app is suspended).
        var timerStart: Date
        /// Elapsed at the time of the update; shown frozen once recording has ended.
        var elapsed: TimeInterval
        /// nil until the first valid speed.
        var speedKmh: Double?
        var distanceKm: Double
        /// nil until the first fix.
        var gpsAccuracyM: Double?
        /// g, + = left.
        var lateralG: Double
        var status: Status
        /// In-app language (PLAN §13); the widget applies it with `.environment(\.locale, …)`.
        var languageCode: String
        var markCount: Int
    }

    var sessionID: UUID
    var startedAt: Date
    /// `CapturePreset.rawValue` (the widget does not link DriveKit).
    var preset: String
}

nonisolated extension DriveActivityAttributes.ContentState.Status {
    /// Recording is running: the timer ticks and MARK / STOP are offered.
    var isLive: Bool { self == .recording || self == .gpsSearching }
}

nonisolated extension DriveActivityAttributes.ContentState {
    /// What the widget draws: a live state whose updates stopped (past its stale date) becomes `.interrupted`,
    /// with the clock frozen at the last reported elapsed.
    func displayed(isStale: Bool) -> Self {
        guard isStale, status.isLive else { return self }
        var state = self
        state.status = .interrupted
        return state
    }
}
