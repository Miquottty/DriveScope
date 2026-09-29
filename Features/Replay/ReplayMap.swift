import DriveDomain
import DriveReplay
import MapKit
import SwiftUI

/// Map half of the Replay screen (mock artboard 5): full route with the played part in solid amber, the car arrow
/// at the playhead, start / end / marker pins, and the FOLLOW / 3D toggles over the map.
struct ReplayMap: View {
    let player: ReplayPlayer
    /// SwiftData's ≤ 200-point preview, drawn until the streams are read.
    let previewRoute: [RoutePoint]
    let onBack: () -> Void

    static let followDistance = 1600.0
    static let pitch3D = 60.0

    @State private var position = MapCameraPosition.automatic
    @State private var follows = true
    @State private var is3D = false
    /// Camera heading while the user steers the camera (FOLLOW off); the arrow is drawn relative to it.
    @State private var freeHeading = 0.0
    @State private var lastCamera = CameraMemo()
    @State private var overlays = RouteOverlays()

    var body: some View {
        ZStack(alignment: .top) {
            // Full bleed under the status bar (and the side / home-indicator insets in landscape).
            map
                .ignoresSafeArea(edges: [.top, .leading, .bottom])
            chrome
                .padding(.horizontal, 16)
                .padding(.top, 9)
        }
    }

    // MARK: Map

