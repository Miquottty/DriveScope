import DriveDomain
import DriveStorage
import Foundation

/// Incremental session statistics. The same accumulator runs live during recording and over the `.bin` files
/// when a session is recovered, so both paths agree (PLAN §4.2 "STOP 時に確定、Recovery 時に再計算").
public struct SessionStatistics: Sendable {
    /// Fixes worse than this don't count toward distance / altitude.
    static let maxUsableAccuracy: Float = 30
    /// Barometric climb must exceed this before it counts (sensor noise, pressure drift).
    static let baroHysteresis = 2.0
    static let gpsHysteresis = 6.0

    public let clock: SessionClock
    public let expectedMotionHz: Double

    public private(set) var distance = 0.0
    public private(set) var maxSpeed = 0.0
    public private(set) var lastLocation: LocationSample?
    public private(set) var locationCount = 0
    public private(set) var maxLocationGap: TimeInterval = 0
    public private(set) var motionCount = 0
    public private(set) var peakLateralG = 0.0
    public private(set) var peakGPSLateralG = 0.0
    /// Latest GPS-estimated lateral g (speed × course rate), signed, + = left.
    public private(set) var gpsLateralG = 0.0
    private var accuracies: [Float] = []
    private var firstMotionTimestamp: Double?
    private var lastMotionTimestamp: Double?
    private var baroGain = Climb(hysteresis: baroHysteresis)
    private var gpsGain = Climb(hysteresis: gpsHysteresis)
    private var altitudeCount = 0

    public init(clock: SessionClock, expectedMotionHz: Double) {
        self.clock = clock
        self.expectedMotionHz = expectedMotionHz
    }

    public mutating func add(_ location: LocationSample) {
        defer { lastLocation = location }
        locationCount += 1
        if location.horizontalAccuracy > 0 { accuracies.append(location.horizontalAccuracy) }
        if location.hasValidSpeed { maxSpeed = max(maxSpeed, Double(location.speed)) }
        if location.verticalAccuracy > 0, location.verticalAccuracy <= Self.maxUsableAccuracy {
            gpsGain.add(location.altitude)
        }
        guard let previous = lastLocation else { return }

        maxLocationGap = max(maxLocationGap, location.timestamp - previous.timestamp)
        guard Self.isUsable(previous), Self.isUsable(location) else { return }
        let step = Units.distance(lat1: previous.latitude, lon1: previous.longitude, lat2: location.latitude, lon2: location.longitude)
        // Parked GPS wanders by meters; only count movement the Doppler speed confirms (PLAN Test A).
        let moving = location.hasValidSpeed
            ? location.speed >= 1
            : step > Double(max(previous.horizontalAccuracy, location.horizontalAccuracy)) * 2
        if moving { distance += step }

        let dt = location.timestamp - previous.timestamp
        if dt > 0, dt <= 3, previous.hasValidCourse, location.hasValidCourse, location.speed > 3 {
            // Compass course turns clockwise for a right turn; lateral + = left.
            let rate = -Units.headingDelta(from: Double(previous.course), to: Double(location.course)) * .pi / 180 / dt
            gpsLateralG = Double(location.speed) * rate / Units.g
            peakGPSLateralG = max(peakGPSLateralG, abs(gpsLateralG))
        } else {
            gpsLateralG = 0
        }
    }

    public mutating func add(_ altitude: AltitudeSample) {
        altitudeCount += 1
        baroGain.add(Double(altitude.relativeAltitude))
    }

    public mutating func addMotion(timestamp: Double) {
        motionCount += 1
        if firstMotionTimestamp == nil { firstMotionTimestamp = timestamp }
        lastMotionTimestamp = timestamp
    }

    /// Vehicle-frame lateral g from calibrated motion (S3).
    public mutating func add(lateralG: Double) {
        peakLateralG = max(peakLateralG, abs(lateralG))
    }

    public func summary(duration: TimeInterval) -> SessionSummary {
        var s = SessionSummary()
        s.duration = duration
        s.distance = distance
        s.maxSpeed = maxSpeed
        s.avgSpeed = duration > 0 ? distance / duration : 0
        s.elevationGain = altitudeCount > 1 ? baroGain.gain : gpsGain.gain
        s.peakLateralG = peakLateralG > 0 ? peakLateralG : peakGPSLateralG
        let sorted = accuracies.sorted()
        s.gpsAccuracyP50 = Self.percentile(sorted, 0.50)
        s.gpsAccuracyP95 = Self.percentile(sorted, 0.95)
        s.maxLocationGap = maxLocationGap
        s.locationSampleCount = locationCount
        s.motionSampleCount = motionCount
        if expectedMotionHz > 0, let first = firstMotionTimestamp, let last = lastMotionTimestamp, last > first {
            let expected = (last - first) * expectedMotionHz + 1
            s.motionDropRate = max(0, 1 - Double(motionCount) / expected)
        }
        return s
    }

    /// Recomputes statistics from a session's files (recovery path).
    public static func compute(files: SessionFiles, manifest: SessionManifest) throws -> (SessionStatistics, duration: TimeInterval) {
        var stats = SessionStatistics(clock: manifest.clock, expectedMotionHz: manifest.preset.motion.hz)
        var end = 0.0
        for location in try files.locations() {
            stats.add(location)
            end = max(end, manifest.clock.elapsed(unixTime: location.timestamp))
        }
        for altitude in try files.altitudes() {
            stats.add(altitude)
            end = max(end, manifest.clock.elapsed(uptime: altitude.timestamp))
        }
        switch manifest.motionStream {
        case .motion:
            for sample in try files.deviceMotion() { stats.addMotion(timestamp: sample.timestamp) }
        case .accel:
            for sample in try files.accelerations() { stats.addMotion(timestamp: sample.timestamp) }
        default:
            break
        }
        if let last = stats.lastMotionTimestamp { end = max(end, manifest.clock.elapsed(uptime: last)) }
        return (stats, end)
    }

    static func isUsable(_ location: LocationSample) -> Bool {
        location.horizontalAccuracy > 0 && location.horizontalAccuracy <= maxUsableAccuracy
    }

    static func percentile(_ sorted: [Float], _ p: Double) -> Double {
        guard !sorted.isEmpty else { return 0 }
        let rank = p * Double(sorted.count - 1)
        let lo = Int(rank.rounded(.down)), hi = Int(rank.rounded(.up))
        return Double(sorted[lo]) + Double(sorted[hi] - sorted[lo]) * (rank - Double(lo))
    }
}

/// Cumulative ascent with hysteresis: climbs count only once they exceed `hysteresis` above the last low point.
struct Climb: Sendable {
    let hysteresis: Double
    private(set) var gain = 0.0
    private var reference: Double?

    init(hysteresis: Double) {
        self.hysteresis = hysteresis
    }

    mutating func add(_ altitude: Double) {
        guard let ref = reference else {
            reference = altitude
            return
        }
        if altitude > ref + hysteresis {
            gain += altitude - ref
            reference = altitude
        } else if altitude < ref - hysteresis {
            reference = altitude
        }
    }
}
