import CoreLocation
import DriveDomain
import DriveReplay
import DriveStorage
import Foundation

/// Everything the Replay screen derives from a session's streams, built once off the main actor.
/// Only the simplified route and the speed profile are materialized; frames are interpolated on demand from the
/// memory-mapped streams, so opening a 2-hour 100 Hz log reads a few hundred KB, not the motion file.
nonisolated struct ReplayTimeline: Sendable {
    struct MarkerInput: Sendable {
        var id: UUID
        var kind: MarkerKind
        var elapsed: TimeInterval
    }

    struct Marker: Sendable, Identifiable {
        var id: UUID
        var kind: MarkerKind
        var elapsed: TimeInterval
        /// Nil when the session has no fixes.
        var coordinate: CLLocationCoordinate2D?
    }

    struct SpeedPoint: Sendable {
        var time: TimeInterval
        var kmh: Double
    }

    static let maxRoutePoints = 2000
    static let speedProfilePoints = 600
    /// Same accuracy gate as the Detail route and `SessionStore.routePreview`, so the lines agree.
    static let routeAccuracyLimit: Float = 50

    let interpolator: TelemetryInterpolator
    let duration: TimeInterval
    /// Shape-preserving simplification of the good fixes (≤ `maxRoutePoints`), with each point's elapsed time.
    let route: [CLLocationCoordinate2D]
    let routeTimes: [TimeInterval]
    let speedProfile: [SpeedPoint]
    let maxKmh: Double
    let markers: [Marker]
    /// Corners, climbs / descents and stops (V1.1), by start time.
    let sections: [DriveSection]
    let hasFixes: Bool
    /// Course of the first moving fix: the heading to show while the log starts stationary.
    let initialCourse: Double?
    /// G comes from calibrated motion. Otherwise lateral G is the GPS estimate and longitudinal G is unknown.
    let hasMotionG: Bool

    /// Replay HUD smoothing: a 0.2 s window, like the live HUD's 0.2 s low-pass, so replayed G reads like what the
    /// driver saw instead of flickering with sensor noise at 30 fps. Speed stays raw.
    static let options = TelemetryInterpolator.Options(speedWindow: 1, gWindow: 0.2)

    @concurrent
    static func load(
        files: SessionFiles, calibration: MountCalibration?, markers: [MarkerInput], sections: [DriveSection],
        fallbackDuration: TimeInterval
    ) async throws -> ReplayTimeline {
        let reader = try TelemetryReader(files: files)
        let interpolator = TelemetryInterpolator(reader: reader, calibration: calibration, options: options)
        let duration = reader.duration > 0 ? reader.duration : max(fallbackDuration, 0)
        let fixes = reader.locations
        let clock = reader.clock

        // One sequential pass over the fixes: route candidates and speed buckets.
        var points: [CLLocationCoordinate2D] = []
        var times: [TimeInterval] = []
        points.reserveCapacity(fixes.count)
        times.reserveCapacity(fixes.count)
        let buckets = duration > 0 ? speedProfilePoints : 0
        var speedSum = [Double](repeating: 0, count: buckets)
        var speedCount = [Int](repeating: 0, count: buckets)
        var initialCourse: Double?
        for fix in fixes {
            let t = clock.elapsed(unixTime: fix.timestamp)
            if initialCourse == nil, fix.hasValidCourse, fix.speed >= 1 { initialCourse = Double(fix.course) }
            if fix.horizontalAccuracy > 0, fix.horizontalAccuracy <= routeAccuracyLimit {
                points.append(CLLocationCoordinate2D(latitude: fix.latitude, longitude: fix.longitude))
                times.append(t)
            }
            if buckets > 0, fix.hasValidSpeed {
                let b = min(max(Int(t / duration * Double(buckets)), 0), buckets - 1)
                speedSum[b] += Double(fix.speed)
                speedCount[b] += 1
            }
        }

        let kept = RouteSimplifier.simplify(points, maxPoints: maxRoutePoints)
        var profile: [SpeedPoint] = []
        profile.reserveCapacity(buckets)
        if !fixes.isEmpty {
            for b in 0..<buckets {
                let center = (Double(b) + 0.5) / Double(buckets) * duration
                // A bucket without fixes (tunnel, or buckets shorter than the fix interval) takes the interpolated speed.
                let mps = speedCount[b] > 0 ? speedSum[b] / Double(speedCount[b]) : interpolator.frame(at: center).speed
                profile.append(SpeedPoint(time: center, kmh: Units.kmh(fromMetersPerSecond: max(mps, 0))))
            }
        }

        let resolved = markers.map { marker in
            let frame = fixes.isEmpty ? nil : interpolator.frame(at: marker.elapsed)
            return Marker(
                id: marker.id, kind: marker.kind, elapsed: marker.elapsed,
                coordinate: frame.map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) }
            )
        }
        let hasMotion = !reader.motion.isEmpty || !reader.accelerations.isEmpty

        return ReplayTimeline(
            interpolator: interpolator,
            duration: duration,
            route: kept.map { points[$0] },
            routeTimes: kept.map { times[$0] },
            speedProfile: profile,
            maxKmh: profile.map(\.kmh).max() ?? 0,
            markers: resolved.sorted { $0.elapsed < $1.elapsed },
            sections: sections.sorted { $0.start < $1.start },
            hasFixes: !fixes.isEmpty,
            initialCourse: initialCourse,
            hasMotionG: hasMotion && interpolator.calibration != nil
        )
    }

    /// Index of the last route point at or before `time` (-1 before the first).
    func routeIndex(atOrBefore time: TimeInterval) -> Int {
        var low = 0, high = routeTimes.count
        while low < high {
            let mid = (low + high) / 2
            if routeTimes[mid] <= time { low = mid + 1 } else { high = mid }
        }
        return low - 1
    }
}