    private var map: some View {
        let timeline = player.timeline
        let frame = player.frame
        return Map(position: $position, interactionModes: is3D ? .all : [.pan, .zoom, .rotate]) {
            if let timeline {
                routeContent(timeline, frame: frame)
            } else if previewRoute.count > 1 {
                let coordinates = previewRoute.map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) }
                MapPolyline(coordinates: coordinates).stroke(Theme.dividerStrong, style: Self.line(7))
                MapPolyline(coordinates: coordinates).stroke(Theme.accent.opacity(0.28), style: Self.line(4))
            }
        }
        .mapStyle(.standard(elevation: is3D ? .realistic : .flat, emphasis: .muted, pointsOfInterest: .excludingAll))
        .mapControls {}
        .onMapCameraChange(frequency: .continuous) { context in
            lastCamera.camera = context.camera
            if !follows, abs(Units.headingDelta(from: freeHeading, to: context.camera.heading)) > 0.5 {
                freeHeading = context.camera.heading
            }
        }
        // Any pan / zoom / rotate by the user ends FOLLOW; tapping FOLLOW resumes it at the user's zoom.
        .onChange(of: position.positionedByUser) { _, byUser in
            guard byUser, follows else { return }
            follows = false
            freeHeading = lastCamera.camera?.heading ?? 0
        }
        .onChange(of: frame) { _, frame in
            guard follows, let frame, timeline?.hasFixes == true else { return }
            position = followPosition(frame)
        }
        .overlay { message(timeline) }
        .accessibilityLabel(Text("Route map"))
    }

    @MapContentBuilder
    private func routeContent(_ timeline: ReplayTimeline, frame: ReplayTelemetryFrame?) -> some MapContent {
        let route = timeline.route
        if route.count > 1 {
            let full = overlays.full(route)
            MapPolyline(full).stroke(Theme.dividerStrong, style: Self.line(7))
            MapPolyline(full).stroke(Theme.accent.opacity(0.28), style: Self.line(4))
            if let frame {
                let last = timeline.routeIndex(atOrBefore: frame.time)
                if last >= 0 {
                    // Played part: the cached prefix up to the last passed point, plus a short tail to the car.
                    MapPolyline(overlays.prefix(route, through: last)).stroke(Theme.accent, style: Self.line(4))
                    MapPolyline(coordinates: [route[last], frame.coordinate]).stroke(Theme.accent, style: Self.line(4))
                }
            }
            Annotation("", coordinate: route[0], anchor: .center) { RouteEndPin(ring: Theme.good) }
                .annotationTitles(.hidden)
            Annotation("", coordinate: route[route.count - 1], anchor: .center) { RouteEndPin(ring: Theme.rec) }
                .annotationTitles(.hidden)
        }
        ForEach(timeline.markers) { marker in
            if let coordinate = marker.coordinate {
                Annotation("", coordinate: coordinate, anchor: .center) { ReplayMarkerPin(marker: marker) }
                    .annotationTitles(.hidden)
            }
        }
        if let frame, timeline.hasFixes {
            Annotation("", coordinate: frame.coordinate, anchor: .center) {
                CarArrow()
                    .rotationEffect(.degrees(arrowRotation(course: frame.course)))
                    .opacity(frame.hasFix ? 1 : 0.5)
            }
            .annotationTitles(.hidden)
        }
    }

    @ViewBuilder
    private func message(_ timeline: ReplayTimeline?) -> some View {
        if player.loadState == .failed {
            mapMessage(Text("Could not read the log files."))
        } else if let timeline, timeline.route.isEmpty, !timeline.hasFixes {
            mapMessage(Text("No route recorded"))
        }
    }

    private func mapMessage(_ text: Text) -> some View {
        text
            .font(.system(size: 13))
            .foregroundStyle(Theme.textSecondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Theme.background.opacity(0.92), in: RoundedRectangle(cornerRadius: 8))
    }

    // MARK: Camera

    /// The arrow is a screen-space annotation, so it turns by the course relative to the camera heading.
    private func arrowRotation(course: Double) -> Double {
        if follows { return is3D ? 0 : course }
        return course - freeHeading
    }

    private func followPosition(_ frame: ReplayTelemetryFrame) -> MapCameraPosition {
        .camera(MapCamera(
            centerCoordinate: frame.coordinate,
            distance: lastCamera.followDistance,
            // 3D is a chase view behind the car; 2D stays north-up.
            heading: is3D ? frame.course : 0,
            pitch: is3D ? Self.pitch3D : 0
        ))
    }

    private func toggleFollow() {
        follows.toggle()
        if follows {
            // Resume at the user's zoom, within reason (the camera may still be the initial world fit).
            if let camera = lastCamera.camera { lastCamera.followDistance = min(max(camera.distance, 250), 50_000) }
            if let frame = player.frame, player.timeline?.hasFixes == true {
                withAnimation(.easeInOut(duration: 0.35)) { position = followPosition(frame) }
            }
        } else {
            freeHeading = lastCamera.camera?.heading ?? 0
        }
    }

    private func toggle3D() {
        is3D.toggle()
        if follows, let frame = player.frame, player.timeline?.hasFixes == true {
            withAnimation(.easeInOut(duration: 0.35)) { position = followPosition(frame) }
        } else if let camera = lastCamera.camera {
            var next = camera
            next.pitch = is3D ? Self.pitch3D : 0
            withAnimation(.easeInOut(duration: 0.35)) { position = .camera(next) }
        }
    }

    // MARK: Chrome

    private var chrome: some View {
        HStack(alignment: .top) {
            Button(action: onBack) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .frame(width: 44, height: 44)
                    .background(Theme.background.opacity(0.92), in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("Back"))
            Spacer()
            HStack(spacing: 6) {
                MapToggleChip(isOn: follows, action: toggleFollow) {
                    Text("Follow").textCase(.uppercase)
                }
                .accessibilityIdentifier("replayFollowToggle")
                MapToggleChip(isOn: is3D, action: toggle3D) {
                    Text(verbatim: "3D")
                }
                .accessibilityIdentifier("replay3DToggle")
            }
            .padding(.top, 6)
        }
    }

    private static func line(_ width: CGFloat) -> StrokeStyle {
        StrokeStyle(lineWidth: width, lineCap: .round, lineJoin: .round)
    }
}

/// Last camera reported by the map. A plain reference so 30 Hz camera callbacks don't invalidate the view.
private final class CameraMemo {
    var camera: MapCamera?
    var followDistance = ReplayMap.followDistance
}

