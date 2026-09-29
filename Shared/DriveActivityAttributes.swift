import ActivityKit
import Foundation

/// Shared between the app and the widget extension (PLAN §10).
struct DriveActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var elapsed: TimeInterval
        var speedKmh: Double
        var distanceKm: Double
        var gpsAccuracyM: Double
        var lateralG: Double
        var status: String
        var languageCode: String
    }

    var sessionID: UUID
    var startedAt: Date
    var preset: String
}
