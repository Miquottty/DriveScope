import DriveDomain
import DriveStorage
import Foundation

/// One synthesized moment of a drive — what the Replay HUD (and later the video HUD) draws (PLAN §12).
public struct ReplayTelemetryFrame: Sendable, Equatable {
    /// Seconds since session start (or since SYNC in a VlogTrack).
    public var time: TimeInterval
    public var latitude: Double
    public var longitude: Double
    /// m/s.
    public var speed: Double
    /// m; barometric when available.
    public var altitude: Double
    /// Compass degrees.
    public var course: Double
    /// g in the vehicle frame (+ = left / accelerating / up). GPS-estimated lateral g without calibration.
    public var lateralG: Double
    public var longitudinalG: Double
    public var verticalG: Double
    /// Degrees; + = right side down / nose up. Yaw is the GPS course.
    public var roll: Double
    public var pitch: Double
    public var yaw: Double
    public var gpsAccuracy: Double
    /// False inside a GPS gap (> 5 s between fixes): position is interpolated across it.
    public var hasFix: Bool
}

/// Synthesizes frames at any time from the independent streams (PLAN §5, §12):
/// Location linear (course circular), motion averaged over a small window and rotated into the vehicle frame.
public struct TelemetryInterpolator: Sendable {
    public struct Options: Sendable {
        /// GPS speed moving average, in fixes (1 = raw).
        public var speedWindow = 1
        /// Motion averaging window, seconds (display smoothing; raw ≈ one sample).
        public var gWindow: TimeInterval = 0.06
        /// Between fixes, speed follows the calibrated longitudinal acceleration instead of a straight line.
        public var speedFusion = true

        public init(speedWindow: Int = 1, gWindow: TimeInterval = 0.06, speedFusion: Bool = true) {
            self.speedWindow = speedWindow
            self.gWindow = gWindow
            self.speedFusion = speedFusion
        }

        /// Vlog output: speed over 5 fixes, G low-passed (PLAN §5).
        public static let vlog = Options(speedWindow: 5, gWindow: 0.3)
    }

    public static let gapThreshold: TimeInterval = 5
    /// Longest fix interval bridged by integrating acceleration; longer gaps (tunnel) stay linear.
    public static let fusionMaxSpan: TimeInterval = 3

    public let reader: TelemetryReader
    public let calibration: MountCalibration?
    public let options: Options
    private let baroReference: Double?

    public init(reader: TelemetryReader, calibration: MountCalibration? = nil, options: Options = Options()) {
        self.reader = reader
        self.calibration = calibration ?? reader.manifest.calibration
        self.options = options
        baroReference = reader.altitudes.first.map { Double($0.relativeAltitude) }
    }

    public var duration: TimeInterval { reader.duration }

    public func frame(at t: TimeInterval) -> ReplayTelemetryFrame {
        var frame = locationFrame(at: t)
        if let baseline = reader.manifest.altitudeBaseline, let reference = baroReference, let relative = relativeAltitude(at: t) {
            frame.altitude = baseline + relative - reference
        }
        applyMotion(at: t, to: &frame)
        return frame
    }

    // MARK: - Location

