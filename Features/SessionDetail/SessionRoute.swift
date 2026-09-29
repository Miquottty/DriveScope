import DriveDomain
import DriveStorage
import Foundation

/// The full route of a session plus marker positions, read from the binary location stream off the main actor.
nonisolated struct SessionRoute: Sendable {
    nonisolated struct MarkerRef: Sendable {
        var id: UUID
        var kind: MarkerKind
        var elapsed: TimeInterval
    }

    nonisolated struct Pin: Sendable, Identifiable {
        var id: UUID
        var kind: MarkerKind
        var elapsed: TimeInterval
        var point: RoutePoint
    }

    var points: [RoutePoint] = []
    var pins: [Pin] = []

    /// Runs on the global executor (`@concurrent`): a multi-hour log has tens of thousands of fixes.
    @concurrent
    static func load(files: SessionFiles, clock: SessionClock, markers: [MarkerRef]) async -> SessionRoute {
        guard let all = try? files.locations() else { return SessionRoute() }
        // Same filter as `SessionStore.routePreview`, so the preview and the full route agree.
        let fixes = all.filter { $0.horizontalAccuracy > 0 && $0.horizontalAccuracy <= 50 }
        let points = fixes.map { RoutePoint(latitude: $0.latitude, longitude: $0.longitude) }
        let times = fixes.map { clock.elapsed(unixTime: $0.timestamp) }
        let pins = markers.compactMap { marker -> Pin? in
            guard let point = interpolate(points, times: times, at: marker.elapsed) else { return nil }
            return Pin(id: marker.id, kind: marker.kind, elapsed: marker.elapsed, point: point)
        }
        return SessionRoute(points: points, pins: pins)
    }

    /// Linear interpolation between the two fixes around `elapsed`; clamps to the first / last fix.
    static func interpolate(_ points: [RoutePoint], times: [TimeInterval], at elapsed: TimeInterval) -> RoutePoint? {
        guard let firstTime = times.first, let lastTime = times.last else { return nil }
        if elapsed <= firstTime { return points[0] }
        if elapsed >= lastTime { return points[points.count - 1] }
        // First index whose time is > elapsed.
        var low = 0, high = times.count - 1
        while low < high {
            let mid = (low + high) / 2
            if times[mid] > elapsed { high = mid } else { low = mid + 1 }
        }
        let (a, b) = (points[low - 1], points[low])
        let span = times[low] - times[low - 1]
        let t = span > 0 ? (elapsed - times[low - 1]) / span : 0
        return RoutePoint(
            latitude: a.latitude + (b.latitude - a.latitude) * t,
            longitude: a.longitude + (b.longitude - a.longitude) * t
        )
    }
}
