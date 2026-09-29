import DriveDomain
import Foundation
import simd

/// Finds the device → vehicle rotation of a phone in an unknown mount (PLAN §7).
///
/// 1. **Up** from gravity (device motion's fused gravity, or a low-passed accelerometer in Eco).
/// 2. **Forward** from the first launch: while GPS goes from standstill to 15 km/h, the horizontal acceleration
///    points forward.
/// 3. **Verification** of the remaining 4-quadrant ambiguity: calibrated x must correlate with the GPS
///    longitudinal acceleration (dv/dt) and y with the GPS lateral acceleration (v × yaw rate). A 180° or ±90°
///    error is corrected once there is enough evidence.
///
/// Runs live in the engine and again over stored files, so it has no clock of its own: every call carries the
/// sample's uptime.
public struct MountCalibrator: Sendable {
    public struct Configuration: Sendable {
        /// Gravity samples averaged before "up" is trusted.
        public var gravitySamples = 50
        public var standstillSpeed = 1.0
        /// 15 km/h.
        public var launchSpeed = 15 / 3.6
        /// g.
        public var launchAcceleration = 0.15
        public var launchMinimumSamples = 5
        /// Σ GPS accel² (g²) needed before the verification may rotate the calibration.
        public var verificationEnergy = 0.3

        public init() {}
    }

    public enum Phase: Sendable, Equatable {
        case findingUp
        case waitingForLaunch
        case calibrated
    }

    public let configuration: Configuration
    public private(set) var phase: Phase = .findingUp
    public private(set) var calibration: MountCalibration?

    private var gravitySum = SIMD3<Double>.zero
    private var gravityCount = 0
    private var up: SIMD3<Double>?
    /// Eco: low-passed raw acceleration ≈ gravity.
    private var lowPass: SIMD3<Double>?

    private var launchWindowOpen = false
    private var launchSum = SIMD3<Double>.zero
    private var launchCount = 0

    private var forward: SIMD3<Double>?
    private var secondSum = SIMD3<Double>.zero
    private var secondCount = 0
    private var previousFix: (uptime: Double, speed: Double, course: Double)?
    private var evidence = Evidence()

    private struct Evidence {
        var xLong = 0.0, yLat = 0.0, xLat = 0.0, yLong = 0.0
        var longEnergy = 0.0, latEnergy = 0.0
    }