    private func locationFrame(at t: TimeInterval) -> ReplayTelemetryFrame {
        let fixes = reader.locations
        let empty = ReplayTelemetryFrame(
            time: t, latitude: 0, longitude: 0, speed: 0, altitude: 0, course: 0, lateralG: 0, longitudinalG: 0,
            verticalG: 0, roll: 0, pitch: 0, yaw: 0, gpsAccuracy: -1, hasFix: false
        )
        guard !fixes.isEmpty else { return empty }
        let clock = reader.clock
        let i = fixes.partitionIndex(where: { clock.elapsed(unixTime: $0.timestamp) }, isAtLeast: t)
        let b = min(i, fixes.count - 1), a = max(i - 1, 0)
        let fa = fixes[a], fb = fixes[b]
        let ta = clock.elapsed(unixTime: fa.timestamp), tb = clock.elapsed(unixTime: fb.timestamp)
        let span = tb - ta
        let f = span > 0 ? min(max((t - ta) / span, 0), 1) : 0
        // Stopped fixes report course -1: hold the last valid heading instead of snapping north.
        let held = lastValidCourse(atOrBefore: a) ?? (fb.hasValidCourse ? Double(fb.course) : 0)
        let courseA = fa.hasValidCourse ? Double(fa.course) : held
        let courseB = fb.hasValidCourse ? Double(fb.course) : courseA
        var course = courseA + Units.headingDelta(from: courseA, to: courseB) * f
        if course < 0 { course += 360 }
        course = course.truncatingRemainder(dividingBy: 360)
        let va = smoothedSpeed(a), vb = smoothedSpeed(b)
        let speed = fusedSpeed(at: t, ta: ta, tb: tb, va: va, vb: vb) ?? va + (vb - va) * f

        var frame = empty
        frame.latitude = fa.latitude + (fb.latitude - fa.latitude) * f
        frame.longitude = fa.longitude + (fb.longitude - fa.longitude) * f
        frame.altitude = fa.altitude + (fb.altitude - fa.altitude) * f
        frame.speed = speed
        frame.course = course
        frame.yaw = course
        frame.gpsAccuracy = Double(f < 0.5 ? fa.horizontalAccuracy : fb.horizontalAccuracy)
        frame.hasFix = span <= Self.gapThreshold && t >= ta - 1 && t <= tb + 1
        // GPS-estimated lateral g (speed × course rate); replaced below when calibrated motion exists.
        if span > 0, span <= 3, fa.hasValidCourse, fb.hasValidCourse, speed > 3 {
            frame.lateralG = speed * -Units.headingDelta(from: Double(fa.course), to: Double(fb.course)) * .pi / 180 / span / Units.g
        }
        return frame
    }

    /// Scans back a bounded number of fixes (a long stop just keeps the last known heading).
    private func lastValidCourse(atOrBefore index: Int) -> Double? {
        let fixes = reader.locations
        var i = index
        while i >= 0, index - i < 600 {
            if fixes[i].hasValidCourse { return Double(fixes[i].course) }
            i -= 1
        }
        return nil
    }

    private func smoothedSpeed(_ index: Int) -> Double {
        let fixes = reader.locations
        let half = options.speedWindow / 2
        let range = max(0, index - half)...min(fixes.count - 1, index + half)
        let valid = range.map { fixes[$0] }.filter(\.hasValidSpeed)
        guard !valid.isEmpty else { return 0 }
        return valid.reduce(0) { $0 + Double($1.speed) } / Double(valid.count)
    }

    private func relativeAltitude(at t: TimeInterval) -> Double? {
        let samples = reader.altitudes
        guard !samples.isEmpty else { return nil }
        let uptime = reader.clock.startUptime + t
        let i = samples.partitionIndex(where: { $0.timestamp }, isAtLeast: uptime)
        let b = min(i, samples.count - 1), a = max(i - 1, 0)
        let sa = samples[a], sb = samples[b]
        let f = sb.timestamp > sa.timestamp ? min(max((uptime - sa.timestamp) / (sb.timestamp - sa.timestamp), 0), 1) : 0
        return Double(sa.relativeAltitude) + Double(sb.relativeAltitude - sa.relativeAltitude) * f
    }

    // MARK: - Speed fusion

