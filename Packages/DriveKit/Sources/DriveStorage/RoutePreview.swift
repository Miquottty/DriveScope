import DriveDomain

/// The ≤ 200-point route a session list draws (PLAN §11), shared by SwiftData's `SessionStore` and the Android app.
public enum RoutePreview {
    public static func make(from locations: [LocationSample], maxPoints: Int = 200) -> [RoutePoint] {
        let usable = locations.filter { $0.horizontalAccuracy > 0 && $0.horizontalAccuracy <= 50 }
        guard maxPoints >= 2, usable.count > maxPoints else {
            return usable.map { RoutePoint(latitude: $0.latitude, longitude: $0.longitude) }
        }
        let step = Double(usable.count - 1) / Double(maxPoints - 1)
        return (0..<maxPoints).map { i in
            let s = usable[i == maxPoints - 1 ? usable.count - 1 : Int((Double(i) * step).rounded())]
            return RoutePoint(latitude: s.latitude, longitude: s.longitude)
        }
    }
}
