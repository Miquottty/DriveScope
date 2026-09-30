import DriveDomain
import DriveReplay
import DriveSensors
import DriveStorage
import Foundation

/// Writes a complete session from a `DriveScript` directly to disk (no clock, no waiting).
/// Used by tests and by the debug "demo session" action, e.g. to check that a 2-hour log opens instantly.
public enum ScriptedSessionBuilder {
    public static func write(
        script: DriveScript, preset: CapturePreset, duration: TimeInterval, root: URL,
        mount: MountCalibration = MotionSynthesizer.portraitDashMount,
        startedAt: Date = Date(timeIntervalSince1970: 1_790_000_000), calibrated: Bool = true
    ) async throws -> (manifest: SessionManifest, summary: SessionSummary, preview: [RoutePoint]) {
        let clock = SessionClock(startedAt: startedAt, startUptime: 1_000)
        var manifest = SessionManifest(
            sessionID: UUID(), clock: clock, timeZoneID: "Asia/Tokyo", preset: preset,
            appVersion: "script", deviceModel: "script", osVersion: "script"
        )
        manifest.altitudeBaseline = script.state(at: 0).altitude
        manifest.calibration = calibrated && preset.motion != .none ? mount : nil
        let files = SessionFiles(root: root, sessionID: manifest.sessionID)
        try files.createDirectory()
        try files.writeManifest(manifest)
        let writer = try SampleWriter(
            files: files, kinds: SessionManifest.streamKinds(for: preset), createdAt: startedAt.timeIntervalSince1970,
            policy: { var p = SampleWriter.Policy(); p.flushThreshold = 4096; return p }()
        )
        var statistics = SessionStatistics(clock: clock, expectedMotionHz: preset.motion.hz)
        let synthesizer = MotionSynthesizer(mount: mount, noise: 0.01)
        var rng = SplitMix64(seed: 11)
        let hz = preset.motion.hz
        var yaw = 0.0
        var locations: [LocationSample] = []

        var nextMotion = 0.0
        for second in 0..<Int(duration) {
            let t = Double(second)
            let s = script.state(at: t)
            if !s.inTunnel {
                let fix = LocationSample(
                    timestamp: clock.startedAt.timeIntervalSince1970 + t, latitude: s.latitude, longitude: s.longitude,
                    altitude: s.altitude, receivedUptime: clock.startUptime + t, speed: Float(s.speed),
                    course: s.speed > 0.5 ? Float(s.course) : -1, horizontalAccuracy: 5, verticalAccuracy: 6,
                    speedAccuracy: 0.4, courseAccuracy: s.speed > 0.5 ? 4 : -1, flags: [.synthetic]
                )
                await writer.append(fix, to: .location)
                statistics.add(fix)
                locations.append(fix)
            }
            let altitude = AltitudeSample(
                timestamp: clock.startUptime + t, relativeAltitude: Float(s.altitude - script.state(at: 0).altitude),
                pressure: 100
            )
            await writer.append(altitude, to: .altitude)
            statistics.add(altitude)

            guard hz > 0 else { continue }
            while nextMotion < t + 1 {
                let m = script.state(at: nextMotion)
                yaw += m.yawRate / hz
                let dynamics = MotionSynthesizer.Dynamics(
                    longitudinal: m.longitudinalAcceleration, lateral: m.lateralAcceleration, yawRate: m.yawRate, yaw: yaw
                )
                switch synthesizer.event(mode: preset.motion, timestamp: clock.startUptime + nextMotion, dynamics: dynamics, rng: &rng) {
                case .deviceMotion(let sample):
                    await writer.append(sample, to: .motion)
                    statistics.addMotion(timestamp: sample.timestamp)
                case .acceleration(let sample):
                    await writer.append(sample, to: .accel)
                    statistics.addMotion(timestamp: sample.timestamp)
                case nil:
                    break
                }
                nextMotion += 1 / hz
            }
        }
        await writer.close()
        manifest.endedAt = clock.date(elapsed: duration)
        try files.writeManifest(manifest)
        return (manifest,statistics.summary(duration: duration), SessionStore.routePreview(from: locations))
    }
}