    /// Speed between two fixes from the longitudinal acceleration (PLAN §12): integrate from the first fix and spread
    /// the miss at the second fix linearly over the interval. The result equals GPS at both fixes, and a constant
    /// accelerometer bias or mount leak within the interval cancels out. nil → linear interpolation.
    private func fusedSpeed(at t: TimeInterval, ta: TimeInterval, tb: TimeInterval, va: Double, vb: Double) -> Double? {
        guard options.speedFusion, let calibration, calibration.confidence >= 0.5 else { return nil }
        let span = tb - ta
        guard span > 0, span <= Self.fusionMaxSpan, t >= ta, t <= tb else { return nil }
        // Parked: integrating noise would only make a stationary car creep.
        if max(va, vb) < 0.3 { return 0 }
        let start = reader.clock.startUptime
        let forward = Array(calibration.rotation.prefix(3))
        guard let integral = longitudinalIntegral(from: start + ta, to: start + tb, forward: forward),
              let partial = longitudinalIntegral(from: start + ta, to: start + t, forward: forward) else { return nil }
        let miss = vb - (va + integral)
        // The accelerometer disagrees with GPS (moved mount, GPS glitch): trust neither the shape nor the fix.
        guard abs(miss) / span <= 2 else { return nil }
        return max(0, va + partial + miss * (t - ta) / span)
    }

    /// ∫ forward acceleration dt in m/s over [u0, u1] (uptime), trapezoidal; nil when motion has a hole > 0.25 s.
    private func longitudinalIntegral(from u0: Double, to u1: Double, forward r: [Double]) -> Double? {
        guard u1 > u0 else { return 0 }
        if !reader.motion.isEmpty {
            let samples = reader.motion
            return integrate(from: u0, to: u1, count: samples.count, index: { samples.partitionIndex(where: { $0.timestamp }, isAtLeast: $0) }) { i in
                let s = samples[i], a = s.userAcceleration
                return (s.timestamp, r[0] * Double(a.x) + r[1] * Double(a.y) + r[2] * Double(a.z))
            }
        }
        let samples = reader.accelerations
        guard !samples.isEmpty else { return nil }
        // Eco: one gravity estimate (centered mean around the interval) — within ≤ 3 s it acts as a constant bias,
        // which the fix-to-fix correction removes. A tilting car (mean far from 1 g) is not trusted.
        var gravity = SIMD3<Double>.zero, n = 0.0
        var i = samples.partitionIndex(where: { $0.timestamp }, isAtLeast: u0 - 2)
        while i < samples.count, samples[i].timestamp <= u1 + 2 {
            let a = samples[i].acceleration
            gravity += SIMD3(Double(a.x), Double(a.y), Double(a.z))
            n += 1
            i += 1
        }
        guard n > 0 else { return nil }
        gravity /= n
        guard abs((gravity * gravity).sum().squareRoot() - 1) < 0.03 else { return nil }
        return integrate(from: u0, to: u1, count: samples.count, index: { samples.partitionIndex(where: { $0.timestamp }, isAtLeast: $0) }) { i in
            let s = samples[i], a = s.acceleration
            let x = Double(a.x) - gravity.x, y = Double(a.y) - gravity.y, z = Double(a.z) - gravity.z
            return (s.timestamp, r[0] * x + r[1] * y + r[2] * z)
        }
    }

    /// Trapezoid over the samples inside [u0, u1], holding the edge samples out to the bounds; g → m/s².
    private func integrate(
        from u0: Double, to u1: Double, count: Int, index: (Double) -> Int, sample: (Int) -> (time: Double, g: Double)
    ) -> Double? {
        let maxHole = 0.25
        var i = index(u0)
        guard i < count else { return nil }
        var previous = sample(i)
        guard previous.time - u0 <= maxHole else { return nil }
        var sum = previous.g * max(0, min(previous.time, u1) - u0)
        i += 1
        while i < count {
            let next = sample(i)
            if next.time > u1 { break }
            guard next.time - previous.time <= maxHole else { return nil }
            sum += (previous.g + next.g) / 2 * (next.time - previous.time)
            previous = next
            i += 1
        }
        guard u1 - previous.time <= maxHole else { return nil }
        sum += previous.g * max(0, u1 - previous.time)
        return sum * Units.g
    }

    // MARK: - Motion

