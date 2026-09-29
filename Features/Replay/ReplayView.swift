import DriveDomain
import DriveRecording
import DriveReplay
import DriveStorage
import SwiftData
import SwiftUI
import UIKit

/// Navigation destination for Replay. The stack re-evaluates destinations whenever its toolbar preferences change,
/// and `ReplayView` (with `@Query` / `@Environment`) never compares equal — so without this equatable boundary the
/// pushed view re-rendered in a tight loop (100 % CPU on the main thread).
struct ReplayDestination: View, Equatable {
    let sessionID: UUID

    var body: some View {
        ReplayView(sessionID: sessionID)
    }
}

/// Timeline Replay (PLAN §11 row 5, mock artboard 5): map following the car, HUD readout, speed sparkline,
/// scrubber, marker jumps and playback speed. Pushed from Session Detail (iPhone); full screen on iPad (artboard 14).
struct ReplayView: View {
    let sessionID: UUID

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Query private var sessions: [DriveSession]
    @State private var player = ReplayPlayer()

    /// Mock map height, measured from the top of the screen (it runs under the status bar).
    private static let mapHeight: CGFloat = 380
    /// The map extends under the status bar (`ReplayMap` ignores the top safe area); Dynamic Island iPhones ≈ 62 pt.
    private static let statusBarAllowance: CGFloat = 62
    /// Mock width of the lower panel; the panel's width beside the map in landscape.
    private static let panelWidth: CGFloat = 390

    init(sessionID: UUID) {
        self.sessionID = sessionID
        _sessions = Query(filter: #Predicate<DriveSession> { $0.id == sessionID })
    }

    var body: some View {
        Group {
            if let session = sessions.first {
                content(session)
            } else {
                ContentUnavailableView("Session not found", systemImage: "questionmark.folder")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.background)
        .toolbar(.hidden, for: .navigationBar)
        .toolbarVisibility(.hidden, for: .tabBar)
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { player.pause() }
        }
        // Keep the screen on while a replay runs, like a video player.
        .onChange(of: player.isPlaying) { _, playing in UIApplication.shared.isIdleTimerDisabled = playing }
        .onDisappear {
            player.pause()
            UIApplication.shared.isIdleTimerDisabled = false
        }
    }

    private func content(_ session: DriveSession) -> some View {
        Group {
            // Regular × regular is an iPad-sized window (artboard 14); a Max iPhone in landscape (regular × compact)
            // stays on the phone layout.
            if horizontalSizeClass == .regular, verticalSizeClass == .regular {
                ReplayIPadLayout(player: player, session: session) { dismiss() }
            } else {
                phoneContent(session)
            }
        }
        .task(id: session.id) { await load(session) }
    }

    /// Portrait is the mock: map on top, panel below. Landscape puts the panel beside the map. One `AnyLayout`
    /// keeps the map's identity (FOLLOW / 3D, camera) across rotation.
    private func phoneContent(_ session: DriveSession) -> some View {
        let landscape = verticalSizeClass == .compact
        let layout = landscape ? AnyLayout(HStackLayout(alignment: .top, spacing: 0)) : AnyLayout(VStackLayout(spacing: 0))
        return layout {
            // Fixed frame: measuring the safe-area inset and feeding it back into the layout looped during the push.
            ReplayMap(player: player, previewRoute: session.routePreview) { dismiss() }
                .frame(height: landscape ? nil : Self.mapHeight - Self.statusBarAllowance)
                .frame(maxHeight: landscape ? .infinity : nil)
            VStack(spacing: 14) {
                ReplayReadout(player: player)
                VStack(spacing: 6) {
                    SpeedSparkline(player: player)
                    ReplayScrubber(player: player)
                    ReplayClockRow(player: player)
                }
                ReplaySectionStrip(player: player)
                ReplayControls(player: player)
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)
            .frame(width: landscape ? Self.panelWidth : nil)
            .frame(maxHeight: .infinity, alignment: .top)
        }
    }

    private func load(_ session: DriveSession) async {
        guard player.loadState == .loading else { return }
        // Sessions recorded before V1.1 (or by an older detector) get their sections first.
        await model.finalizer.ensureSections(session)
        let markers = session.sortedMarkers.map { ReplayTimeline.MarkerInput(id: $0.id, kind: $0.kind, elapsed: $0.elapsed) }
        await player.load(
            files: SessionFiles(root: model.filesRoot, sessionID: session.id),
            calibration: session.calibration, markers: markers, sections: session.sections,
            fallbackDuration: session.duration
        )
    }
}

// MARK: - Readout

/// Speed (64 pt) and the ALT / CRS / LAT G / LONG G grid. Telemetry labels stay English (PLAN §13).
private struct ReplayReadout: View {
    let player: ReplayPlayer

    private static let valueStyle = TelemetryValue.Style(valueSize: 17, unitSize: 17, labelSize: 10, spacing: 1)
    private static let columnWidth: CGFloat = 64