/// `MKPolyline`s reused across frames, so the static lines are built once and the played prefix only when the
/// playhead passes a route point (at most `maxRoutePoints` times per replay) instead of 30 times a second.
private final class RouteOverlays {
    private var fullLine: (count: Int, polyline: MKPolyline)?
    private var prefixLine: (last: Int, polyline: MKPolyline)?

    func full(_ route: [CLLocationCoordinate2D]) -> MKPolyline {
        if let fullLine, fullLine.count == route.count { return fullLine.polyline }
        let polyline = MKPolyline(coordinates: route, count: route.count)
        fullLine = (route.count, polyline)
        return polyline
    }

    func prefix(_ route: [CLLocationCoordinate2D], through last: Int) -> MKPolyline {
        if let prefixLine, prefixLine.last == last { return prefixLine.polyline }
        let polyline = route.withUnsafeBufferPointer { MKPolyline(coordinates: $0.baseAddress!, count: last + 1) }
        prefixLine = (last, polyline)
        return polyline
    }
}

private struct MapToggleChip<Label: View>: View {
    var isOn: Bool
    var action: () -> Void
    @ViewBuilder var label: Label

    var body: some View {
        Button(action: action) {
            label
                .font(.system(size: 11, weight: .semibold))
                .tracking(0.66)
                .foregroundStyle(isOn ? Theme.background : Theme.textTertiary)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(isOn ? Theme.textPrimary : Theme.background.opacity(0.92), in: RoundedRectangle(cornerRadius: 6))
                // The chip is ~24 pt tall; widen the touch target without moving it.
                .contentShape(Rectangle().inset(by: -8))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}

/// Start (green ring) / end (red ring), as on the Detail map.
private struct RouteEndPin: View {
    let ring: Color

    var body: some View {
        Circle()
            .fill(Theme.background)
            .frame(width: 14, height: 14)
            .overlay(Circle().strokeBorder(ring, lineWidth: 3))
    }
}

private struct ReplayMarkerPin: View {
    let marker: ReplayTimeline.Marker

    var body: some View {
        let color = marker.kind == .sync ? Theme.good : Theme.textPrimary
        Circle()
            .fill(color)
            .frame(width: 10, height: 10)
            .overlay(Circle().stroke(Theme.background, lineWidth: 2))
            .overlay(alignment: .leading) {
                Text(verbatim: ReplayFormat.markerChip(kind: marker.kind, elapsed: marker.elapsed))
                    .font(.hudNumber(size: 10))
                    .foregroundStyle(color)
                    .shadow(color: Theme.background, radius: 2)
                    .fixedSize()
                    .offset(x: 14)
            }
    }
}

/// The mock's car glyph (`M0 -14 L9 10 L0 5 L-9 10 Z`), pointing north, rotated about its origin.
private struct CarArrow: View {
    var body: some View {
        ArrowShape()
            .fill(Theme.textPrimary)
            .overlay(ArrowShape().stroke(Theme.background, style: StrokeStyle(lineWidth: 2, lineJoin: .round)))
            .frame(width: 32, height: 32)
    }

    nonisolated private struct ArrowShape: Shape {
        func path(in rect: CGRect) -> Path {
            let c = CGPoint(x: rect.midX, y: rect.midY)
            var path = Path()
            path.move(to: CGPoint(x: c.x, y: c.y - 14))
            path.addLine(to: CGPoint(x: c.x + 9, y: c.y + 10))
            path.addLine(to: CGPoint(x: c.x, y: c.y + 5))
            path.addLine(to: CGPoint(x: c.x - 9, y: c.y + 10))
            path.closeSubpath()
            return path
        }
    }
}

private extension ReplayTelemetryFrame {
    var coordinate: CLLocationCoordinate2D { CLLocationCoordinate2D(latitude: latitude, longitude: longitude) }
}
