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
    var style = Style.phone
    let onBack: () -> Void

    enum Style {
        case phone
        /// iPad full-screen map (mock artboard 14): title block beside a 52 pt back button, 44 pt chips, a heavier
        /// route and larger pins.
        case pad(title: String, subtitle: String)

        var isPad: Bool {
            if case .pad = self { true } else { false }
        }
    }

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
            if case .pad(let title, let subtitle) = style {
                padChrome(title: title, subtitle: subtitle)
                    .padding(.horizontal, 24)
                    .padding(.top, 8)
            } else {
                chrome
                    .padding(.horizontal, 16)
                    .padding(.top, 9)
            }
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
                MapPolyline(coordinates: coordinates).stroke(route.casing, style: Self.line(route.casingWidth))
                MapPolyline(coordinates: coordinates).stroke(route.upcoming, style: Self.line(route.upcomingWidth))
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
        let style = self.route
        if route.count > 1 {
            let full = overlays.full(route)
            MapPolyline(full).stroke(style.casing, style: Self.line(style.casingWidth))
            MapPolyline(full).stroke(style.upcoming, style: Self.line(style.upcomingWidth))
            if let frame {
                let last = timeline.routeIndex(atOrBefore: frame.time)
                if last >= 0 {
                    // Played part: the cached prefix up to the last passed point, plus a short tail to the car.
                    MapPolyline(overlays.prefix(route, through: last))
                        .stroke(Theme.accent, style: Self.line(style.playedWidth))
                    MapPolyline(coordinates: [route[last], frame.coordinate])
                        .stroke(Theme.accent, style: Self.line(style.playedWidth))
                }
            }
            Annotation("", coordinate: route[0], anchor: .center) {
                RouteEndPin(ring: Theme.good, isLarge: style.isPad)
            }
            .annotationTitles(.hidden)
            Annotation("", coordinate: route[route.count - 1], anchor: .center) {
                RouteEndPin(ring: Theme.rec, isLarge: style.isPad)
            }
            .annotationTitles(.hidden)
        }
        ForEach(timeline.markers) { marker in
            if let coordinate = marker.coordinate {
                Annotation("", coordinate: coordinate, anchor: .center) {
                    ReplayMarkerPin(marker: marker, isLarge: style.isPad)
                }
                .annotationTitles(.hidden)
            }
        }
        if let frame, timeline.hasFixes {
            Annotation("", coordinate: frame.coordinate, anchor: .center) {
                CarArrow(isLarge: style.isPad)
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
            .font(.system(size: style.isPad ? 15 : 13))
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

    /// iPad (mock artboard 14): back button and the session's title / date at the left, 44 pt FOLLOW / 3D pills at
    /// the right. The readout card sits under the pills (`ReplayIPadLayout`).
    private func padChrome(title: String, subtitle: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Button(action: onBack) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .frame(width: 52, height: 52)
                    .background(Theme.background, in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("Back"))
            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: title)
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                Text(verbatim: subtitle)
                    .font(.system(size: 14))
                    .foregroundStyle(Theme.textTertiary)
            }
            .lineLimit(1)
            // No panel behind the title in the mock: a soft dark halo keeps it legible over bright map tiles.
            .shadow(color: Theme.background, radius: 3)
            .shadow(color: Theme.background.opacity(0.6), radius: 8)
            .frame(height: 52)
            .accessibilityElement(children: .combine)
            Spacer(minLength: 16)
            HStack(spacing: 8) {
                MapToggleChip(isOn: follows, isLarge: true, action: toggleFollow) {
                    Text("Follow").textCase(.uppercase)
                }
                .accessibilityIdentifier("replayFollowToggle")
                MapToggleChip(isOn: is3D, isLarge: true, action: toggle3D) {
                    Text(verbatim: "3D")
                }
                .accessibilityIdentifier("replay3DToggle")
            }
        }
    }

    private var route: RouteStyle { style.isPad ? .pad : .phone }

    private static func line(_ width: CGFloat) -> StrokeStyle {
        StrokeStyle(lineWidth: width, lineCap: .round, lineJoin: .round)
    }
}

/// Route strokes: phone (artboard 5) and the heavier iPad line (artboard 14: dark casing, 5 pt upcoming, 6 pt played).
private struct RouteStyle {
    var casing: Color
    var casingWidth: CGFloat
    var upcoming: Color
    var upcomingWidth: CGFloat
    var playedWidth: CGFloat
    var isPad: Bool

