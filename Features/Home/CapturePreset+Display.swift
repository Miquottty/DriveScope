import DriveDomain

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
}
