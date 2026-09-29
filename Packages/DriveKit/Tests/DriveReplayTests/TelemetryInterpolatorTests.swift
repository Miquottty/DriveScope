import DriveDomain
import DriveRecording
import DriveReplay
import DriveSensors
import DriveStorage
import Foundation
import Testing

struct TelemetryInterpolatorTests {
    /// PLAN S5 exit: a 2-hour Logger log opens instantly, and frames reproduce the drive — position, speed,
    /// circular course, calibrated lateral g sign in corners, and GPS gaps (tunnel) flagged.
    @Test func twoHourLogOpensInstantlyAndFramesMatchTheScript() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "DriveScopeReplay-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let script = DriveScript.akagi
        let built = try await ScriptedSessionBuilder.write(script: script, preset: .logger, duration: 2 * 3600, root: root)
        let files = SessionFiles(root: root, sessionID: built.manifest.sessionID)

        let opened = ContinuousClock.now
        let reader = try TelemetryReader(files: files)
        let interpolator = TelemetryInterpolator(reader: reader)
        _ = interpolator.frame(at: 3600)
        #expect(ContinuousClock.now - opened < .milliseconds(100))
        #expect(reader.motion.count >= 2 * 3600 * 50)

        var cornersChecked = 0
        for t in stride(from: 30.5, to: script.duration - 5, by: 7) {
            let s = script.state(at: t)
            let frame = interpolator.frame(at: t)
            if s.inTunnel {
                #expect(!frame.hasFix, "t=\(t)")
                continue
            }
            #expect(Units.distance(lat1: frame.latitude, lon1: frame.longitude, lat2: s.latitude, lon2: s.longitude) < 25, "t=\(t)")
            #expect(abs(frame.speed - s.speed) < 1.5, "t=\(t)")
            #expect(abs(Units.headingDelta(from: s.course, to: frame.course)) < 20 || s.speed < 3, "t=\(t)")
            if abs(s.lateralAcceleration) > 0.15 * Units.g {
                #expect(frame.lateralG.sign == s.lateralAcceleration.sign, "t=\(t)")
                cornersChecked += 1
            }
        }
        #expect(cornersChecked > 5)
    }

    /// Course interpolates the short way around north.
    @Test func courseInterpolatesAcrossNorth() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "DriveScopeReplay-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let clock = SessionClock(startedAt: Date(timeIntervalSince1970: 1_790_000_000), startUptime: 0)
        let manifest = SessionManifest(sessionID: UUID(), clock: clock, timeZoneID: "UTC", preset: .gpsOnly, appVersion: "", deviceModel: "", osVersion: "")
        let files = SessionFiles(root: root, sessionID: manifest.sessionID)
        try files.createDirectory()
        try files.writeManifest(manifest)
        let writer = try SampleWriter(files: files, kinds: [.location], createdAt: 0)
        for (i, course) in [350.0, 10.0].enumerated() {
            await writer.append(LocationSample(
                timestamp: 1_790_000_000 + Double(i), latitude: 36, longitude: 139, altitude: 0, receivedUptime: Double(i),
                speed: 10, course: Float(course), horizontalAccuracy: 5, verticalAccuracy: 5, speedAccuracy: 1, courseAccuracy: 1
            ), to: .location)
        }
        await writer.close()
        let frame = TelemetryInterpolator(reader: try TelemetryReader(files: files)).frame(at: 0.5)
        #expect(abs(frame.course - 0) < 1e-6 || abs(frame.course - 360) < 1e-6)
    }
}

struct PresetReplayTests {
    /// PLAN DoD: every preset records and replays — the right motion file (or none), the expected rate, and frames
    /// with position and speed; G comes from motion when recorded, from GPS otherwise.
    @Test func everyPresetRecordsAndReplays() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "DriveScopePresets-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        for preset in CapturePreset.allCases {
            let built = try await ScriptedSessionBuilder.write(script: .akagi, preset: preset, duration: 120, root: root)
            let reader = try TelemetryReader(files: SessionFiles(root: root, sessionID: built.manifest.sessionID))
            let motionCount = reader.motion.count + reader.accelerations.count
            #expect(abs(Double(motionCount) - preset.motion.hz * 120) <= preset.motion.hz + 1, "\(preset)")
            #expect(preset == .eco ? !reader.accelerations.isEmpty : reader.accelerations.isEmpty, "\(preset)")
            #expect(reader.locations.count >= 115, "\(preset)")

            let frame = TelemetryInterpolator(reader: reader).frame(at: 40) // moving (the scripted light is ~70–90 s)
            #expect(frame.hasFix && frame.speed > 5, "\(preset)")
            #expect(built.summary.distance > 1_000, "\(preset)")
        }
    }
}
