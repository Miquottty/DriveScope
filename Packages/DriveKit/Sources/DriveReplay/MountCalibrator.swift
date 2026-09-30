import DriveDomain
import Foundation
import simd

/// Finds the device → vehicle rotation of a phone in an unknown mount (PLAN §7).
///
/// 1. **Up** from gravity (device motion's fused gravity, or a low-passed accelerometer in Eco), once it has held
///    still for a few seconds.
/// 2. **Forward** from the first launch: while GPS goes from standstill to 15 km/h, the horizontal acceleration
///    points forward. A quick first guess.
/// 3. **GPS fit**: the horizontal acceleration per GPS interval is matched against the GPS longitudinal (dv/dt) and
///    lateral (v × yaw rate) acceleration; the best rotation about "up" becomes forward. It needs no launch and
///    corrects any wrong guess, including a 90° or 180° one.
/// 4. **Mount change**: gravity far from "up" for a few seconds means the phone left the mount (or was moved in
///    it). Everything is dropped and found again — so a phone still in the hand at START doesn't poison the drive.
///
/// Runs live in the engine, so it has no clock of its own: every call carries the sample's time.
/// After STOP, `MountSolver` recomputes the mount from the whole recording.
public struct MountCalibrator: Sendable {
    public struct Configuration: Sendable {
        /// Seconds of still gravity before "up" is trusted.
        public var stillDuration: TimeInterval = 3
        /// Degrees gravity may wander from its running mean and still count as still. Device-motion gravity stays
        /// steady in a mount even while the car accelerates; in a hand it wanders.
        public var stillAngle = 3.0
        /// g. Jolts above this (handling, knocking the mount) restart the still stretch; normal driving stays below.
        public var stillAcceleration = 0.6
        public var standstillSpeed = 1.0
        /// 15 km/h.
        public var launchSpeed = 15 / 3.6
        /// g.
        public var launchAcceleration = 0.15
        public var launchMinimumSamples = 5
        /// Σ GPS accel² (g²) needed before the GPS fit may set or turn forward.
        public var fitEnergy = 0.3
        /// Gravity this far from "up" (degrees) for `mountChangeDuration` is a mount change. Roads tilt the car by
        /// well under 10°, and device-motion gravity doesn't lean in corners or under braking.
        public var mountChangeAngle = 15.0
        public var mountChangeDuration: TimeInterval = 2
        /// Eco's low-passed gravity does lean under sustained acceleration, so it needs more before it counts.
        public var ecoMountChangeAngle = 25.0
        /// A new "up" within this angle (degrees) of the lost mount's is the same mount: the phone was knocked or
        /// taken out and put back, so the old calibration applies again at once.
        public var sameMountAngle = 5.0

        public init() {}
    }

    public enum Phase: Sendable, Equatable {
        case findingUp
        case waitingForLaunch
        case calibrated
    }

    public enum Update: Sendable, Equatable {
        case calibrated(MountCalibration)
        /// The phone left the mount: there is no calibration until it is found again.
        case lost
    }

    public let configuration: Configuration
    public private(set) var phase: Phase = .findingUp
    public private(set) var calibration: MountCalibration?

    private var up: SIMD3<Double>?
    /// Eco: low-passed raw acceleration ≈ gravity.
    private var lowPass: SIMD3<Double>?
    private var lastElapsed: TimeInterval?
    /// ~0.5 s low-pass of gravity for the mount-change check.
    private var smoothedGravity: SIMD3<Double>?
    private var stillSum = SIMD3<Double>.zero
    private var stillSince: TimeInterval?
    private var deviatingSince: TimeInterval?

    private var launchWindowOpen = false
    private var launchSum = SIMD3<Double>.zero
    private var launchCount = 0

    private var forward: SIMD3<Double>?
    private var fit: HeadingFit?
    /// Mounts lost to mount changes (newest last), to restore if the phone goes back into one.
    private var previousMounts: [(forward: SIMD3<Double>, fit: HeadingFit?, calibration: MountCalibration)] = []
    private var intervalSum = SIMD3<Double>.zero
    private var intervalCount = 0
    private var previousFix: (uptime: Double, speed: Double, course: Double)?

