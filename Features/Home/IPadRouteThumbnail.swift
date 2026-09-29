import DriveDomain
import SwiftUI

/// iPad route thumbnail (mock 11 sidebar and RECENT cards): the mock draws it on a 56×44 grid, so line width, dash
/// and start dot scale with the size. Bordered, unlike the phone `RouteThumbnail`.
struct IPadRouteThumbnail: View {
    let points: [RoutePoint]
    var size = CGSize(width: 56, height: 44)
    /// Recovered sessions are drawn dashed.
    var dashed = false

    var body: some View {
        let scale = size.width / 56
        Canvas { context, canvasSize in
            let bounds = CGRect(origin: .zero, size: canvasSize).insetBy(dx: 9 * scale, dy: 7 * scale)
            let projected = RouteThumbnail.project(points, into: bounds)
            guard let first = projected.first, projected.count > 1 else { return }
            var path = Path()
            path.move(to: first)
            for point in projected.dropFirst() { path.addLine(to: point) }
            context.stroke(
                path, with: .color(Theme.accent),
                style: StrokeStyle(
                    lineWidth: 2.4 * scale, lineCap: .round, lineJoin: .round, dash: dashed ? [3 * scale, 3 * scale] : []
                )
            )
            let radius = 2.6 * scale
            context.fill(
                Path(ellipseIn: CGRect(x: first.x - radius, y: first.y - radius, width: 2 * radius, height: 2 * radius)),
                with: .color(Theme.textSecondary)
            )
        }
        .frame(width: size.width, height: size.height)
        .background(Theme.background, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.divider))
        .accessibilityHidden(true)
    }
}
