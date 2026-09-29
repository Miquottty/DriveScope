import DriveDomain
import Foundation

/// Picks the points worth reverse-geocoding after a drive (PLAN §8): start, end, highest point, peak lateral g,
/// and two via points at ⅓ and ⅔ of the distance — at most 6.
public enum PlacePicker {
    public struct Candidate: Sendable, Equatable {
        public var latitude: Double
        public var longitude: Double
        public var role: PlaceRole
    }

    /// `peakLateralElapsed`: when calibrated motion saw the peak lateral g (nil → GPS-estimated peak is used).
    public static func candidates(
        locations: [LocationSample], clock: SessionClock, peakLateralElapsed: TimeInterval? = nil
    ) -> [Candidate] {
        let usable = locations.filter { $0.horizontalAccuracy > 0 && $0.horizontalAccuracy <= 50 }
        guard let first = usable.first, let last = usable.last else { return [] }
        func candidate(_ s: LocationSample, _ role: PlaceRole) -> Candidate {
            Candidate(latitude: s.latitude, longitude: s.longitude, role: role)
        }
        var result = [candidate(first, .start), candidate(last, .end)]

        if let highest = usable.filter({ $0.verticalAccuracy > 0 && $0.verticalAccuracy <= 30 }).max(by: { $0.altitude < $1.altitude }),
           highest.altitude - first.altitude > 50 {
            result.append(candidate(highest, .maxAltitude))
        }

        let peak: LocationSample? = if let peakLateralElapsed {
            usable.min { abs(clock.elapsed(unixTime: $0.timestamp) - peakLateralElapsed) < abs(clock.elapsed(unixTime: $1.timestamp) - peakLateralElapsed) }
        } else {
            gpsPeakLateral(usable)
        }
        if let peak { result.append(candidate(peak, .peakG)) }

        // Via points by distance along the route.
        var cumulative = [0.0]
        for i in 1..<usable.count {
            let a = usable[i - 1], b = usable[i]
            cumulative.append(cumulative[i - 1] + Units.distance(lat1: a.latitude, lon1: a.longitude, lat2: b.latitude, lon2: b.longitude))
        }
        if let total = cumulative.last, total > 5_000 {
            for fraction in [1.0 / 3, 2.0 / 3] {
                if let index = cumulative.firstIndex(where: { $0 >= total * fraction }) {
                    result.append(candidate(usable[index], .via))
                }
            }
        }
        // Start and end always stay; any other point within 300 m of one already kept adds nothing.
        var unique = Array(result.prefix(2))
        for c in result.dropFirst(2) where !unique.contains(where: {
            Units.distance(lat1: $0.latitude, lon1: $0.longitude, lat2: c.latitude, lon2: c.longitude) < 300
        }) {
            unique.append(c)
        }
        return Array(unique.prefix(6))
    }

    private static func gpsPeakLateral(_ fixes: [LocationSample]) -> LocationSample? {
        var best: (LocationSample, Double)?
        for i in 1..<max(fixes.count, 1) {
            let a = fixes[i - 1], b = fixes[i]
            let dt = b.timestamp - a.timestamp
            guard dt > 0, dt <= 3, a.hasValidCourse, b.hasValidCourse, b.speed > 3 else { continue }
            let g = abs(Double(b.speed) * Units.headingDelta(from: Double(a.course), to: Double(b.course)) * .pi / 180 / dt)
            if g > (best?.1 ?? 0) { best = (b, g) }
        }
        return best?.0
    }
}

/// Automatic session titles (PLAN §8): "前橋市 → 沼田市", or "前橋市 · Loop" when the drive ends where it began.
public enum SessionTitle {
    /// Start and end closer than this count as a loop.
    public static let loopRadius = 1_500.0

    public static func make(start: PlaceMeta?, end: PlaceMeta?, loopWord: String) -> String? {
        guard let start, let from = start.shortName else { return end?.shortName }
        guard let end, let to = end.shortName else { return from }
        let distance = Units.distance(lat1: start.latitude, lon1: start.longitude, lat2: end.latitude, lon2: end.longitude)
        if distance < loopRadius || from == to && distance < loopRadius * 4 {
            return "\(from) · \(loopWord)"
        }
        // Same municipality but not a loop (e.g. across town): "A → A" reads oddly.
        return from == to ? from : "\(from) → \(to)"
    }
}