    private func applyMotion(at t: TimeInterval, to frame: inout ReplayTelemetryFrame) {
        guard let calibration else { return }
        let uptime = reader.clock.startUptime + t
        guard let (user, gravity) = deviceMotion(at: uptime) ?? accelerometer(at: uptime) else { return }
        let r = calibration.rotation
        func rotate(_ v: SIMD3<Double>) -> SIMD3<Double> {
            SIMD3(r[0] * v.x + r[1] * v.y + r[2] * v.z, r[3] * v.x + r[4] * v.y + r[5] * v.z, r[6] * v.x + r[7] * v.y + r[8] * v.z)
        }
        let a = rotate(user), g = rotate(gravity)
        frame.longitudinalG = a.x
        frame.lateralG = a.y
        frame.verticalG = a.z
        frame.pitch = atan2(-g.x, -g.z) * 180 / .pi
        frame.roll = atan2(-g.y, -g.z) * 180 / .pi
    }

    /// Mean user acceleration and gravity (device frame) over the window; nil in a motion gap.
    private func deviceMotion(at uptime: Double) -> (SIMD3<Double>, SIMD3<Double>)? {
        let samples = reader.motion
        guard !samples.isEmpty else { return nil }
        let half = options.gWindow / 2
        // Start at the window, but always take at least the nearest sample so a tiny window still yields a value.
        var i = min(samples.partitionIndex(where: { $0.timestamp }, isAtLeast: uptime - half), samples.count - 1)
        guard abs(samples[i].timestamp - uptime) <= 1 else { return nil }
        var user = SIMD3<Double>.zero, gravity = SIMD3<Double>.zero, n = 0.0
        while i < samples.count, n == 0 || samples[i].timestamp <= uptime + half {
            let s = samples[i]
            user += SIMD3(Double(s.userAcceleration.x), Double(s.userAcceleration.y), Double(s.userAcceleration.z))
            gravity += SIMD3(Double(s.gravity.x), Double(s.gravity.y), Double(s.gravity.z))
            n += 1
            i += 1
        }
        return (user / n, gravity / n)
    }

    /// Eco: gravity is the centered 4 s mean of the raw acceleration (non-causal, fine for replay).
    private func accelerometer(at uptime: Double) -> (SIMD3<Double>, SIMD3<Double>)? {
        let samples = reader.accelerations
        guard !samples.isEmpty else { return nil }
        let half = max(options.gWindow / 2, 0.05)
        var gravity = SIMD3<Double>.zero, gravityCount = 0.0
        var raw = SIMD3<Double>.zero, rawCount = 0.0
        var i = samples.partitionIndex(where: { $0.timestamp }, isAtLeast: uptime - 2)
        while i < samples.count, samples[i].timestamp <= uptime + 2 {
            let a = samples[i].acceleration
            let v = SIMD3(Double(a.x), Double(a.y), Double(a.z))
            gravity += v
            gravityCount += 1
            if abs(samples[i].timestamp - uptime) <= half {
                raw += v
                rawCount += 1
            }
            i += 1
        }
        guard rawCount > 0 else { return nil }
        let g = gravity / gravityCount
        return (raw / rawCount - g, g)
    }
}

/// The derived, regenerable Vlog track (PLAN §5): fixed-rate frames with display smoothing, time zero at SYNC.
public struct VlogTrack: Sequence, Sendable {
    public let interpolator: TelemetryInterpolator
    public let fps: Double
    /// Session elapsed of the SYNC marker; frames before it have negative time.
    public let syncElapsed: TimeInterval

    public init(reader: TelemetryReader, calibration: MountCalibration? = nil, fps: Double = 30, syncElapsed: TimeInterval? = nil) {
        interpolator = TelemetryInterpolator(reader: reader, calibration: calibration, options: .vlog)
        self.fps = fps
        self.syncElapsed = syncElapsed ?? 0
    }

    public var frameCount: Int { Int(interpolator.duration * fps) + 1 }

    public func makeIterator() -> AnyIterator<ReplayTelemetryFrame> {
        var index = 0
        let count = frameCount
        return AnyIterator {
            guard index < count else { return nil }
            let t = Double(index) / fps
            index += 1
            var frame = interpolator.frame(at: t)
            frame.time = t - syncElapsed
            return frame
        }
    }
}