    public init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
    }

    // MARK: - Inputs

    /// Device-motion sample (gravity and user acceleration in g, device axes).
    public mutating func add(_ sample: MotionSample, elapsed: TimeInterval) -> Update? {
        let gravity = SIMD3(Double(sample.gravity.x), Double(sample.gravity.y), Double(sample.gravity.z))
        let user = SIMD3(Double(sample.userAcceleration.x), Double(sample.userAcceleration.y), Double(sample.userAcceleration.z))
        return add(gravity: gravity, user: user, elapsed: elapsed, mountChangeAngle: configuration.mountChangeAngle)
    }

    /// Accelerometer-only sample (Eco): gravity is estimated with a ~2 s low-pass.
    public mutating func add(_ sample: AccelSample, elapsed: TimeInterval, sampleRate: Double) -> Update? {
        let raw = SIMD3(Double(sample.acceleration.x), Double(sample.acceleration.y), Double(sample.acceleration.z))
        let alpha = min(1, 1 / (2 * sampleRate))
        let gravity = lowPass.map { $0 + (raw - $0) * alpha } ?? raw
        lowPass = gravity
        return add(gravity: gravity, user: raw - gravity, elapsed: elapsed, mountChangeAngle: configuration.ecoMountChangeAngle)
    }

    /// GPS fix: drives launch detection and the GPS fit.
    public mutating func add(_ location: LocationSample, elapsed: TimeInterval) -> Update? {
        guard location.hasValidSpeed else { return nil }
        let speed = Double(location.speed)
        let course = location.hasValidCourse ? Double(location.course) : -1
        defer {
            previousFix = (location.receivedUptime, speed, course)
            intervalSum = .zero
            intervalCount = 0
        }
        guard phase != .findingUp else { return nil }
        if phase == .waitingForLaunch, let update = launch(speed: speed, elapsed: elapsed) { return update }
        return addToFit(speed: speed, course: course, uptime: location.receivedUptime, elapsed: elapsed)
    }

    /// The Recording screen's manual "rotate 90°" (PLAN §7-4): forward turns left about the up axis.
    public mutating func rotateManually(elapsed: TimeInterval) -> Update? {
        guard let up, let forward else { return nil }
        self.forward = simd_cross(up, forward)
        return publish(confidence: calibration?.confidence ?? 0.5, elapsed: elapsed, method: .manual)
    }

    // MARK: - Internals

    private mutating func add(gravity: SIMD3<Double>, user: SIMD3<Double>, elapsed: TimeInterval, mountChangeAngle: Double) -> Update? {
        let dt = lastElapsed.map { min(max(elapsed - $0, 0), 1) } ?? 0
        lastElapsed = elapsed
        let smoothed = smoothedGravity.map { $0 + (gravity - $0) * min(1, dt / 0.5) } ?? gravity
        smoothedGravity = smoothed

        guard let up else {
            return findUp(gravity: gravity, user: user, elapsed: elapsed)
        }
        if Self.angle(-smoothed, up) > mountChangeAngle {
            let since = deviatingSince ?? elapsed
            deviatingSince = since
            if elapsed - since >= configuration.mountChangeDuration {
                let hadCalibration = calibration != nil
                resetMount()
                return hadCalibration ? .lost : nil
            }
            // The phone is moving: its acceleration says nothing about the car.
            return nil
        }
        deviatingSince = nil

        switch phase {
        case .findingUp:
            break
        case .waitingForLaunch:
            if launchWindowOpen {
                let horizontal = user - simd_dot(user, up) * up
                if simd_length(horizontal) > configuration.launchAcceleration {
                    launchSum += horizontal
                    launchCount += 1
                }
            }
            intervalSum += user
            intervalCount += 1
        case .calibrated:
            intervalSum += user
            intervalCount += 1
        }
        return nil
    }

    /// Up = mean gravity over a still stretch (gravity steady within a few degrees, little acceleration).
    private mutating func findUp(gravity: SIMD3<Double>, user: SIMD3<Double>, elapsed: TimeInterval) -> Update? {
        let still = simd_length(user) < configuration.stillAcceleration
            && (stillSince == nil || Self.angle(gravity, stillSum) < configuration.stillAngle)
        guard still else {
            stillSum = .zero
            stillSince = nil
            return nil
        }
        stillSum += gravity
        let since = stillSince ?? elapsed
        stillSince = since
        guard elapsed - since >= configuration.stillDuration else { return nil }
        let found = simd_normalize(-stillSum)
        if let index = previousMounts.lastIndex(where: { Self.angle(found, $0.calibration.upAxis) < configuration.sameMountAngle }) {
            let previous = previousMounts.remove(at: index)
            up = previous.calibration.upAxis
            forward = previous.forward
            fit = previous.fit ?? HeadingFit(up: previous.calibration.upAxis)
            phase = .calibrated
            calibration = previous.calibration
            return .calibrated(previous.calibration)
        }
        up = found
        fit = HeadingFit(up: found)
        phase = .waitingForLaunch
        return nil
    }

    private mutating func launch(speed: Double, elapsed: TimeInterval) -> Update? {
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
    }

    private mutating func addToFit(speed: Double, course: Double, uptime: Double, elapsed: TimeInterval) -> Update? {
        guard let previous = previousFix, intervalCount > 0, var fit else { return nil }
        let dt = uptime - previous.uptime
        guard dt > 0.5, dt < 2 else { return nil }
        fit.add(
            horizontal: intervalSum / Double(intervalCount),
            gps: HeadingFit.gpsAcceleration(from: (previous.speed, previous.course), to: (speed, course), dt: dt)
        )
        self.fit = fit
        // A manual rotation is the user's decision; the fit only takes over again after a mount change.
        guard calibration?.method != .manual, fit.energy >= configuration.fitEnergy, let solved = fit.forward else { return nil }
        forward = solved
        phase = .calibrated
        return publish(confidence: fit.confidence, elapsed: elapsed)
    }

    private mutating func resetMount() {
        if let forward, let calibration {
            previousMounts.append((forward, fit, calibration))
            if previousMounts.count > 4 { previousMounts.removeFirst() }
        }
        up = nil
        forward = nil
        fit = nil
        calibration = nil
        phase = .findingUp
        stillSum = .zero
        stillSince = nil
        deviatingSince = nil
        launchWindowOpen = false
        launchSum = .zero
        launchCount = 0
    }

    private mutating func publish(confidence: Double, elapsed: TimeInterval, method: MountCalibration.Method = .auto) -> Update? {
        guard let up, let forward else { return nil }
        let next = MountCalibration(up: up, forward: forward, method: method, confidence: confidence, elapsed: elapsed)
        // The fit moves a little with every fix; only a visible turn or a new confidence is worth an update.
        if let current = calibration, current.method == method,
           Self.angle(current.forwardAxis, next.forwardAxis) < 2, abs(current.confidence - confidence) < 0.05 {
            return nil
        }
        calibration = next
        return .calibrated(next)
    }

    /// Degrees between two vectors (any length).
    static func angle(_ a: SIMD3<Double>, _ b: SIMD3<Double>) -> Double {
        let la = simd_length(a), lb = simd_length(b)
        guard la > 0, lb > 0 else { return 180 }
        return acos(min(1, max(-1, simd_dot(a, b) / (la * lb)))) * 180 / .pi
    }
}