    static let phone = RouteStyle(casing: Theme.dividerStrong, casingWidth: 7, upcoming: Theme.accent.opacity(0.28),
                                  upcomingWidth: 4, playedWidth: 4, isPad: false)
    static let pad = RouteStyle(casing: Theme.background, casingWidth: 11, upcoming: Theme.accent.opacity(0.35),
                                upcomingWidth: 5, playedWidth: 6, isPad: true)
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
    /// iPad: 44 pt pill, 15 pt title (mock artboard 14).
    var isLarge = false
    var action: () -> Void
    @ViewBuilder var label: Label

    var body: some View {
        Button(action: action) {
            if isLarge {
                label
                    .font(.system(size: 15, weight: .semibold))
                    .tracking(0.6)
                    .foregroundStyle(isOn ? Theme.background : Theme.textPrimary)
                    .padding(.horizontal, 18)
                    .frame(height: 44)
                    .background(isOn ? Theme.textPrimary : Theme.background, in: Capsule())
                    // 44 pt visible, 52 pt to the finger.
                    .contentShape(Rectangle().inset(by: -4))
            } else {
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
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}

/// Start (green ring) / end (red ring), as on the Detail map.
private struct RouteEndPin: View {
    let ring: Color
    var isLarge = false

    var body: some View {
        Circle()
            .fill(Theme.background)
            .frame(width: isLarge ? 24 : 14, height: isLarge ? 24 : 14)
            .overlay(Circle().strokeBorder(ring, lineWidth: isLarge ? 4 : 3))
    }
}

private struct ReplayMarkerPin: View {
    let marker: ReplayTimeline.Marker
    var isLarge = false

    var body: some View {
        let color = marker.kind.color
        if isLarge {
            // iPad (mock artboard 14): 12 pt dot, 14 pt label on a dark plate.
            Circle()
                .fill(color)
                .frame(width: 12, height: 12)
                .overlay(Circle().stroke(Theme.background, lineWidth: 2))
                .overlay(alignment: .leading) {
                    Text(verbatim: ReplayFormat.markerChip(kind: marker.kind, elapsed: marker.elapsed))
                        .font(.hudNumber(size: 14))
                        .foregroundStyle(color)
                        .padding(.horizontal, 8)
                        .frame(height: 28)
                        .background(Theme.background.opacity(0.85), in: RoundedRectangle(cornerRadius: 8))
                        .fixedSize()
                        .offset(x: 18)
                }
        } else {
            phonePin(color: color)
        }
    }

    private func phonePin(color: Color) -> some View {
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

/// The mock's car glyph (`M0 -14 L9 10 L0 5 L-9 10 Z`; iPad `M0 -14 L10 12 L0 6 L-10 12 Z` on a 22 pt amber halo),
/// pointing north, rotated about its origin.
private struct CarArrow: View {
    var isLarge = false

    var body: some View {
        let shape = isLarge
            ? ArrowShape(halfWidth: 10, back: 12, notch: 6)
            : ArrowShape(halfWidth: 9, back: 10, notch: 5)
        shape
            .fill(Theme.textPrimary)
            .overlay(shape.stroke(Theme.background, style: StrokeStyle(lineWidth: 2, lineJoin: .round)))
            .frame(width: 32, height: 32)
            .background {
                if isLarge {
                    Circle().fill(Theme.accent.opacity(0.18)).frame(width: 44, height: 44)
                }
            }
    }

    nonisolated private struct ArrowShape: Shape {
        var halfWidth: CGFloat
        var back: CGFloat
        var notch: CGFloat

        func path(in rect: CGRect) -> Path {
            let c = CGPoint(x: rect.midX, y: rect.midY)
            var path = Path()
            path.move(to: CGPoint(x: c.x, y: c.y - 14))
            path.addLine(to: CGPoint(x: c.x + halfWidth, y: c.y + back))
            path.addLine(to: CGPoint(x: c.x, y: c.y + notch))
            path.addLine(to: CGPoint(x: c.x - halfWidth, y: c.y + back))
            path.closeSubpath()
            return path
        }
    }
}

private extension ReplayTelemetryFrame {
    var coordinate: CLLocationCoordinate2D { CLLocationCoordinate2D(latitude: latitude, longitude: longitude) }
}
