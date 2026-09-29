import DriveDomain
import SwiftUI

/// A session's downsampled route drawn as a `Path` in a small rounded square. No MapKit snapshots (they are slow
/// and would need the network) — the preview is at most 200 points.
struct RouteThumbnail: View {
    let points: [RoutePoint]
    var size = CGSize(width: 56, height: 44)
    /// Recovered sessions are drawn dashed, as in the mock.
    var dashed = false

    var body: some View {
        Canvas { context, canvasSize in
            let projected = Self.project(points, into: CGRect(origin: .zero, size: canvasSize).insetBy(dx: 7, dy: 7))
            guard let first = projected.first, projected.count > 1 else { return }
            var path = Path()
            path.move(to: first)
            for point in projected.dropFirst() { path.addLine(to: point) }
            context.stroke(
                path, with: .color(Theme.accent),
                style: StrokeStyle(lineWidth: 2.2, lineCap: .round, lineJoin: .round, dash: dashed ? [3, 4] : [])
            )
            context.fill(
                Path(ellipseIn: CGRect(x: first.x - 2.5, y: first.y - 2.5, width: 5, height: 5)),
                with: .color(Theme.textSecondary)
            )
        }
        .frame(width: size.width, height: size.height)
        .background(Theme.background, in: RoundedRectangle(cornerRadius: 8))
        .accessibilityHidden(true)
    }

    /// Equirectangular projection (longitude scaled by cos(latitude)), fitted into `rect` with the aspect kept.
    static func project(_ points: [RoutePoint], into rect: CGRect) -> [CGPoint] {
        guard let first = points.first else { return [] }
        var minLat = first.latitude, maxLat = first.latitude
        var minLon = first.longitude, maxLon = first.longitude
        for p in points {
            minLat = min(minLat, p.latitude); maxLat = max(maxLat, p.latitude)
            minLon = min(minLon, p.longitude); maxLon = max(maxLon, p.longitude)
        }
        let lonScale = cos((minLat + maxLat) / 2 * .pi / 180)
        let width = (maxLon - minLon) * lonScale
        let height = maxLat - minLat
        guard width > 0 || height > 0 else { return [CGPoint(x: rect.midX, y: rect.midY)] }
        let scale = min(width > 0 ? rect.width / width : .infinity, height > 0 ? rect.height / height : .infinity)
        let offsetX = rect.minX + (rect.width - width * scale) / 2
        let offsetY = rect.minY + (rect.height - height * scale) / 2
        return points.map { p in
            CGPoint(
                x: offsetX + (p.longitude - minLon) * lonScale * scale,
                y: offsetY + (maxLat - p.latitude) * scale
            )
        }
    }
}
