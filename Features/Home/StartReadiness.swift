import DriveRecording
import SwiftUI

/// START's look before recording (PLAN §11): green READY once the Home satellite search has a lock, so the driver
/// can tell from a glance that recording will have speed and position from the first second. Only a hint —
/// START stays available while amber (setting up the cameras under a roof is a normal start).
enum StartReadiness: Equatable {
    /// Not searching: no permission yet, approximate location, or a scripted drive.
    case unknown
    case searching
    case ready

    init(probe status: TelemetrySnapshot.GPSStatus?) {
        switch status {
        case nil: self = .unknown
        case .good?: self = .ready
        case .acquiring?, .searching?: self = .searching
        }
    }

    var fill: Color { self == .ready ? Theme.good : Theme.accent }

    /// The line under START; it carries the state in words too, not only in colour.
    var caption: LocalizedStringKey {
        switch self {
        case .unknown: "Record drive"
        case .searching: "Searching satellites"
        case .ready: "READY · satellites locked"
        }
    }
}