    var body: some View {
        let frame = player.timeline?.hasFixes == true ? player.frame : nil
        let hasMotionG = player.timeline?.hasMotionG ?? false
        HStack(alignment: .bottom) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(verbatim: HUDFormat.speedKmh(frame?.speed))
                    .font(.hudNumber(size: 64, weight: .medium))
                    .tracking(-1.9)
                    .foregroundStyle(Theme.textPrimary)
                Text(verbatim: "km/h")
                    .font(.system(size: 14))
                    .foregroundStyle(Theme.textSecondary)
            }
            .lineLimit(1)
            .accessibilityElement(children: .combine)
            Spacer(minLength: 12)
            Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 6) {
                GridRow {
                    value("ALT", frame.map { HUDFormat.altitude($0.altitude) + " m" })
                    value("CRS", frame.map { HUDFormat.course($0.course) + "°" })
                }
                GridRow {
                    value("LAT G", frame.map { HUDFormat.signedG($0.lateralG) }, color: Theme.accent)
                    // Without calibrated motion only lateral G can be estimated (from GPS course change).
                    value("LONG G", hasMotionG ? frame.map { HUDFormat.signedG($0.longitudinalG) } : nil)
                }
            }
        }
    }

    private func value(_ label: String, _ text: String?, color: Color = Theme.textPrimary) -> some View {
        TelemetryValue(
            label: label, value: text ?? HUDFormat.placeholder, style: Self.valueStyle,
            valueColor: text == nil ? Theme.textMuted : color, alignment: .leading
        )
        .frame(width: Self.columnWidth, alignment: .leading)
    }
}

// MARK: - Clock row

/// "00:00 · 18:24.5 · 42:31" under the scrubber.
private struct ReplayClockRow: View {
    let player: ReplayPlayer

    var body: some View {
        let duration = player.duration
        let longForm = ReplayFormat.isLongForm(duration: duration)
        HStack(alignment: .firstTextBaseline) {
            Text(verbatim: ReplayFormat.clock(0, longForm: longForm))
                .font(.hudNumber(size: 12))
                .foregroundStyle(Theme.textSecondary)
            Spacer()
            Text(verbatim: ReplayFormat.playhead(player.time, longForm: longForm))
                .font(.hudNumber(size: 16, weight: .medium))
                .foregroundStyle(Theme.textPrimary)
            Spacer()
            Text(verbatim: ReplayFormat.clock(duration, longForm: longForm))
                .font(.hudNumber(size: 12))
                .foregroundStyle(Theme.textSecondary)
        }
        .accessibilityHidden(true)
    }
}

// MARK: - Controls

/// Marker chips (left) and step back / play / rate (right).
private struct ReplayControls: View {
    let player: ReplayPlayer

    var body: some View {
        HStack(spacing: 10) {
            ScrollView(.horizontal) {
                HStack(spacing: 6) {
                    ForEach(player.timeline?.markers ?? []) { marker in
                        MarkerChip(marker: marker) { player.seek(to: marker.elapsed) }
                    }
                }
            }
            .scrollIndicators(.hidden)
            .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
            HStack(spacing: 10) {
                Button { player.stepBack() } label: {
                    Image(systemName: "backward.end.fill")
                        .font(.system(size: 16))
                        .foregroundStyle(Theme.textPrimary)
                        .frame(width: 44, height: 44)
                        .background(Theme.surface, in: Circle())
                }
                .accessibilityLabel(Text("Previous mark"))
                Button { player.togglePlay() } label: {
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 20))
                        .foregroundStyle(Theme.background)
                        .frame(width: 56, height: 56)
                        .background(Theme.accent, in: Circle())
                        .contentTransition(.symbolEffect(.replace))
                }
                .accessibilityLabel(player.isPlaying ? Text("Pause") : Text("Play"))
                .accessibilityIdentifier("replayPlayButton")
                Button { player.cycleRate() } label: {
                    Text(verbatim: player.rate.label)
                        .font(.hudNumber(size: 13, weight: .medium))
                        .foregroundStyle(Theme.textPrimary)
                        .padding(.horizontal, 10)
                        .frame(minWidth: 44, minHeight: 44)
                        .background(Theme.surface, in: Capsule())
                }
                .accessibilityLabel(Text("Playback speed"))
                .accessibilityValue(Text(verbatim: player.rate.label))
                .accessibilityIdentifier("replayRateButton")
            }
            .buttonStyle(HUDButtonStyle())
            .disabled(!player.canPlay)
            .opacity(player.canPlay ? 1 : 0.4)
        }
    }
}

private struct MarkerChip: View {
    let marker: ReplayTimeline.Marker
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(verbatim: ReplayFormat.markerChip(kind: marker.kind, elapsed: marker.elapsed))
                .font(.hudNumber(size: 11))
                .foregroundStyle(marker.kind == .sync ? Theme.good : Theme.textPrimary)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: 6))
                .contentShape(Rectangle().inset(by: -8))
        }
        .buttonStyle(HUDButtonStyle())
        .accessibilityHint(Text("Jumps to this marker"))
    }
}
