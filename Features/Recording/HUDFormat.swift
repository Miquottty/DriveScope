import DriveDomain
import DriveRecording
import Foundation

/// Text for the Recording HUD. Digits are Latin in both languages (PLAN §13), so no locale is involved.
enum HUDFormat {
    static let placeholder = "--"

    /// `hh:mm:ss`
    static func elapsed(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        return String(format: "%02d:%02d:%02d", total / 3600, total / 60 % 60, total % 60)
    }

    static func speedKmh(_ metersPerSecond: Double?) -> String {
        guard let metersPerSecond else { return placeholder }
        return String(Int(Units.kmh(fromMetersPerSecond: max(0, metersPerSecond)).rounded()))
    }

    static func altitude(_ meters: Double?) -> String {
        guard let meters else { return placeholder }
        return String(Int(meters.rounded()))
    }

    static func course(_ degrees: Double?) -> String {
        guard let degrees else { return placeholder }
        return String(Int(normalized(degrees).rounded()) % 360)
    }

    /// "° W" — the unit slot of COURSE.
    static func courseUnit(_ degrees: Double?) -> String {
        guard let degrees else { return "°" }
        return "° " + cardinal(degrees)
    }

    /// 8-point compass.
    static func cardinal(_ degrees: Double) -> String {
        let points = ["N", "NE", "E", "SE", "S", "SW", "W", "NW"]
        return points[Int((normalized(degrees) / 45).rounded()) % 8]
    }

    static func distanceKm(_ meters: Double) -> String {
        String(format: "%.1f", max(0, meters) / 1000)
    }

    /// "+0.21" / "−0.08" (typographic minus, as in the mock), always signed so the width never changes.
    static func signedG(_ g: Double) -> String {
        let rounded = (g * 100).rounded() / 100
        let sign = rounded < 0 ? "\u{2212}" : "+"
        return sign + String(format: "%.2f", abs(rounded))
    }

    /// "50 Hz · Logger" — landscape header (mock artboard 8).
    static func presetLabel(_ preset: CapturePreset) -> String {
        let name = switch preset {
        case .gpsOnly: "GPS Only"
        case .eco: "Eco"
        case .vlog: "Vlog"
        case .logger: "Logger"
        case .lab: "Lab"
        }
        let hz = preset.motion.hz
        return hz > 0 ? "\(Int(hz)) Hz · \(name)" : "GPS 1 Hz · \(name)"
    }

    private static func normalized(_ degrees: Double) -> Double {
        let d = degrees.truncatingRemainder(dividingBy: 360)
        return d < 0 ? d + 360 : d
    }
}

/// Accuracy badge in the header. Thresholds follow what the HUD needs to say at a glance:
/// good enough for a clean track / usable / don't trust the line.
enum GPSQuality: Equatable {
    case good, fair, poor, acquiring, searching

    static let goodAccuracy = 10.0
    static let fairAccuracy = 30.0

    init(status: TelemetrySnapshot.GPSStatus, accuracy: Double?) {
        switch status {
        case .acquiring: self = .acquiring
        case .searching: self = .searching
        case .good:
            guard let accuracy, accuracy > 0 else { self = .acquiring; return }
            self = accuracy <= Self.goodAccuracy ? .good : accuracy <= Self.fairAccuracy ? .fair : .poor
        }
    }
}
