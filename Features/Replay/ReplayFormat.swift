import DriveDomain
import Foundation

/// Replay clock and marker labels. Latin digits in both languages (PLAN §13), so no locale is involved.
/// Sessions under an hour read "mm:ss" like the mock; longer ones gain an hour field ("h:mm:ss").
enum ReplayFormat {
    /// Playhead, with tenths: "18:24.5" / "1:18:24.5".
    static func playhead(_ seconds: TimeInterval, longForm: Bool) -> String {
        let tenths = Int((max(0, seconds) * 10).rounded(.down))
        return clock(tenths / 10, longForm: longForm) + ".\(tenths % 10)"
    }

    /// Start / total: "00:00" … "42:31", or "0:00:00" … "2:00:00".
    static func clock(_ seconds: TimeInterval, longForm: Bool) -> String {
        clock(Int(max(0, seconds).rounded(.down)), longForm: longForm)
    }

    static func isLongForm(duration: TimeInterval) -> Bool { duration >= 3600 }

    /// "SYNC 00:00:12" (always h:m:s — the camera-sync offset) / "MARK 12:42".
    static func markerChip(kind: MarkerKind, elapsed: TimeInterval) -> String {
        switch kind {
        case .sync: "SYNC " + HUDFormat.elapsed(elapsed)
        case .mark: "MARK " + clock(elapsed, longForm: isLongForm(duration: elapsed))
        }
    }

    private static func clock(_ total: Int, longForm: Bool) -> String {
        longForm
            ? String(format: "%d:%02d:%02d", total / 3600, total / 60 % 60, total % 60)
            : String(format: "%02d:%02d", total / 60, total % 60)
    }
}
