import DriveDomain
import SwiftUI

extension CapturePreset {
    /// Preset names are product names and stay English in both languages (PLAN §2.2.1).
    var displayName: String {
        switch self {
        case .gpsOnly: "GPS Only"
        case .eco: "Eco"
        case .vlog: "Vlog"
        case .logger: "Logger"
        case .lab: "Lab"
        }
    }

    /// One line on what the preset records and what it gives up (PLAN §2.2.1).
    var summary: LocalizedStringKey {
        switch self {
        case .gpsOnly: "GPS only, no motion sensors. G is estimated from GPS, so peaks are blunted."
        case .eco: "GPS + accelerometer at 10 Hz, gyro off. No attitude or rotation rate."
        case .vlog: "GPS + full device motion at 25 Hz. Nothing lost, smaller files."
        case .logger: "GPS + full device motion at 50 Hz. Nothing lost. Default."
        case .lab: "GPS + full device motion at 100 Hz. Largest files, highest battery use."
        }
    }

    /// Estimated drain in %/h with the screen off (PLAN §2.2.2). Eco / Vlog / Lab are interpolated from the
    /// Logger and GPS Only estimates; real-car test E replaces all of them with measurements.
    var estimatedScreenOffDrain: ClosedRange<Double> {
        switch self {
        case .gpsOnly: 2.0...2.5
        case .eco: 2.1...2.6
        case .vlog: 2.3...2.8
        case .logger: 2.5...3.0
        case .lab: 2.9...3.4
        }
    }
}
