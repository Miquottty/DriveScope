import DriveDomain
import DriveReplay
import DriveSensors
import Foundation
import simd
import Testing

struct MountCalibratorTests {
    /// Rotation (device → vehicle) of a landscape phone yawed 25° and tilted back 15°.
    static let awkwardMount: MountCalibration = {
        func rz(_ a: Double) -> simd_double3x3 { simd_double3x3(rows: [[cos(a), -sin(a), 0], [sin(a), cos(a), 0], [0, 0, 1]]) }
        func ry(_ a: Double) -> simd_double3x3 { simd_double3x3(rows: [[cos(a), 0, sin(a)], [0, 1, 0], [-sin(a), 0, cos(a)]]) }
        // Landscape on the dash facing the driver: screen x → vehicle up… built from the portrait mount.
        let portrait = simd_double3x3(rows: [[0, 0, -1], [-1, 0, 0], [0, 1, 0]])
        let landscape = simd_double3x3(rows: [[0, 1, 0], [-1, 0, 0], [0, 0, 1]]) // device z-rotation by 90°
        let m = rz(25 * .pi / 180) * ry(-15 * .pi / 180) * portrait * landscape
        let rows = (0..<3).flatMap { r in (0..<3).map { c in m[c][r] } }
        return MountCalibration(rotation: rows, method: .manual, confidence: 1, calibratedAtElapsed: 0)
    }()

    /// PLAN S3 exit criterion: from an unknown mount, gravity + the first launch + GPS verification recover the
    /// vehicle axes, and lateral g then has the right sign in corners.
    @Test func recoversUnknownMountAndLateralSign() throws {
        let truth = Self.awkwardMount
        let synth = MotionSynthesizer(mount: truth, noise: 0.015)
        let script = DriveScript.akagi
        var calibrator = MountCalibrator()
        var rng = SplitMix64(seed: 5)
        var yaw = 0.0
        let hz = 50.0

        var t = 0.0
        var nextFix = 0.0
        while t < 400 {
            let s = script.state(at: t)
            yaw += s.yawRate / hz
            let dyn = MotionSynthesizer.Dynamics(longitudinal: s.longitudinalAcceleration, lateral: s.lateralAcceleration, yawRate: s.yawRate, yaw: yaw)
            if case .deviceMotion(let m) = synth.event(mode: .deviceMotion(hz: hz), timestamp: t, dynamics: dyn, rng: &rng) {
                _ = calibrator.add(m, elapsed: t)
            }
            if t >= nextFix {
                nextFix += 1
                _ = calibrator.add(LocationSample(
                    timestamp: t, latitude: s.latitude, longitude: s.longitude, altitude: s.altitude, receivedUptime: t,
                    speed: Float(s.speed), course: s.speed > 0.5 ? Float(s.course) : -1, horizontalAccuracy: 5,
                    verticalAccuracy: 5, speedAccuracy: 0.3, courseAccuracy: 3
                ), elapsed: t)
            }
            t += 1 / hz
        }

        let found = try #require(calibrator.calibration)
        for row in 0..<3 {
            let a = SIMD3(found.rotation[row * 3], found.rotation[row * 3 + 1], found.rotation[row * 3 + 2])
            let b = SIMD3(truth.rotation[row * 3], truth.rotation[row * 3 + 1], truth.rotation[row * 3 + 2])
            #expect(simd_dot(a, b) > 0.98, "axis \(row)")
        }

        // In a hard corner, calibrated lateral g has the script's sign and roughly its size.
        let corner = stride(from: 400.0, to: 1500, by: 1).map { script.state(at: $0) }.max { abs($0.lateralAcceleration) < abs($1.lateralAcceleration) }!
        var noNoise = SplitMix64(seed: 0)
        let quiet = MotionSynthesizer(mount: truth, noise: 0)
        guard case .deviceMotion(let m) = quiet.event(
            mode: .deviceMotion(hz: hz), timestamp: 0,
            dynamics: .init(longitudinal: corner.longitudinalAcceleration, lateral: corner.lateralAcceleration, yawRate: corner.yawRate, yaw: 0),
            rng: &noNoise
        ) else { Issue.record("no sample"); return }
        let lateral = Double(found.apply(m.userAcceleration).y)
        let expected = corner.lateralAcceleration / Units.g
        #expect(lateral.sign == expected.sign)
        #expect(abs(lateral - expected) < 0.05)
    }
}