/// Rotation about "up" that best maps GPS acceleration onto the measured horizontal acceleration (2-D Procrustes).
///
/// With a horizontal basis e1, e2 = up × e1 and forward = cos θ e1 + sin θ e2, a vehicle acceleration (long, lat)
/// shows up as h1 + i·h2 = (long + i·lat)·e^{iθ}. So θ = arg Σ h·conj(a), and |Σ h·conj(a)| / Σ |h||a| says how
/// consistently the samples agree (1 = perfectly).
struct HeadingFit: Sendable {
    let up: SIMD3<Double>
    private let e1: SIMD3<Double>
    private let e2: SIMD3<Double>
    private var re = 0.0, im = 0.0, magnitude = 0.0
    /// Σ GPS accel² (g²).
    private(set) var energy = 0.0

    init(up: SIMD3<Double>) {
        self.up = up
        // Any horizontal direction works as e1; take the device axis least aligned with up.
        let axes: [SIMD3<Double>] = [[1, 0, 0], [0, 1, 0], [0, 0, 1]]
        let seed = axes.min { abs(simd_dot($0, up)) < abs(simd_dot($1, up)) }!
        e1 = simd_normalize(seed - simd_dot(seed, up) * up)
        e2 = simd_cross(up, e1)
    }

    /// `horizontal`: mean user acceleration (g, device axes) over a GPS interval; `gps`: that interval's vehicle
    /// acceleration (g) from GPS.
    mutating func add(horizontal: SIMD3<Double>, gps: (longitudinal: Double, lateral: Double)) {
        let h1 = simd_dot(horizontal, e1), h2 = simd_dot(horizontal, e2)
        let (aL, aT) = gps
        re += h1 * aL + h2 * aT
        im += h2 * aL - h1 * aT
        magnitude += (h1 * h1 + h2 * h2).squareRoot() * (aL * aL + aT * aT).squareRoot()
        energy += aL * aL + aT * aT
    }

    var forward: SIMD3<Double>? {
        guard re != 0 || im != 0 else { return nil }
        let theta = atan2(im, re)
        return cos(theta) * e1 + sin(theta) * e2
    }

    var confidence: Double {
        magnitude > 0 ? min(1, (re * re + im * im).squareRoot() / magnitude) : 0
    }

    /// Longitudinal (dv/dt) and lateral (v × yaw rate, + = left) acceleration in g between two fixes. Lateral is 0
    /// when either course is invalid or the car is too slow for the course to mean anything.
    static func gpsAcceleration(
        from a: (speed: Double, course: Double), to b: (speed: Double, course: Double), dt: Double
    ) -> (longitudinal: Double, lateral: Double) {
        let longitudinal = (b.speed - a.speed) / dt / Units.g
        var lateral = 0.0
        if a.course >= 0, b.course >= 0, b.speed > 3 {
            // Compass course turns clockwise for a right turn; lateral + = left.
            lateral = b.speed * -Units.headingDelta(from: a.course, to: b.course) * .pi / 180 / dt / Units.g
        }
        return (longitudinal, lateral)
    }
}

extension MountCalibration {
    /// Rows forward, left, up (device axes).
    init(up: SIMD3<Double>, forward: SIMD3<Double>, method: Method, confidence: Double, elapsed: TimeInterval) {
        let f = simd_normalize(forward - simd_dot(forward, up) * up)
        let l = simd_cross(up, f)
        self.init(
            rotation: [f.x, f.y, f.z, l.x, l.y, l.z, up.x, up.y, up.z],
            method: method, confidence: confidence, calibratedAtElapsed: elapsed
        )
    }

    var forwardAxis: SIMD3<Double> { SIMD3(rotation[0], rotation[1], rotation[2]) }
    /// Vehicle up in device axes; gravity of a phone in this mount points the opposite way.
    var upAxis: SIMD3<Double> { SIMD3(rotation[6], rotation[7], rotation[8]) }
}
