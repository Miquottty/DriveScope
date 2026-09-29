import DriveDomain
import Foundation

/// A deterministic, physically consistent drive used on the simulator, in tests and for screenshots.
///
/// Built from waypoints: the polyline is densified with Catmull-Rom, a speed profile respects a cruise limit,
/// a lateral-g limit in corners and accel/brake limits, and optional stops. Every stream (GPS, motion,
/// altimeter) is derived from the same trajectory, so e.g. lateral g agrees with the change of GPS course.
public struct DriveScript: Sendable {
    public struct State: Sendable, Equatable {
        public var elapsed: TimeInterval
        public var latitude: Double
        public var longitude: Double
        /// Meters above sea level.
        public var altitude: Double
        /// m/s.
        public var speed: Double
        /// Compass degrees, 0 = north, clockwise.
        public var course: Double
        /// m/s², + = accelerating.
        public var longitudinalAcceleration: Double
        /// m/s², + = toward the vehicle's left (left turn).
        public var lateralAcceleration: Double
        /// rad/s about the vertical axis, + = counter-clockwise (left turn).
        public var yawRate: Double
        /// Distance travelled, meters.
        public var distance: Double
        /// GPS is unavailable here (tunnel).
        public var inTunnel: Bool
    }

    public struct Configuration: Sendable {
        public var cruiseSpeed = 60 / 3.6
        public var maxLateralAcceleration = 0.35 * Units.g
        public var acceleration = 0.25 * Units.g
        public var braking = 0.35 * Units.g
        public var startAltitude = 110.0
        public var endAltitude = 1340.0
        /// Fractions of the route length with a full stop, and how long each stop lasts.
        public var stops: [Double] = []
        public var stopDuration: TimeInterval = 20
        /// Fraction range of the route length without GPS.
        public var tunnel: ClosedRange<Double>?

        public init() {}
    }

    private struct Node {
        var s: Double
        var t: Double
        var v: Double
        var x: Double
        var y: Double
        var heading: Double
        var curvature: Double
    }

    private let nodes: [Node]
    private let origin: (lat: Double, lon: Double)
    private let config: Configuration
    public let length: Double
    public var duration: TimeInterval { nodes.last?.t ?? 0 }

    public init(waypoints: [(lat: Double, lon: Double)], configuration: Configuration = Configuration()) {
        precondition(waypoints.count >= 2)
        let origin = waypoints[0]
        self.origin = origin
        config = configuration
        let metersPerDegLat = 111_132.0
        let metersPerDegLon = 111_320.0 * cos(origin.lat * .pi / 180)
        let points = waypoints.map { (x: ($0.lon - origin.lon) * metersPerDegLon, y: ($0.lat - origin.lat) * metersPerDegLat) }
        // Smooth the geometry itself (not the curvature) so heading and curvature stay consistent at kinks.
        var dense = Self.catmullRom(points, spacing: 5)
        for _ in 0..<3 {
            let xs = Self.smooth(dense.map(\.x), radius: 4), ys = Self.smooth(dense.map(\.y), radius: 4)
            dense = zip(xs, ys).map { (x: $0, y: $1) }
        }

        // Arc length, heading (math angle, CCW from east) and curvature.
        var s = [0.0]
        var heading = [Double]()
        for i in 1..<dense.count {
            let dx = dense[i].x - dense[i - 1].x, dy = dense[i].y - dense[i - 1].y
            s.append(s[i - 1] + (dx * dx + dy * dy).squareRoot())
            heading.append(atan2(dy, dx))
        }
        heading.append(heading.last!)
        var curvature = [Double](repeating: 0, count: dense.count)
        for i in 1..<dense.count - 1 {
            let ds = s[i + 1] - s[i - 1]
            if ds > 0 { curvature[i] = Self.wrap(heading[i] - heading[i - 1]) / (ds / 2) }
        }
        curvature = Self.smooth(curvature, radius: 1)
        length = s.last!

        // Speed profile: limits, then forward (acceleration) and backward (braking) passes.
        let stopIndices = Set(configuration.stops.map { f in s.firstIndex { $0 >= f * s.last! } ?? s.count - 1 })
        var v = curvature.map { k in min(configuration.cruiseSpeed, (configuration.maxLateralAcceleration / max(abs(k), 1e-6)).squareRoot()) }
        v[0] = 0
        v[v.count - 1] = 0
        for i in stopIndices { v[i] = 0 }
        for i in 1..<v.count {
            v[i] = min(v[i], (v[i - 1] * v[i - 1] + 2 * configuration.acceleration * (s[i] - s[i - 1])).squareRoot())
        }
        for i in stride(from: v.count - 2, through: 0, by: -1) {
            v[i] = min(v[i], (v[i + 1] * v[i + 1] + 2 * configuration.braking * (s[i + 1] - s[i])).squareRoot())
        }

        var nodes: [Node] = []
        var t = 0.0
        for i in dense.indices {
            if i > 0 {
                let mean = (v[i] + v[i - 1]) / 2
                t += (s[i] - s[i - 1]) / max(mean, 0.3)
            }
            nodes.append(Node(s: s[i], t: t, v: v[i], x: dense[i].x, y: dense[i].y, heading: heading[i], curvature: curvature[i]))
            if stopIndices.contains(i), i > 0, i < dense.count - 1 {
                t += configuration.stopDuration
                var dwell = nodes[nodes.count - 1]
                dwell.t = t
                nodes.append(dwell)
            }
        }
        self.nodes = nodes
    }

