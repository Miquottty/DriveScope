import DriveDomain
import Foundation
import simd

/// Solves the mount from a whole recording after STOP (PLAN §7). The orientation the phone held for most of the
/// drive is the mount; gravity there is "up"; forward is the horizontal direction that best explains the GPS
/// acceleration while the phone was in it (`HeadingFit`).
///
/// The live `MountCalibrator` only sees the past, so the first seconds (phone still in the hand) or a stretch out of
/// the mount can mislead it; the recorded streams are unaffected (PLAN §18), so this replaces its result.
public enum MountSolver {
    /// Seconds whose gravity lies within this angle (degrees) of each other count as one orientation.
    static let clusterAngle = 10.0
    /// Σ GPS accel² (g²) needed for a forward axis.
    static let minimumEnergy = 0.3

    /// nil without motion data or without enough GPS acceleration while mounted.
    public static func solve(reader: TelemetryReader) -> MountCalibration? {
        let bins = Bins(reader: reader)
        guard let up = dominantUp(bins) else { return nil }
        var fit = HeadingFit(up: up)
        let fixes = reader.locations
        var previous: (time: Double, speed: Double, course: Double)?
        for fix in fixes where fix.hasValidSpeed {
            let t = reader.elapsed(fix)
            let current = (time: t, speed: Double(fix.speed), course: fix.hasValidCourse ? Double(fix.course) : -1)
            defer { previous = current }
            guard let a = previous, t - a.time > 0.5, t - a.time < 2,
                  bins.isMounted(from: a.time, to: t, up: up),
                  let horizontal = bins.meanUserAcceleration(from: a.time, to: t) else { continue }
            fit.add(
                horizontal: horizontal,
                gps: HeadingFit.gpsAcceleration(from: (a.speed, a.course), to: (current.speed, current.course), dt: t - a.time)
            )
        }
        guard fit.energy >= minimumEnergy, let forward = fit.forward else { return nil }
        return MountCalibration(up: up, forward: forward, method: .auto, confidence: fit.confidence, elapsed: 0)
    }

    /// Up of the orientation shared by the most seconds of the recording.
    static func dominantUp(_ bins: Bins) -> SIMD3<Double>? {
        let seconds = bins.secondGravity.compactMap { $0 }
        guard !seconds.isEmpty else { return nil }
        let threshold = cos(clusterAngle * .pi / 180)
        // At most ~1500 candidate centres: plenty, and a 2-hour drive stays around 10 M dot products.
        let step = max(1, seconds.count / 1500)
        var best: (score: Int, sum: SIMD3<Double>)?
        for c in stride(from: 0, to: seconds.count, by: step) {
            let centre = seconds[c]
            var score = 0, sum = SIMD3<Double>.zero
            for g in seconds where simd_dot(g, centre) > threshold {
                score += 1
                sum += g
            }
            if score > best?.score ?? 0 { best = (score, sum) }
        }
        return best.map { simd_normalize(-$0.sum) }
    }

    /// Motion summed into 0.1 s bins (session elapsed), so interval means and per-second gravity are cheap.
    struct Bins {
        static let width = 0.1
        private var user: [SIMD3<Double>] = []
        private var gravity: [SIMD3<Double>] = []
        private var count: [Int] = []
        /// Unit gravity per whole second; nil where the second has little data.
        private(set) var secondGravity: [SIMD3<Double>?] = []

        init(reader: TelemetryReader) {
            let clock = reader.clock
            let n = Int(reader.duration / Self.width) + 1
            user = Array(repeating: .zero, count: n)
            gravity = Array(repeating: .zero, count: n)
            count = Array(repeating: 0, count: n)
            func add(_ time: Double, user u: SIMD3<Double>, gravity g: SIMD3<Double>) {
                let i = Int(clock.elapsed(uptime: time) / Self.width)
                guard i >= 0, i < n else { return }
                user[i] += u
                gravity[i] += g
                count[i] += 1
            }
            if !reader.motion.isEmpty {
                for s in reader.motion {
                    add(s.timestamp,
                        user: SIMD3(Double(s.userAcceleration.x), Double(s.userAcceleration.y), Double(s.userAcceleration.z)),
                        gravity: SIMD3(Double(s.gravity.x), Double(s.gravity.y), Double(s.gravity.z)))
                }
            } else {
                // Eco: raw acceleration in both; gravity is its per-second mean, user the remainder (below).
                for s in reader.accelerations {
                    let a = SIMD3(Double(s.acceleration.x), Double(s.acceleration.y), Double(s.acceleration.z))
                    add(s.timestamp, user: a, gravity: a)
                }
            }
            let perSecond = Int(1 / Self.width)
            secondGravity = stride(from: 0, to: n, by: perSecond).map { start in
                let range = start..<min(start + perSecond, n)
                let samples = range.reduce(0) { $0 + count[$1] }
                guard samples >= 5 else { return nil }
                let sum = range.reduce(SIMD3<Double>.zero) { $0 + gravity[$1] }
                return simd_length(sum) > 0 ? simd_normalize(sum) : nil
            }
            if reader.motion.isEmpty {
                for i in 0..<n where count[i] > 0 {
                    guard let g = secondGravity[i / perSecond] else { continue }
                    user[i] -= g * Double(count[i])
                }
            }
        }

        /// Every second touched by [t0, t1] has gravity within the mount-change angle of `up`.
        func isMounted(from t0: Double, to t1: Double, up: SIMD3<Double>) -> Bool {
            let limit = cos(TelemetryInterpolator.mountTolerance * .pi / 180)
            let first = max(0, Int(t0)), last = min(secondGravity.count - 1, Int(t1))
            guard first <= last else { return false }
            for s in first...last {
                guard let g = secondGravity[s], simd_dot(-g, up) > limit else { return false }
            }
            return true
        }

        func meanUserAcceleration(from t0: Double, to t1: Double) -> SIMD3<Double>? {
            let first = max(0, Int(t0 / Self.width)), last = min(count.count, Int(t1 / Self.width))
            guard first < last else { return nil }
            var sum = SIMD3<Double>.zero, samples = 0
            for i in first..<last {
                sum += user[i]
                samples += count[i]
            }
            return samples >= 5 ? sum / Double(samples) : nil
        }
    }
}
