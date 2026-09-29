import SwiftUI

/// Friction-circle G meter (mock: 150 pt portrait, 170 pt landscape, drawn on a 150-unit grid).
///
/// Rings at ⅓ / ⅔ / 1 of `range`. Direction follows the mock: positive lateral (the engine's "+ = left")
/// plots to the right, i.e. the way the driver is pushed in a left turn; accelerating plots up.
/// The amber wedge is the recent trail swept from the centre (the mock's translucent sector).
struct GMeterView: View {
    var lateralG: Double
    var longitudinalG: Double
    /// g at the outer ring.
    var range: Double = 1.0
    var showsTrail = true
    /// Trail length in snapshots (the HUD publishes on change, ≤10 Hz).
    var trailLength = 12
    var style = Style.phone

    /// `phone` scales everything with the 150-unit grid. `pad` follows the iPad artboards (12, 14, 16): the outer
    /// ring 4 pt inside the edge in `dividerStrong`, fixed hairlines, a fixed-size dot and an optional "1.0 G" label.
    enum Style {
        case phone
        case pad(dotRadius: CGFloat, labelSize: CGFloat?)
    }

    /// The dot shows the car's acceleration vector: a left turn (+lateral) plots left, accelerating plots up.
    static let lateralSign: Double = -1

    @State private var trail: [Sample] = []

    private struct Sample: Equatable {
        var lateral: Double
        var longitudinal: Double
    }

    var body: some View {
        Canvas { context, size in
            if case .pad(let dotRadius, let labelSize) = style {
                drawPad(context, size: size, dotRadius: dotRadius, labelSize: labelSize)
                return
            }
            let side = min(size.width, size.height)
            let unit = side / 150
            let center = CGPoint(x: size.width / 2, y: size.height / 2)
            let outer = 72 * unit
            let grid = GraphicsContext.Shading.color(Theme.divider)

            for (radius, width) in [(72.0, 1.5), (48.0, 1.0), (24.0, 1.0)] {
                let r = radius * unit
                context.stroke(
                    Path(ellipseIn: CGRect(x: center.x - r, y: center.y - r, width: 2 * r, height: 2 * r)),
                    with: grid, lineWidth: width * unit)
            }
            var cross = Path()
            cross.move(to: CGPoint(x: center.x, y: center.y - outer))
            cross.addLine(to: CGPoint(x: center.x, y: center.y + outer))
            cross.move(to: CGPoint(x: center.x - outer, y: center.y))
            cross.addLine(to: CGPoint(x: center.x + outer, y: center.y))
            context.stroke(cross, with: grid, lineWidth: unit)

            if showsTrail, trail.count > 1 {
                var wedge = Path()
                wedge.move(to: center)
                for sample in trail {
                    wedge.addLine(to: point(sample, center: center, radius: outer))
                }
                wedge.closeSubpath()
                context.fill(wedge, with: .color(Theme.accent.opacity(0.18)))
            }

            context.draw(
                Text(verbatim: String(format: "%.1f", range))
                    .font(.hudNumber(size: 9 * unit))
                    .foregroundStyle(Theme.textSecondary),
                at: CGPoint(x: center.x, y: center.y - 61 * unit), anchor: .center)

            let dot = point(Sample(lateral: lateralG, longitudinal: longitudinalG), center: center, radius: outer)
            let dotRadius = 7 * unit
            context.fill(
                Path(ellipseIn: CGRect(x: dot.x - dotRadius, y: dot.y - dotRadius, width: 2 * dotRadius, height: 2 * dotRadius)),
                with: .color(Theme.accent))
        }
        .aspectRatio(1, contentMode: .fit)
        .onChange(of: Sample(lateral: lateralG, longitudinal: longitudinalG), initial: true) { _, sample in
            guard showsTrail else { return }
            trail.append(sample)
            if trail.count > trailLength { trail.removeFirst(trail.count - trailLength) }
        }
        .accessibilityElement()
        .accessibilityLabel(Text(verbatim: "G meter"))
        .accessibilityValue(Text(verbatim:
            "LATERAL \(HUDFormat.signedG(lateralG)) G, LONG \(HUDFormat.signedG(longitudinalG)) G"))
    }

    private func drawPad(_ context: GraphicsContext, size: CGSize, dotRadius: CGFloat, labelSize: CGFloat?) {
        let side = min(size.width, size.height)
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        let outer = side / 2 - 4
        let hairline = GraphicsContext.Shading.color(Theme.divider)
        func circle(_ r: CGFloat, at c: CGPoint) -> Path {
            Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r))
        }

        context.stroke(circle(outer, at: center), with: .color(Theme.dividerStrong), lineWidth: 2)
        context.stroke(circle(outer * 2 / 3, at: center), with: hairline, lineWidth: 1.5)
        context.stroke(circle(outer / 3, at: center), with: hairline, lineWidth: 1.5)
        var cross = Path()
        cross.move(to: CGPoint(x: center.x, y: center.y - outer))
        cross.addLine(to: CGPoint(x: center.x, y: center.y + outer))
        cross.move(to: CGPoint(x: center.x - outer, y: center.y))
        cross.addLine(to: CGPoint(x: center.x + outer, y: center.y))
        context.stroke(cross, with: hairline, lineWidth: 1.5)

        if showsTrail, trail.count > 1 {
            var wedge = Path()
            wedge.move(to: center)
            for sample in trail {
                wedge.addLine(to: point(sample, center: center, radius: outer, dotRadius: dotRadius))
            }
            wedge.closeSubpath()
            context.fill(wedge, with: .color(Theme.accent.opacity(0.16)))
        }

        if let labelSize {
            // Mock: baseline 22 pt below the top edge, i.e. just inside the outer ring.
            context.draw(
                Text(verbatim: String(format: "%.1f G", range))
                    .font(.hudNumber(size: labelSize))
                    .foregroundStyle(Theme.textSecondary),
                at: CGPoint(x: center.x, y: center.y - side / 2 + 22), anchor: UnitPoint(x: 0.5, y: 0.8))
        }

        let dot = point(Sample(lateral: lateralG, longitudinal: longitudinalG), center: center, radius: outer,
                        dotRadius: dotRadius)
        context.fill(circle(dotRadius, at: dot), with: .color(Theme.accent))
    }

    /// `pad` geometry: same mapping, clamped so the dot stays inside the ring's outer edge.
    private func point(_ sample: Sample, center: CGPoint, radius: CGFloat, dotRadius: CGFloat) -> CGPoint {
        let limit = max(radius + 4 - dotRadius, 0) / radius
        return point(sample, center: center, radius: radius, limit: limit)
    }

    /// Maps g to canvas coordinates, clamping so a spike past `range` keeps the whole dot inside the canvas.
    private func point(_ sample: Sample, center: CGPoint, radius: CGFloat) -> CGPoint {
        point(sample, center: center, radius: radius, limit: (75.0 - 7.0) / 72.0)
    }

    private func point(_ sample: Sample, center: CGPoint, radius: CGFloat, limit: Double) -> CGPoint {
        var x = Self.lateralSign * sample.lateral / range
        var y = sample.longitudinal / range
        let magnitude = (x * x + y * y).squareRoot()
        if magnitude > limit {
            x *= limit / magnitude
            y *= limit / magnitude
        }
        return CGPoint(x: center.x + x * radius, y: center.y - y * radius)
    }
}
