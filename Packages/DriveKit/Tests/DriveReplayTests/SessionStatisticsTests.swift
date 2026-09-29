import DriveDomain
import DriveReplay
import DriveSensors
import Foundation
import Testing

struct SessionStatisticsTests {
    /// PLAN Test A: a parked phone's GPS wanders several meters; none of it may count as distance or climb,
    /// and gaps / accuracy percentiles must still be reported.
    @Test func parkedDriftAddsNoDistanceOrClimb() {
        let clock = SessionClock(startedAt: Date(timeIntervalSince1970: 1_790_000_000), startUptime: 100)
        var stats = SessionStatistics(clock: clock, expectedMotionHz: 50)
        var rng = SplitMix64(seed: 9)
        var t = 1_790_000_000.0
        for i in 0..<600 {
            t += i == 300 ? 12 : 1 // one 12 s gap
            stats.add(LocationSample(
                timestamp: t, latitude: 36.4 + rng.symmetric(4.0) / 111_000, longitude: 139.1 + rng.symmetric(4.0) / 90_000,
                altitude: 120 + rng.symmetric(4.0), receivedUptime: 100 + t - 1_790_000_000,
                speed: Float(abs(rng.symmetric(0.3))), course: -1, horizontalAccuracy: i < 540 ? 5 : 20,
                verticalAccuracy: 6, speedAccuracy: 0.5, courseAccuracy: -1
            ))
            stats.add(AltitudeSample(timestamp: 100 + Double(i), relativeAltitude: Float(rng.symmetric(0.8)), pressure: 100))
        }
        let summary = stats.summary(duration: 611)
        #expect(summary.distance == 0)
        #expect(summary.elevationGain == 0)
        #expect(summary.maxLocationGap == 12)
        #expect(summary.gpsAccuracyP50 == 5)
        #expect(summary.gpsAccuracyP95 == 20)
        #expect(summary.peakLateralG == 0)
    }
}
