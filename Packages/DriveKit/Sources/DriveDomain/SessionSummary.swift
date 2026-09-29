import Foundation

/// Statistics fixed at STOP and recomputed on recovery (PLAN §4.2). Units: SI (m, m/s, s, g).
public struct SessionSummary: Sendable, Equatable, Codable {
    public var duration: TimeInterval = 0
    public var distance: Double = 0
    public var maxSpeed: Double = 0
    /// distance / duration.
    public var avgSpeed: Double = 0
    public var elevationGain: Double = 0
    /// Peak |lateral g| (vehicle frame when calibrated, GPS-estimated otherwise).
    public var peakLateralG: Double = 0
    public var gpsAccuracyP50: Double = 0
    public var gpsAccuracyP95: Double = 0
    public var maxLocationGap: TimeInterval = 0
    public var locationSampleCount = 0
    public var motionSampleCount = 0
    /// 1 - received / expected motion samples.
    public var motionDropRate: Double = 0
    /// Battery drain, %/h, when measurable (non-charging snapshots).
    public var batteryUsagePerHour: Double?

    public init() {}
}

/// A downsampled route point for list thumbnails and map overviews.
public struct RoutePoint: Sendable, Equatable, Codable {
    public var latitude: Double
    public var longitude: Double

    public init(latitude: Double, longitude: Double) {
        self.latitude = latitude
        self.longitude = longitude
    }
}
