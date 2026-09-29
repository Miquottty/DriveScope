import DriveDomain
import DriveRecording
import DriveStorage
import MapKit
import SwiftData
import SwiftUI

struct SessionDetailView: View {
    let sessionID: UUID
    /// iPad: the detail is the split view's root, so after a delete the shell picks what to show instead.
    var onDeleted: (() -> Void)?

    @Environment(AppModel.self) private var model
    @Environment(AppLanguage.self) private var appLanguage
    @Environment(RecordingController.self) private var recorder
    @Environment(\.dismiss) private var dismiss
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Query private var sessions: [DriveSession]
    @State private var route = SessionRoute()
    @State private var camera = MapCameraPosition.automatic
    @State private var isRenaming = false
    @State private var draftTitle = ""
    @State private var isConfirmingDelete = false
    @State private var isDeleted = false
    @State private var deleteError: String?
    @State private var showsReplay = false
    /// iPad: Replay is full screen (mock 14) instead of a push inside the detail column.
    @State private var showsReplayCover = false
    @State private var showsExport = false

    private static let mapHeight: CGFloat = 340
    /// iPad map beside the panel (mock 13: 480 pt); it gives way so three 30 pt metric tiles still fit.
    private static let iPadMapMaxWidth: CGFloat = 480
    private static let iPadPanelMinWidth: CGFloat = 440

