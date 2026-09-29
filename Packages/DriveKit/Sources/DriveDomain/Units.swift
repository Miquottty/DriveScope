import Foundation

public enum Units {
    /// Standard gravity, m/s².
    public static let g = 9.80665

    public static func kmh(fromMetersPerSecond mps: Double) -> Double { mps * 3.6 }
    public static func metersPerSecond(fromKmh kmh: Double) -> Double { kmh / 3.6 }

    /// Signed smallest difference b - a between two headings in degrees, in (-180, 180].
    public static func headingDelta(from a: Double, to b: Double) -> Double {
        var d = (b - a).truncatingRemainder(dividingBy: 360)
        if d > 180 { d -= 360 }
        if d <= -180 { d += 360 }
        return d
    }

    /// Great-circle distance in meters (haversine).
    public static func distance(lat1: Double, lon1: Double, lat2: Double, lon2: Double) -> Double {
        let r = 6_371_008.8
        let p1 = lat1 * .pi / 180, p2 = lat2 * .pi / 180
        let dp = (lat2 - lat1) * .pi / 180, dl = (lon2 - lon1) * .pi / 180
        let a = sin(dp / 2) * sin(dp / 2) + cos(p1) * cos(p2) * sin(dl / 2) * sin(dl / 2)
        return 2 * r * atan2(a.squareRoot(), (1 - a).squareRoot())
    }
}