    public init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
    }

    // MARK: - Inputs

    /// Device-motion sample (gravity and user acceleration in g, device axes). Returns a new calibration when it changes.
    public mutating func add(_ sample: MotionSample, elapsed: TimeInterval) -> MountCalibration? {
        let gravity = SIMD3(Double(sample.gravity.x), Double(sample.gravity.y), Double(sample.gravity.z))
        let user = SIMD3(Double(sample.userAcceleration.x), Double(sample.userAcceleration.y), Double(sample.userAcceleration.z))
        return add(gravity: gravity, user: user, elapsed: elapsed)
    }

    /// Accelerometer-only sample (Eco): gravity is estimated with a ~2 s low-pass.
    public mutating func add(_ sample: AccelSample, elapsed: TimeInterval, sampleRate: Double) -> MountCalibration? {
        let raw = SIMD3(Double(sample.acceleration.x), Double(sample.acceleration.y), Double(sample.acceleration.z))
        let alpha = min(1, 1 / (2 * sampleRate))
        let gravity = lowPass.map { $0 + (raw - $0) * alpha } ?? raw
        lowPass = gravity
        return add(gravity: gravity, user: raw - gravity, elapsed: elapsed)
    }

    /// GPS fix: drives launch detection and verification.
    public mutating func add(_ location: LocationSample, elapsed: TimeInterval) -> MountCalibration? {
        guard location.hasValidSpeed else { return nil }
        let speed = Double(location.speed)
        defer {
            previousFix = (location.receivedUptime, speed, location.hasValidCourse ? Double(location.course) : -1)
        }
        switch phase {
        case .findingUp:
            return nil
        case .waitingForLaunch:
            if speed < configuration.standstillSpeed {
                // Re-open at every standstill: a window that saw braking or noise is discarded.
                launchWindowOpen = true
                launchSum = .zero
                launchCount = 0
            } else if launchWindowOpen, speed >= configuration.launchSpeed {
                launchWindowOpen = false
                if launchCount >= configuration.launchMinimumSamples, let up {
                    let horizontal = launchSum - simd_dot(launchSum, up) * up
                    if simd_length(horizontal) > 1e-6 {
                        forward = simd_normalize(horizontal)
                        phase = .calibrated
                        return publish(confidence: 0.6, elapsed: elapsed)
                    }
                }
            }
            return nil
        case .calibrated:
            return verify(speed: speed, course: location.hasValidCourse ? Double(location.course) : -1,
                          uptime: location.receivedUptime, elapsed: elapsed)
        }
    }

    /// The Recording screen's manual "rotate 90°" (PLAN §7-4): forward turns left about the up axis.
    public mutating func rotateManually(elapsed: TimeInterval) -> MountCalibration? {
        guard let up, let forward else { return nil }
        self.forward = simd_cross(up, forward)
        evidence = Evidence()
        return publish(confidence: calibration?.confidence ?? 0.5, elapsed: elapsed, method: .manual)
    }

    // MARK: - Internals

    private mutating func add(gravity: SIMD3<Double>, user: SIMD3<Double>, elapsed: TimeInterval) -> MountCalibration? {
        switch phase {
        case .findingUp:
            // Average gravity while the device is still (gravity points down, so up is its negation).
            if simd_length(user) < 0.05 {
                gravitySum += gravity
                gravityCount += 1
            }
            if gravityCount >= configuration.gravitySamples {
                up = simd_normalize(-gravitySum)
                phase = .waitingForLaunch
            }
        case .waitingForLaunch:
            guard launchWindowOpen, let up else { break }
            let horizontal = user - simd_dot(user, up) * up
            if simd_length(horizontal) > configuration.launchAcceleration {
                launchSum += horizontal
                launchCount += 1
            }
        case .calibrated:
            // Average calibrated acceleration per GPS interval for the verification.
            secondSum += user
            secondCount += 1
        }
        return nil
    }

    private mutating func verify(speed: Double, course: Double, uptime: Double, elapsed: TimeInterval) -> MountCalibration? {
        defer {
            secondSum = .zero
            secondCount = 0
        }
        // A manual rotation is the user's decision; don't let the verification undo it.
        guard calibration?.method != .manual else { return nil }
        guard let previous = previousFix, let up, let forward, secondCount > 0 else { return nil }
        let dt = uptime - previous.uptime
        guard dt > 0.5, dt < 2 else { return nil }
        let mean = secondSum / Double(secondCount)
        let left = simd_cross(up, forward)
        let x = simd_dot(mean, forward), y = simd_dot(mean, left)
        let gpsLong = (speed - previous.speed) / dt / Units.g
        var gpsLat = 0.0
        if course >= 0, previous.course >= 0, speed > 3 {
            gpsLat = speed * -Units.headingDelta(from: previous.course, to: course) * .pi / 180 / dt / Units.g
        }
        evidence.xLong += x * gpsLong
        evidence.yLat += y * gpsLat
        evidence.xLat += x * gpsLat
        evidence.yLong += y * gpsLong
        evidence.longEnergy += gpsLong * gpsLong
        evidence.latEnergy += gpsLat * gpsLat

        guard evidence.longEnergy + evidence.latEnergy >= configuration.verificationEnergy else { return nil }
        let straight = evidence.xLong + evidence.yLat
        let quarter = evidence.yLong - evidence.xLat // forward is really +left (rotated 90° CCW)
        let reversed = -straight
        let best = max(straight, quarter, -quarter, reversed)
        let total = abs(evidence.xLong) + abs(evidence.yLat) + abs(evidence.xLat) + abs(evidence.yLong)
        let confidence = total > 0 ? max(0, min(1, best / total)) : 0
        evidence = Evidence()
        if best == straight {
            return publish(confidence: max(confidence, 0.6), elapsed: elapsed)
        } else if best == reversed {
            self.forward = -forward
        } else if best == quarter {
            self.forward = left
        } else {
            self.forward = -left
        }
        return publish(confidence: confidence, elapsed: elapsed)
    }

    private mutating func publish(confidence: Double, elapsed: TimeInterval, method: MountCalibration.Method = .auto) -> MountCalibration? {
        guard let up, let forward else { return nil }
        let f = simd_normalize(forward - simd_dot(forward, up) * up)
        let l = simd_cross(up, f)
        let next = MountCalibration(
            rotation: [f.x, f.y, f.z, l.x, l.y, l.z, up.x, up.y, up.z],
            method: method, confidence: confidence, calibratedAtElapsed: elapsed
        )
        // Re-publishing the same axes only refreshes confidence; don't spam updates.
        if let current = calibration, current.rotation == next.rotation, abs(current.confidence - confidence) < 0.05 {
            return nil
        }
        calibration = next
        return next
    }
}