    init(sessionID: UUID, onDeleted: (() -> Void)? = nil) {
        self.sessionID = sessionID
        self.onDeleted = onDeleted
        _sessions = Query(filter: #Predicate<DriveSession> { $0.id == sessionID })
    }

    private var isRegular: Bool { horizontalSizeClass == .regular }

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
        .fullScreenCover(isPresented: $showsReplayCover) { ReplayDestination(sessionID: sessionID).equatable() }
        .sheet(isPresented: $showsExport) {
            if isRegular {
                ExportView(sessionID: sessionID).iPadFormSheet()
            } else {
                ExportView(sessionID: sessionID)
            }
        }
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
        return Group {
            if isRegular {
                iPadContent(session, format, points: points)
            } else {
                phoneContent(session, format, points: points)
            }
        }
        .task(id: session.id) {
            await loadRoute(for: session)
            // Sessions recorded before V1.1 (or by an older detector) get their sections here.
            await model.finalizer.ensureSections(session)
        }
        .alert("Rename", isPresented: $isRenaming) {
            TextField("Session name", text: $draftTitle)
            Button("Save") { commitRename(session, format) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Leave empty to use the automatic name.")
        }
    }

    private func phoneContent(_ session: DriveSession, _ format: SessionFormat, points: [RoutePoint]) -> some View {
        ScrollView {
            VStack(spacing: 0) {
                routeMap(points: points)
                    .frame(height: Self.mapHeight)
                VStack(alignment: .leading, spacing: 16) {
                    titleBlock(session, format)
                    metricsGrid(session, format)
                    logQuality(session, format)
                    SessionSectionsCard(sections: session.sections)
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
        .toolbar { menu(session, format) }
        .confirmationDialog("Delete this session?", isPresented: $isConfirmingDelete, titleVisibility: .visible) {
            deleteConfirmation(session)
        } message: {
            Text("The recorded data is removed from this device.")
        }
    }

    @ViewBuilder private func deleteConfirmation(_ session: DriveSession) -> some View {
        Button("Delete", role: .destructive) { delete(session) }
    }

    // MARK: iPad (mock 13)

    /// Map-first: the map runs the full height on the left and the panel scrolls beside it. In portrait (or a
    /// narrow window) the map sits on top at ~45 % of the height.
    private func iPadContent(_ session: DriveSession, _ format: SessionFormat, points: [RoutePoint]) -> some View {
        GeometryReader { geometry in
            let size = geometry.size
            if size.width > size.height && size.width >= Self.iPadPanelMinWidth + 300 {
                HStack(spacing: 0) {
                    iPadMap(session, points: points)
                        .frame(width: min(Self.iPadMapMaxWidth, size.width - Self.iPadPanelMinWidth))
                        .ignoresSafeArea(edges: .vertical)
                    iPadPanel(session, format)
                }
            } else {
                VStack(spacing: 0) {
                    // Frame after `ignoresSafeArea`: the slot stays below the bar and the map grows up under it.
                    iPadMap(session, points: points)
                        .ignoresSafeArea(edges: .top)
                        .frame(height: size.height * 0.42)
                    iPadPanel(session, format)
                }
            }
        }
    }

    private func iPadMap(_ session: DriveSession, points: [RoutePoint]) -> some View {
        routeMap(points: points, large: true)
            .overlay(alignment: .bottomLeading) {
                // Above the Apple Maps logo, which also sits bottom-left.
                RouteEndpointChips(session: session)
                    .padding(.leading, 16)
                    .padding(.bottom, 40)
            }
    }

    private func iPadPanel(_ session: DriveSession, _ format: SessionFormat) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                iPadActions(session, format)
                iPadTitleBlock(session, format)
                IPadMetricsGrid(session: session, format: format)
                IPadLogQualityCard(session: session, format: format)
                SessionSectionsCard(sections: session.sections, large: true)
                SessionPlacesCard(places: session.viaPlaces, large: true)
                SessionNotesEditor(session: session, large: true)
            }
            .padding(.horizontal, 28)
            .padding(.top, 8)
            .padding(.bottom, 24)
        }
        .scrollBounceBehavior(.basedOnSize)
    }

    private func iPadActions(_ session: DriveSession, _ format: SessionFormat) -> some View {
        let shape = RoundedRectangle(cornerRadius: 12)
        return HStack(spacing: 10) {
            Spacer(minLength: 0)
            Button { showsReplayCover = true } label: {
                IPadActionLabel(title: "Replay", systemImage: "play.fill")
                    .foregroundStyle(Theme.background)
                    .background(Theme.accent, in: shape)
                    .cardHoverEffect(cornerRadius: 12)
            }
            .accessibilityIdentifier("replayButton")
            Button { showsExport = true } label: {
                IPadActionLabel(title: "Export", systemImage: "square.and.arrow.up")
                    .foregroundStyle(Theme.textPrimary)
                    .background(Theme.surface, in: shape)
                    .overlay(shape.strokeBorder(Theme.dividerStrong, lineWidth: 1.5))
                    .cardHoverEffect(cornerRadius: 12)
            }
            .accessibilityIdentifier("exportButton")
            Menu {
                Button {
                    beginRename(session, format)
                } label: {
                    Label("Rename", systemImage: "pencil")
                }
                Button {
                    Task { await model.archiver.archive(session) }
                } label: {
                    Label("Compress now", systemImage: "archivebox")
                }
                .disabled(session.archivedAt != nil || isRecording(session))
                Button(role: .destructive) {
                    isConfirmingDelete = true
                } label: {
                    Label("Delete", systemImage: "trash")
                }
                .disabled(isRecording(session))
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .frame(width: IPadMetrics.minTouch, height: IPadMetrics.minTouch)
                    .background(Theme.surface, in: shape)
                    .overlay(shape.strokeBorder(Theme.dividerStrong, lineWidth: 1.5))
                    .cardHoverEffect(cornerRadius: 12)
            }
            .accessibilityLabel("More")
            .accessibilityIdentifier("sessionMenu")
            // Anchored here: on iPad the dialog is a popover pointing at its source.
            .confirmationDialog("Delete this session?", isPresented: $isConfirmingDelete, titleVisibility: .visible) {
                deleteConfirmation(session)
            } message: {
                Text("The recorded data is removed from this device.")
            }
        }
        .buttonStyle(.plain)
    }

    private func iPadTitleBlock(_ session: DriveSession, _ format: SessionFormat) -> some View {
        let hz = Int(session.preset.motion.hz)
        let preset = hz > 0 ? "\(session.preset.displayName) \(hz) Hz" : session.preset.displayName
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                Button { beginRename(session, format) } label: {
                    HStack(spacing: 10) {
                        Text(verbatim: format.title(session))
                            .font(.system(size: 30, weight: .semibold))
                            .foregroundStyle(Theme.textPrimary)
                            .multilineTextAlignment(.leading)
                            .lineLimit(2)
                        Image(systemName: "pencil")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(Theme.textSecondary)
                    }
                    .frame(minHeight: IPadMetrics.minTouch)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityHint("Rename")
                .accessibilityIdentifier("renameButton")
                if session.state == .recovered {
                    Text(verbatim: "RECOVERED")
                        .font(.system(size: 13, weight: .semibold))
                        .tracking(1)
                        .foregroundStyle(Theme.accent)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.accent, lineWidth: 1))
                        .fixedSize()
                }
            }
            SessionPlacesLine(session: session, title: format.title(session), large: true)
            // "Tue, Sep 29 · 14:05 – 14:48 · Logger 50 Hz"
            Text(verbatim: "\(format.dateRangeLine(session)) · \(preset)")
                .font(.system(size: 15))
                .foregroundStyle(Theme.textTertiary)
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
                Button {
                    Task { await model.archiver.archive(session) }
                } label: {
                    Label("Compress now", systemImage: "archivebox")
                }
                .disabled(session.archivedAt != nil || isRecording(session))
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
            if let onDeleted { onDeleted() } else { dismiss() }
        } catch {
            deleteError = String(describing: error)
        }
    }

    // MARK: Map

    /// `large`: the iPad map (mock 13) — thicker line, bigger pins and marker labels.
    private func routeMap(points: [RoutePoint], large: Bool = false) -> some View {
        let coordinates = points.map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) }
        return Map(position: $camera) {
            if coordinates.count > 1 {
                // Dark casing under the amber line, like the mock.
                MapPolyline(coordinates: coordinates).stroke(large ? Theme.background : Theme.dividerStrong, lineWidth: large ? 11 : 7)
                MapPolyline(coordinates: coordinates).stroke(Theme.accent, lineWidth: large ? 5 : 4)
            }
            if let start = coordinates.first, coordinates.count > 1 {
                Annotation("", coordinate: start, anchor: .center) { RoutePin(ring: Theme.good, large: large) }
                    .annotationTitles(.hidden)
            }
            if let end = coordinates.last, coordinates.count > 1 {
                Annotation("", coordinate: end, anchor: .center) { RoutePin(ring: Theme.rec, large: large) }
                    .annotationTitles(.hidden)
            }
            ForEach(route.pins) { pin in
                Annotation(
                    "", coordinate: CLLocationCoordinate2D(latitude: pin.point.latitude, longitude: pin.point.longitude),
                    anchor: .leading
                ) {
                    MarkerPin(kind: pin.kind, elapsed: pin.elapsed, large: large)
                }
                .annotationTitles(.hidden)
            }
        }
        .mapStyle(.standard(elevation: .flat, emphasis: .muted, pointsOfInterest: .excludingAll))
        .overlay {
            if coordinates.isEmpty {
                Text("No route recorded")
                    .font(.system(size: large ? 15 : 13))
                    .foregroundStyle(large ? Theme.textSecondary : Theme.textMuted)
            }
        }
        .accessibilityLabel("Route map")
        .onChange(of: points.count) { _, _ in camera = Self.fit(points, large: large) }
        .onAppear { camera = Self.fit(points, large: large) }
    }

    private static func fit(_ points: [RoutePoint], large: Bool = false) -> MapCameraPosition {
        guard !points.isEmpty else { return .automatic }
        var rect = MKMapRect.null
        for point in points {
            let mapPoint = MKMapPoint(CLLocationCoordinate2D(latitude: point.latitude, longitude: point.longitude))
            rect = rect.union(MKMapRect(origin: mapPoint, size: MKMapSize(width: 0, height: 0)))
        }
        // Breathing room, and a minimum extent so a stationary log does not zoom to the pixel level.
        var padded = rect.insetBy(dx: -max(rect.width * 0.25, 1500), dy: -max(rect.height * 0.25, 1500))
        if large {
            // The iPad marker plates hang to the right of their pin; keep room so the map edge does not clip them.
            padded.size.width += padded.width * 0.35
        }
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
    var large = false

    var body: some View {
        Circle()
            .fill(Theme.background)
            .frame(width: large ? 22 : 14, height: large ? 22 : 14)
            .overlay(Circle().strokeBorder(ring, lineWidth: large ? 4 : 3))
    }
}

private struct MarkerPin: View {
    let kind: MarkerKind
    let elapsed: TimeInterval
    var large = false

    var body: some View {
        if large {
            // iPad: the label sits on a dark plate so it reads over any map tile (mock 13).
            HStack(spacing: 6) {
                Circle().fill(kind == .sync ? Theme.good : Theme.textPrimary).frame(width: 12, height: 12)
                Text(verbatim: label)
                    .font(.hudNumber(size: 14))
                    .foregroundStyle(kind == .sync ? Theme.good : Theme.textPrimary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(Theme.background.opacity(0.85), in: RoundedRectangle(cornerRadius: 8))
            }
        } else {
            HStack(spacing: 4) {
                Circle().fill(Theme.textPrimary).frame(width: 10, height: 10)
                Text(verbatim: label)
                    .font(.hudNumber(size: 10))
                    .foregroundStyle(Theme.textPrimary)
                    .shadow(color: Theme.background, radius: 2)
            }
        }
    }

    private var label: String { "\(kind == .sync ? "SYNC" : "MARK") \(elapsedText)" }

    private var elapsedText: String {
        let total = max(0, Int(elapsed.rounded()))
        return String(format: "%02d:%02d", total / 60, total % 60)
    }
}
