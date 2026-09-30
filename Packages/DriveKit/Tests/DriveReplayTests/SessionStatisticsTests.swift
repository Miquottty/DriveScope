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

    /// iOS delivers "50 Hz" motion at 49.76 Hz, perfectly regular: that is not loss. Only a real hole counts,
    /// and by how many samples it swallowed.
    @Test func motionDropRateCountsHolesNotIosSampleRate() {
        let clock = SessionClock(startedAt: Date(timeIntervalSince1970: 1_790_000_000), startUptime: 100)
        func dropRate(holeAt: Int?) -> (rate: Double, count: Int) {
            var stats = SessionStatistics(clock: clock, expectedMotionHz: 50)
            var t = 100.0
            for i in 0..<Int(60 * 49.76) {
                t += i == holeAt ? 1.0 : 1 / 49.76
                stats.addMotion(timestamp: t)
            }
            return (stats.summary(duration: 60).motionDropRate, stats.motionCount)
        }

        #expect(dropRate(holeAt: nil).rate == 0)
        // A 1.0 s gap between two samples swallowed 49 samples at the nominal 50 Hz.
        let holed = dropRate(holeAt: 1_000)
        #expect(abs(holed.rate - 49 / Double(holed.count + 49)) < 1e-9)
    }
}

struct BatteryUsageTests {
    /// %/h from 5-minute snapshots, split by screen state; charging and unknown levels are excluded.
    @Test func drainPerHourByScreenState() {
        let unplugged = BatteryUsage.unpluggedState
        let events = [
            EventRecord(kind: .batterySnapshot, aux: unplugged, elapsed: 0, value: 0.90),
            EventRecord(kind: .batterySnapshot, aux: unplugged, elapsed: 600, value: 0.88), // on: 2 % / 10 min
            EventRecord(kind: .screenOff, elapsed: 700),
            EventRecord(kind: .batterySnapshot, aux: unplugged, elapsed: 1800, value: 0.87), // off: 1 % / 20 min
            EventRecord(kind: .batterySnapshot, aux: 2, elapsed: 2400, value: 0.95), // charging: ignored
            EventRecord(kind: .batterySnapshot, aux: unplugged, elapsed: 3000, value: -1), // unknown: ignored
        ]
        let usage = BatteryUsage(events: events)
        #expect(abs((usage.screenOn ?? 0) - 12) < 1e-9)
        #expect(abs((usage.screenOff ?? 0) - 3) < 1e-9)
        #expect(abs((usage.overall ?? 0) - 6) < 1e-9)
        #expect(BatteryUsage(events: []).overall == nil)
    }
}