    public func state(at elapsed: TimeInterval) -> State {
        let t = min(max(elapsed, 0), duration)
        // Binary search for the segment containing t.
        var lo = 0, hi = nodes.count - 1
        while hi - lo > 1 {
            let mid = (lo + hi) / 2
            if nodes[mid].t <= t { lo = mid } else { hi = mid }
        }
        let a = nodes[lo], b = nodes[hi]
        let span = b.t - a.t
        let f = span > 0 ? (t - a.t) / span : 0
        let x = a.x + (b.x - a.x) * f, y = a.y + (b.y - a.y) * f
        let speed = a.v + (b.v - a.v) * f
        let heading = a.heading + Self.wrap(b.heading - a.heading) * f
        let curvature = a.curvature + (b.curvature - a.curvature) * f
        let distance = a.s + (b.s - a.s) * f
        let fraction = length > 0 ? distance / length : 0

        let metersPerDegLat = 111_132.0
        let metersPerDegLon = 111_320.0 * cos(origin.lat * .pi / 180)
        let altitude = config.startAltitude + (config.endAltitude - config.startAltitude) * fraction
            + 12 * sin(fraction * .pi * 9)
        var course = (90 - heading * 180 / .pi).truncatingRemainder(dividingBy: 360)
        if course < 0 { course += 360 }

        return State(
            elapsed: t,
            latitude: origin.lat + y / metersPerDegLat,
            longitude: origin.lon + x / metersPerDegLon,
            altitude: altitude,
            speed: speed,
            course: course,
            longitudinalAcceleration: span > 0 ? (b.v - a.v) / span : 0,
            lateralAcceleration: speed * speed * curvature,
            yawRate: speed * curvature,
            distance: distance,
            inTunnel: config.tunnel.map { $0.contains(fraction) } ?? false
        )
    }

    // MARK: - Geometry helpers

    private static func wrap(_ angle: Double) -> Double {
        var a = angle.truncatingRemainder(dividingBy: 2 * .pi)
        if a > .pi { a -= 2 * .pi }
        if a <= -.pi { a += 2 * .pi }
        return a
    }

    private static func smooth(_ values: [Double], radius: Int) -> [Double] {
        values.indices.map { i in
            let range = max(0, i - radius)...min(values.count - 1, i + radius)
            return values[range].reduce(0, +) / Double(range.count)
        }
    }

    /// Uniform Catmull-Rom through the points, sampled roughly every `spacing` meters.
    private static func catmullRom(_ p: [(x: Double, y: Double)], spacing: Double) -> [(x: Double, y: Double)] {
        var out: [(x: Double, y: Double)] = [p[0]]
        for i in 0..<p.count - 1 {
            let p0 = p[max(i - 1, 0)], p1 = p[i], p2 = p[i + 1], p3 = p[min(i + 2, p.count - 1)]
            let segment = ((p2.x - p1.x) * (p2.x - p1.x) + (p2.y - p1.y) * (p2.y - p1.y)).squareRoot()
            let steps = max(1, Int(segment / spacing))
            for step in 1...steps {
                let t = Double(step) / Double(steps), t2 = t * t, t3 = t2 * t
                func blend(_ a: Double, _ b: Double, _ c: Double, _ d: Double) -> Double {
                    0.5 * (2 * b + (-a + c) * t + (2 * a - 5 * b + 4 * c - d) * t2 + (-a + 3 * b - 3 * c + d) * t3)
                }
                out.append((blend(p0.x, p1.x, p2.x, p3.x), blend(p0.y, p1.y, p2.y, p3.y)))
            }
        }
        return out
    }
}

extension DriveScript {
    /// Maebashi → Akagi Onuma: city start with a traffic-light stop, a long straight, hairpins up the mountain,
    /// and a 90-ish-second tunnel. Same waypoints as `scripts/routes/akagi.txt`.
    public static let akagi: DriveScript = {
        var config = Configuration()
        config.stops = [0.04]
        config.tunnel = 0.30...0.33
        return DriveScript(waypoints: akagiWaypoints, configuration: config)
    }()

    public static func named(_ name: String) -> DriveScript? {
        switch name.lowercased() {
        case "akagi": .akagi
        default: nil
        }
    }

    static let akagiWaypoints: [(lat: Double, lon: Double)] = [
        (36.38950, 139.06100), (36.39600, 139.07000), (36.40500, 139.08000), (36.41500, 139.09000),
        (36.42600, 139.10000), (36.43800, 139.11000), (36.45000, 139.11900), (36.46200, 139.12700),
        (36.47400, 139.13400), (36.47509, 139.13521), (36.47607, 139.13823), (36.47685, 139.14201),
        (36.47750, 139.14530), (36.47859, 139.14651), (36.47957, 139.14349), (36.48035, 139.13971),
        (36.48100, 139.13862), (36.48209, 139.13983), (36.48307, 139.14285), (36.48385, 139.14663),
        (36.48450, 139.14992), (36.48559, 139.15113), (36.48657, 139.14811), (36.48735, 139.14433),
        (36.48800, 139.14324), (36.48909, 139.14445), (36.49007, 139.14747), (36.49085, 139.15125),
        (36.49150, 139.15454), (36.49259, 139.15575), (36.49357, 139.15273), (36.49435, 139.14895),
        (36.49500, 139.14786), (36.49609, 139.14907), (36.49707, 139.15209), (36.49785, 139.15587),
        (36.49850, 139.15916), (36.49959, 139.16037), (36.50057, 139.15735), (36.50135, 139.15357),
        (36.50200, 139.15248), (36.50309, 139.15369), (36.50407, 139.15671), (36.50485, 139.16049),
        (36.50550, 139.16378), (36.50659, 139.16499), (36.50757, 139.16197), (36.50835, 139.15819),
        (36.50900, 139.15600), (36.54800, 139.17900), (36.55300, 139.18800),
    ]
}
