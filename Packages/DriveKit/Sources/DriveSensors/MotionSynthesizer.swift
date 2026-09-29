import DriveDomain
import Foundation
import Synchronization

/// Turns vehicle-frame dynamics into what Core Motion would report for a phone in a mount.
///
/// Conventions (match Core Motion): `gravity` is a unit vector toward the earth in device axes; `userAcceleration`
/// is the device's kinematic acceleration in g; `rotationRate` is rad/s about device axes.
/// Vehicle axes: x forward, y left, z up.
public struct MotionSynthesizer: Sendable {
    /// Device → vehicle rotation of the simulated mount.
    public var mount: MountCalibration
    /// Accelerometer noise, g (1σ-ish, uniform).
    public var noise: Float

    public init(mount: MountCalibration = MotionSynthesizer.portraitDashMount, noise: Float = 0.015) {
        self.mount = mount
        self.noise = noise
    }

    /// Portrait phone on the dash facing the driver: screen x → vehicle right, screen y → up, screen z → rearward.
    public static let portraitDashMount = MountCalibration(
        rotation: [0, 0, -1, -1, 0, 0, 0, 1, 0], method: .manual, confidence: 1, calibratedAtElapsed: 0
    )

    public struct Dynamics: Sendable {
        /// m/s², + = accelerating.
        public var longitudinal: Double
        /// m/s², + = toward the left.
        public var lateral: Double
        /// rad/s, + = CCW (left turn).
        public var yawRate: Double
        /// Accumulated heading change since start, rad (for the attitude).
        public var yaw: Double

        public init(longitudinal: Double, lateral: Double, yawRate: Double, yaw: Double) {
            self.longitudinal = longitudinal
            self.lateral = lateral
            self.yawRate = yawRate
            self.yaw = yaw
        }
    }

    public func event(mode: CapturePreset.MotionMode, timestamp: Double, dynamics d: Dynamics, rng: inout SplitMix64) -> MotionEvent? {
        let g = Float(Units.g)
        let userVehicle = Vector3(x: Float(d.longitudinal) / g, y: Float(d.lateral) / g, z: 0)
        let gravityVehicle = Vector3(x: 0, y: 0, z: -1)
        let user = toDevice(userVehicle) + jitter(&rng)
        let gravity = toDevice(gravityVehicle)
        switch mode {
        case .none:
            return nil
        case .accelerometer:
            return .acceleration(AccelSample(timestamp: timestamp, acceleration: gravity + user))
        case .deviceMotion:
            let rotation = toDevice(Vector3(x: 0, y: 0, z: Float(d.yawRate))) + jitter(&rng) * 0.2
            return .deviceMotion(MotionSample(
                timestamp: timestamp, userAcceleration: user, gravity: gravity, rotationRate: rotation,
                attitude: attitude(yaw: d.yaw), magneticField: Vector3(x: 18, y: -4, z: -38), magneticAccuracy: 1
            ))
        }
    }

    /// Vehicle → device is the transpose of the mount rotation.
    private func toDevice(_ v: Vector3) -> Vector3 {
        let r = mount.rotation.map(Float.init)
        return Vector3(
            x: r[0] * v.x + r[3] * v.y + r[6] * v.z,
            y: r[1] * v.x + r[4] * v.y + r[7] * v.z,
            z: r[2] * v.x + r[5] * v.y + r[8] * v.z
        )
    }

    private func jitter(_ rng: inout SplitMix64) -> Vector3 {
        Vector3(x: rng.symmetric(noise), y: rng.symmetric(noise), z: rng.symmetric(noise))
    }

    /// Device orientation in a z-up reference frame: yaw about world z, then the mount (device → vehicle).
    private func attitude(yaw: Double) -> Quaternion {
        let m = mount.rotation
        // Quaternion of the mount matrix (device → vehicle).
        let trace = m[0] + m[4] + m[8]
        var q: (w: Double, x: Double, y: Double, z: Double)
        if trace > 0 {
            let s = (trace + 1).squareRoot() * 2
            q = (0.25 * s, (m[7] - m[5]) / s, (m[2] - m[6]) / s, (m[3] - m[1]) / s)
        } else if m[0] > m[4], m[0] > m[8] {
            let s = (1 + m[0] - m[4] - m[8]).squareRoot() * 2
            q = ((m[7] - m[5]) / s, 0.25 * s, (m[1] + m[3]) / s, (m[2] + m[6]) / s)
        } else if m[4] > m[8] {
            let s = (1 + m[4] - m[0] - m[8]).squareRoot() * 2
            q = ((m[2] - m[6]) / s, (m[1] + m[3]) / s, 0.25 * s, (m[5] + m[7]) / s)
        } else {
            let s = (1 + m[8] - m[0] - m[4]).squareRoot() * 2
            q = ((m[3] - m[1]) / s, (m[2] + m[6]) / s, (m[5] + m[7]) / s, 0.25 * s)
        }
        // yaw ⊗ mount
        let (cw, sw) = (cos(yaw / 2), sin(yaw / 2))
        return Quaternion(
            w: Float(cw * q.w - sw * q.z),
            x: Float(cw * q.x - sw * q.y),
            y: Float(cw * q.y + sw * q.x),
            z: Float(cw * q.z + sw * q.w)
        )
    }
}

/// Small deterministic PRNG so simulated drives are reproducible.
public struct SplitMix64: Sendable {
    private var state: UInt64

    public init(seed: UInt64) {
        state = seed
    }

    public mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// Uniform in [-amplitude, amplitude].
    public mutating func symmetric(_ amplitude: Float) -> Float {
        (Float(next() >> 40) / Float(1 << 24) * 2 - 1) * amplitude
    }

    public mutating func symmetric(_ amplitude: Double) -> Double {
        (Double(next() >> 11) / Double(1 << 53) * 2 - 1) * amplitude
    }
}
