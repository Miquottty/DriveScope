import DriveDomain
import DriveRecording
import DriveStorage
import MapKit
import SwiftData
import SwiftUI

struct SessionDetailView: View {
    let sessionID: UUID

    @Environment(AppModel.self) private var model
    @Environment(AppLanguage.self) private var appLanguage
    @Environment(RecordingController.self) private var recorder
    @Environment(\.dismiss) private var dismiss
    @Query private var sessions: [DriveSession]
    @State private var route = SessionRoute()
    @State private var camera = MapCameraPosition.automatic
    @State private var isRenaming = false
    @State private var draftTitle = ""
    @State private var isConfirmingDelete = false
    @State private var isDeleted = false
    @State private var deleteError: String?
    @State private var showsReplay = false
    @State private var showsExport = false

    private static let mapHeight: CGFloat = 340

    init(sessionID: UUID) {
        self.sessionID = sessionID
        _sessions = Query(filter: #Predicate<DriveSession> { $0.id == sessionID })
    }

    var body: some View {
        Group {
            if let session = sessions.first {
                content(session)
            } else if !isDeleted {
                ContentUnavailableView("Session not found", systemImage: "questionmark.folder")
            }
        }
        .background(Theme.background)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackgroundVisibility(.hidden, for: .navigationBar)
        .toolbarVisibility(.hidden, for: .tabBar)
        // On the root, not the bottom inset: destinations inside a safe-area inset are ignored.
        .navigationDestination(isPresented: $showsReplay) { ReplayDestination(sessionID: sessionID).equatable() }
        .sheet(isPresented: $showsExport) { ExportView(sessionID: sessionID) }
        // Outside `content`: the alert must survive the session disappearing from the query.
        .alert(
            "Could not delete the session",
            isPresented: Binding(get: { deleteError != nil }, set: { if !$0 { deleteError = nil } })
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(verbatim: deleteError ?? "")
        }
    }

    private func content(_ session: DriveSession) -> some View {
        let format = SessionFormat(language: appLanguage)
        // Show the 200-point preview immediately; the full route replaces it once the streams are read.
        let points = route.points.isEmpty ? session.routePreview : route.points
        return ScrollView {
            VStack(spacing: 0) {
                routeMap(points: points)
                    .frame(height: Self.mapHeight)
                VStack(alignment: .leading, spacing: 16) {
                    titleBlock(session, format)
                    metricsGrid(session, format)
                    logQuality(session, format)
                    SessionPlacesCard(places: session.viaPlaces)
                    SessionNotesEditor(session: session)
                }
                .padding(.horizontal, 20)
                .padding(.top, 18)
                .padding(.bottom, 12)
                .readableWidth()
            }
        }
        // The map runs under the status bar, like the mock.
        .ignoresSafeArea(edges: .top)
        .scrollBounceBehavior(.basedOnSize)
        .safeAreaInset(edge: .bottom, spacing: 0) { actionButtons }
        .task(id: session.id) { await loadRoute(for: session) }
        .toolbar { menu(session, format) }
        .alert("Rename", isPresented: $isRenaming) {
            TextField("Session name", text: $draftTitle)
            Button("Save") { commitRename(session, format) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Leave empty to use the automatic name.")
        }
        .confirmationDialog("Delete this session?", isPresented: $isConfirmingDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) { delete(session) }
        } message: {
            Text("The recorded data is removed from this device.")
        }
    }

    // MARK: Rename and delete

    /// The session being recorded right now keeps its files (same rule as the Sessions swipe action).
    private func isRecording(_ session: DriveSession) -> Bool {
        recorder.session?.id == session.id
    }

    @ToolbarContentBuilder
    private func menu(_ session: DriveSession, _ format: SessionFormat) -> some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                Button {
                    beginRename(session, format)
                } label: {
                    Label("Rename", systemImage: "pencil")
                }
                Button(role: .destructive) {
                    isConfirmingDelete = true
                } label: {
                    Label("Delete", systemImage: "trash")
                }
                .disabled(isRecording(session))
            } label: {
                Image(systemName: "ellipsis")
                    .foregroundStyle(Theme.textPrimary)
            }
            .accessibilityLabel("More")
            .accessibilityIdentifier("sessionMenu")
        }
    }

    private func beginRename(_ session: DriveSession, _ format: SessionFormat) {
        draftTitle = format.title(session)
        isRenaming = true
    }

    private func commitRename(_ session: DriveSession, _ format: SessionFormat) {
        let name = draftTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty {
            // Back to the automatic name: clear it so the date shows if regeneration cannot produce one.
            session.titleIsUserEdited = false
            session.title = ""
            try? model.store.save()
            // A running session is named by the finalizer at STOP.
            guard !isRecording(session) else { return }
            Task { await model.finalizer.finalize(session) }
        } else if name != format.title(session) {
            session.title = name
            session.titleIsUserEdited = true
            try? model.store.save()
        }
    }

    private func delete(_ session: DriveSession) {
        do {
            try model.store.delete(session, filesRoot: model.filesRoot)
            isDeleted = true
            dismiss()
        } catch {
            deleteError = String(describing: error)
        }
    }

    // MARK: Map

    private func routeMap(points: [RoutePoint]) -> some View {
        let coordinates = points.map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) }
        return Map(position: $camera) {
            if coordinates.count > 1 {
                // Dark casing under the amber line, like the mock.
                MapPolyline(coordinates: coordinates).stroke(Theme.dividerStrong, lineWidth: 7)
                MapPolyline(coordinates: coordinates).stroke(Theme.accent, lineWidth: 4)
            }
            if let start = coordinates.first, coordinates.count > 1 {
                Annotation("", coordinate: start, anchor: .center) { RoutePin(ring: Theme.good) }
                    .annotationTitles(.hidden)
            }
            if let end = coordinates.last, coordinates.count > 1 {
                Annotation("", coordinate: end, anchor: .center) { RoutePin(ring: Theme.rec) }
                    .annotationTitles(.hidden)
            }
            ForEach(route.pins) { pin in
                Annotation(
                    "", coordinate: CLLocationCoordinate2D(latitude: pin.point.latitude, longitude: pin.point.longitude),
                    anchor: .leading
                ) {
                    MarkerPin(kind: pin.kind, elapsed: pin.elapsed)
                }
                .annotationTitles(.hidden)
            }
        }
        .mapStyle(.standard(elevation: .flat, emphasis: .muted, pointsOfInterest: .excludingAll))
        .overlay {
            if coordinates.isEmpty {
                Text("No route recorded")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.textMuted)
            }
        }
        .accessibilityLabel("Route map")
        .onChange(of: points.count) { _, _ in camera = Self.fit(points) }
        .onAppear { camera = Self.fit(points) }
    }

    private static func fit(_ points: [RoutePoint]) -> MapCameraPosition {
        guard !points.isEmpty else { return .automatic }
        var rect = MKMapRect.null
        for point in points {
            let mapPoint = MKMapPoint(CLLocationCoordinate2D(latitude: point.latitude, longitude: point.longitude))
            rect = rect.union(MKMapRect(origin: mapPoint, size: MKMapSize(width: 0, height: 0)))
        }
        // Breathing room, and a minimum extent so a stationary log does not zoom to the pixel level.
        let padded = rect.insetBy(dx: -max(rect.width * 0.25, 1500), dy: -max(rect.height * 0.25, 1500))
        return .rect(padded)
    }

    private func loadRoute(for session: DriveSession) async {
        let files = SessionFiles(root: model.filesRoot, sessionID: session.id)
        let markers = session.sortedMarkers.map { SessionRoute.MarkerRef(id: $0.id, kind: $0.kind, elapsed: $0.elapsed) }
        route = await SessionRoute.load(files: files, clock: session.clock, markers: markers)
    }

    // MARK: Header and metrics

    private func titleBlock(_ session: DriveSession, _ format: SessionFormat) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Button { beginRename(session, format) } label: {
                    HStack(spacing: 8) {
                        Text(verbatim: format.title(session))
                            .font(.system(size: 22, weight: .semibold))
                            .foregroundStyle(Theme.textPrimary)
                            .multilineTextAlignment(.leading)
                            .lineLimit(2)
                        Image(systemName: "pencil")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(Theme.textMuted)
                    }
                }
                .buttonStyle(.plain)
                .accessibilityHint("Rename")
                .accessibilityIdentifier("renameButton")
                if session.state == .recovered {
                    Text(verbatim: "RECOVERED")
                        .font(.system(size: 10, weight: .semibold))
                        .tracking(0.8)
                        .foregroundStyle(Theme.accent)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Theme.accent.opacity(0.15), in: RoundedRectangle(cornerRadius: 4))
                }
            }
            SessionPlacesLine(session: session, title: format.title(session))
            Text(verbatim: format.dateRangeLine(session))
                .font(.system(size: 13))
                .foregroundStyle(Theme.textSecondary)
        }
    }

    private func metricsGrid(_ session: DriveSession, _ format: SessionFormat) -> some View {
        let columns = Array(repeating: GridItem(.flexible(), spacing: 10), count: 3)
        return LazyVGrid(columns: columns, spacing: 10) {
            MetricTile(label: "Time", value: format.duration(session.duration))
            MetricTile(label: "Distance", quantity: format.distance(meters: session.distance))
            MetricTile(label: "Max", quantity: format.speed(metersPerSecond: session.maxSpeed))
            MetricTile(label: "Avg", quantity: format.speed(metersPerSecond: session.avgSpeed))
            MetricTile(label: "Gain", quantity: format.elevationGain(meters: session.elevationGain))
            MetricTile(label: "Peak G", value: format.number(session.peakLateralG, fraction: 2), tint: Theme.accent)
        }
    }

    private func logQuality(_ session: DriveSession, _ format: SessionFormat) -> some View {
        // Telemetry abbreviations stay English in both languages.
        let gps = "GPS P50 \(format.meters(session.gpsAccuracyP50).text) · P95 \(format.meters(session.gpsAccuracyP95).text)"
        let motion = session.motionSampleCount > 0
            ? "MOT \(format.integer(session.motionSampleCount)) · DROP \(format.percent(session.motionDropRate))"
            : "MOT —"
        let counts = "LOC \(format.integer(session.locationSampleCount)) · \(motion)"
        return VStack(alignment: .leading, spacing: 3) {
            Text("Log Quality")
                .font(.system(size: 10))
                .tracking(1)
                .textCase(.uppercase)
                .foregroundStyle(Theme.textSecondary)
            Text(verbatim: gps)
            Text(verbatim: "GAP MAX \(format.seconds(session.maxLocationGap).text)")
            Text(verbatim: counts)
        }
        .font(.hudNumber(size: 12))
        .foregroundStyle(Theme.textTertiary)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .combine)
    }

    private var actionButtons: some View {
        HStack(spacing: 12) {
            Button { showsReplay = true } label: {
                Label("Replay", systemImage: "play.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .frame(maxWidth: .infinity, minHeight: 56)
                    .foregroundStyle(Theme.background)
                    .background(Theme.accent, in: RoundedRectangle(cornerRadius: 14))
            }
            .accessibilityIdentifier("replayButton")
            Button { showsExport = true } label: {
                Label("Export", systemImage: "square.and.arrow.up")
                    .font(.system(size: 15, weight: .semibold))
                    .frame(maxWidth: .infinity, minHeight: 56)
                    .foregroundStyle(Theme.textPrimary)
                    .background(Theme.surface, in: RoundedRectangle(cornerRadius: 14))
                    .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Theme.dividerStrong, lineWidth: 1.5))
            }
            .accessibilityIdentifier("exportButton")
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 20)
        .padding(.top, 8)
        .padding(.bottom, 8)
        .background(Theme.background)
    }
}

