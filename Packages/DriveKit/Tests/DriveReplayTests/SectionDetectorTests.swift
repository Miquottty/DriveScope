import DriveDomain
import DriveRecording
import DriveReplay
import DriveSensors
import DriveStorage
import Foundation
import Testing

struct SectionDetectorTests {
    /// V1.1: on the Akagi script the detector finds the hairpins (count and direction as the same rule finds them in
    /// the ground truth), the one traffic-light stop (the tunnel's GPS gap is not a stop), and the climb.
    @Test func findsCornersStopAndClimbOnAkagi() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "DriveScopeSections-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let script = DriveScript.akagi
        let defaults = DriveScript.Configuration() // Akagi keeps the default stop length and altitudes
        let built = try await ScriptedSessionBuilder.write(script: script, preset: .logger, duration: script.duration, root: root)
        let reader = try TelemetryReader(files: SessionFiles(root: root, sessionID: built.manifest.sessionID))
        let sections = SectionDetector.detect(reader: reader, calibration: reader.manifest.calibration)

        let truth = stride(from: 0.0, through: script.duration, by: 0.2).map { t in
            let s = script.state(at: t)
            return SectionDetector.Sample(
                time: t, lateralG: s.lateralAcceleration / Units.g, speed: s.speed, course: s.course,
                distance: s.distance, altitude: s.altitude
            )
        }
        let reference = SectionDetector.corners(truth)
        let corners = sections.filter { $0.kind == .corner }
        #expect(reference.count >= 10)
        #expect(abs(corners.count - reference.count) <= max(1, reference.count / 10), "\(corners.count) vs \(reference.count)")
        for bend in reference where (bend.peakLateralG ?? 0) >= 0.25 {
            #expect(corners.contains { $0.direction == bend.direction && $0.start < bend.end && $0.end > bend.start }, "\(bend)")
        }

        let stops = sections.filter { $0.kind == .stop }
        #expect(stops.count == 1)
        if let stop = stops.first {
            #expect(abs(stop.duration - defaults.stopDuration) <= 2, "\(stop)")
            #expect(script.state(at: (stop.start + stop.end) / 2).speed < 0.3)
        }

        let net = sections.compactMap { $0.kind == .climb || $0.kind == .descent ? $0.altitudeChange : nil }.reduce(0, +)
        let rise = defaults.endAltitude - defaults.startAltitude
        #expect(abs(net - rise) <= 0.15 * rise, "net \(net) m vs \(rise) m")
    }
}