/// Ramer–Douglas–Peucker on a local metric projection. Keeps hairpins that even index decimation would cut, which
/// matters when the camera follows the car at street zoom.
nonisolated enum RouteSimplifier {
    /// Indices of the kept points (always the first and last), at most `maxPoints`.
    static func simplify(_ points: [CLLocationCoordinate2D], maxPoints: Int) -> [Int] {
        guard points.count > maxPoints, maxPoints >= 2 else { return Array(points.indices) }
        // Bound the O(n log n) work for very dense logs (10 Hz GPS for hours): pre-thin evenly to 4× the target.
        let candidates = evenlySpaced(count: points.count, target: maxPoints * 4)
        let lat0 = points[candidates[0]].latitude * .pi / 180
        let xs = candidates.map { points[$0].longitude * 111_320 * cos(lat0) }
        let ys = candidates.map { points[$0].latitude * 110_574 }
        var tolerance = 2.0
        while true {
            let kept = douglasPeucker(xs: xs, ys: ys, tolerance: tolerance)
            if kept.count <= maxPoints { return kept.map { candidates[$0] } }
            tolerance *= 2
        }
    }

    private static func evenlySpaced(count: Int, target: Int) -> [Int] {
        guard count > target else { return Array(0..<count) }
        let step = Double(count - 1) / Double(target - 1)
        return (0..<target).map { $0 == target - 1 ? count - 1 : Int((Double($0) * step).rounded()) }
    }

    private static func douglasPeucker(xs: [Double], ys: [Double], tolerance: Double) -> [Int] {
        var keep = [Bool](repeating: false, count: xs.count)
        keep[0] = true
        keep[xs.count - 1] = true
        var stack = [(0, xs.count - 1)]
        let limit = tolerance * tolerance
        while let (a, b) = stack.popLast() {
            guard b > a + 1 else { continue }
            let dx = xs[b] - xs[a], dy = ys[b] - ys[a]
            let length2 = dx * dx + dy * dy
            var worst = 0.0, worstIndex = a
            for i in (a + 1)..<b {
                let px = xs[i] - xs[a], py = ys[i] - ys[a]
                let d2: Double
                if length2 > 0 {
                    let cross = px * dy - py * dx
                    d2 = cross * cross / length2
                } else {
                    d2 = px * px + py * py
                }
                if d2 > worst {
                    worst = d2
                    worstIndex = i
                }
            }
            if worst > limit {
                keep[worstIndex] = true
                stack.append((a, worstIndex))
                stack.append((worstIndex, b))
            }
        }
        return keep.indices.filter { keep[$0] }
    }
}