private struct MetricTile: View {
    let label: LocalizedStringKey
    let value: String
    var unit = ""
    var tint = Theme.textPrimary

    init(label: LocalizedStringKey, value: String, tint: Color = Theme.textPrimary) {
        self.label = label
        self.value = value
        self.tint = tint
    }

    init(label: LocalizedStringKey, quantity: Quantity) {
        self.label = label
        value = quantity.value
        unit = quantity.unit
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(.system(size: 10))
                .tracking(1)
                .textCase(.uppercase)
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(1)
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(verbatim: value)
                    .font(.hudNumber(size: 20, weight: .medium))
                    .foregroundStyle(tint)
                if !unit.isEmpty {
                    Text(verbatim: unit)
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textSecondary)
                }
            }
            .lineLimit(1)
            .minimumScaleFactor(0.7)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .combine)
    }
}

/// Start (green ring) / end (red ring) of the route.
private struct RoutePin: View {
    let ring: Color

    var body: some View {
        Circle()
            .fill(Theme.background)
            .frame(width: 14, height: 14)
            .overlay(Circle().strokeBorder(ring, lineWidth: 3))
    }
}

private struct MarkerPin: View {
    let kind: MarkerKind
    let elapsed: TimeInterval

    var body: some View {
        HStack(spacing: 4) {
            Circle().fill(Theme.textPrimary).frame(width: 10, height: 10)
            Text(verbatim: "\(kind == .sync ? "SYNC" : "MARK") \(elapsedText)")
                .font(.hudNumber(size: 10))
                .foregroundStyle(Theme.textPrimary)
                .shadow(color: Theme.background, radius: 2)
        }
    }

    private var elapsedText: String {
        let total = max(0, Int(elapsed.rounded()))
        return String(format: "%02d:%02d", total / 60, total % 60)
    }
}
