import DriveDomain
import DriveReplay
import DriveStorage
import SwiftUI
import UIKit

/// iPad Timeline Replay (mock artboard 14): the map fills the screen, a readout card floats under the FOLLOW / 3D
/// pills (a row across the top in portrait), and the timeline bar runs along the bottom. Keyboard: Space play /
/// pause, ← / → ∓5 s, ⇧← / ⇧→ ∓30 s, [ / ] previous / next marker (`KeyCommandResponder`: plain arrows belong to
/// the focus system otherwise).
///
/// Only the window's aspect (a binary choice from the proposed size) steers the layout; nothing measured inside is
/// fed back, which is what once made the pushed Replay re-render in a loop.
struct ReplayIPadLayout: View {
    let player: ReplayPlayer
    let session: DriveSession
    let onBack: () -> Void

    @Environment(AppLanguage.self) private var appLanguage

    /// Mock offsets under the safe area: pills 8 pt down and 44 pt tall, then a 16 pt gap.
    private static let readoutTop: CGFloat = 8 + 44 + 16
    private static let margin: CGFloat = 24

    var body: some View {
        GeometryReader { proxy in
            let landscape = proxy.size.width > proxy.size.height
            VStack(spacing: 0) {
                ReplayMap(
                    player: player, previewRoute: session.routePreview,
                    style: .pad(title: title, subtitle: subtitle), onBack: onBack
                )
                .overlay(alignment: .topTrailing) {
                    Group {
                        if landscape {
                            ReplayReadoutCard(player: player)
                        } else {
                            ReplayReadoutRow(player: player, arrangement: .init(windowWidth: proxy.size.width))
                        }
                    }
                    .padding(.top, Self.readoutTop)
                    .padding(.horizontal, Self.margin)
                }
                ReplayTimelineBar(player: player, landscape: landscape)
            }
        }
        .background(alignment: .topLeading) {
            KeyCommandResponder(commands: keyCommands)
                .frame(width: 1, height: 1)
                .accessibilityHidden(true)
        }
    }

    /// Space, ← / →, ⇧← / ⇧→, [ / ] (mock artboard 14's hint line).
    private var keyCommands: [KeyCommandResponder.Command] {
        let player = player
        let language = appLanguage
        func command(
            _ input: String, _ modifiers: UIKeyModifierFlags = [], _ title: String.LocalizationValue,
            _ action: @escaping (ReplayPlayer) -> Void
        ) -> KeyCommandResponder.Command {
            KeyCommandResponder.Command(input: input, modifiers: modifiers, title: language.string(title)) {
                guard player.canPlay else { return }
                action(player)
            }
        }
        return [
            command(" ", [], "Play / Pause") { $0.togglePlay() },
            command(UIKeyCommand.inputLeftArrow, [], "Back 5 seconds") { $0.skip(by: -5) },
            command(UIKeyCommand.inputRightArrow, [], "Forward 5 seconds") { $0.skip(by: 5) },
            command(UIKeyCommand.inputLeftArrow, .shift, "Back 30 seconds") { $0.skip(by: -30) },
            command(UIKeyCommand.inputRightArrow, .shift, "Forward 30 seconds") { $0.skip(by: 30) },
            command("[", [], "Previous marker") { $0.stepBack() },
            command("]", [], "Next marker") { $0.stepForward() },
        ]
    }

    private var title: String {
        SessionFormat(language: appLanguage).title(session)
    }

    /// "Sep 29 · Logger 50 Hz"
    private var subtitle: String {
        let hz = session.preset.motion.hz
        let rate = hz > 0 ? "\(Int(hz)) Hz" : "GPS 1 Hz"
        let date = SessionFormat(language: appLanguage).shortDate(session)
        return "\(date) · \(HUDFormat.presetName(session.preset)) \(rate)"
    }
}

// MARK: - Readout

/// Frame values shared by the card and the portrait row. Telemetry labels stay English (PLAN §13).
private struct ReplayReadoutValues {
    let player: ReplayPlayer

    private static let style = TelemetryValue.Style(
        valueSize: 30, unitSize: 14, unitGap: 3, labelSize: 13, spacing: 0, labelWeight: .semibold,
        unitColor: Theme.textTertiary)

    private var frame: ReplayTelemetryFrame? {
        player.timeline?.hasFixes == true ? player.frame : nil
    }

    /// Without calibrated motion only lateral G can be estimated (from GPS course change).
    private var hasMotionG: Bool { player.timeline?.hasMotionG ?? false }

    var speed: some View {
        let text = HUDFormat.speedKmh(frame?.speed)
        return HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(verbatim: text)
                .font(.hudNumber(size: 96, weight: .medium))
                .tracking(96 * -0.04)
                .foregroundStyle(Theme.textPrimary)
                // Mock line-height 0.9 (see the HUD's speed).
                .padding(.top, -96 * 0.09)
                .padding(.bottom, -96 * 0.17)
            Text(verbatim: "km/h")
                .font(.system(size: 20))
                .foregroundStyle(Theme.textTertiary)
        }
        .lineLimit(1)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: "\(text) km/h"))
    }

    var altitude: some View {
        value("ALT", frame.map { HUDFormat.altitude($0.altitude) }, unit: "m")
    }

    var course: some View {
        value("CRS", frame.map { HUDFormat.course($0.course) + "°" })
    }

    var lateral: some View {
        value("LAT G", frame.map { HUDFormat.signedG($0.lateralG) }, color: Theme.accent)
    }

    var longitudinal: some View {
        value("LONG G", hasMotionG ? frame.map { HUDFormat.signedG($0.longitudinalG) } : nil)
    }

    var meter: some View {
        GMeterView(
            lateralG: frame?.lateralG ?? 0, longitudinalG: hasMotionG ? frame?.longitudinalG ?? 0 : 0,
            style: .pad(dotRadius: 8, labelSize: nil))
            .frame(width: ReplayReadoutRow.meterSize, height: ReplayReadoutRow.meterSize)
    }

    private func value(
        _ label: String, _ text: String?, unit: String? = nil, color: Color = Theme.textPrimary
    ) -> some View {
        TelemetryValue(
            label: label, value: text ?? HUDFormat.placeholder, unit: text == nil ? nil : unit, style: Self.style,
            valueColor: text == nil ? Theme.textSecondary : color, alignment: .leading)
    }
}

/// Landscape: 300 pt card with speed, a 2 × 2 grid and the G meter.
private struct ReplayReadoutCard: View {
    let player: ReplayPlayer

    var body: some View {
        let values = ReplayReadoutValues(player: player)
        VStack(alignment: .leading, spacing: 14) {
            values.speed
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top, spacing: 12) {
                    values.altitude.frame(maxWidth: .infinity, alignment: .leading)
                    values.course.frame(maxWidth: .infinity, alignment: .leading)
                }
                HStack(alignment: .top, spacing: 12) {
                    values.lateral.frame(maxWidth: .infinity, alignment: .leading)
                    values.longitudinal.frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            values.meter
                .frame(maxWidth: .infinity)
        }
        .padding(20)
        .frame(width: 300)
        .readoutPanel()
    }
}

/// Portrait: the same readouts in one row across the top — four values abreast on a full-screen 13" iPad, a 2 × 2
/// grid on an 11", and without the meter in narrower windows.
private struct ReplayReadoutRow: View {
    enum Arrangement {
        case fourAcross, grid, gridWithoutMeter

        /// Chosen from the window width alone (speed and columns have fixed widths), so playback never reflows it.
        init(windowWidth: CGFloat) {
            // Card padding and screen margins.
            let chrome: CGFloat = 2 * 20 + 2 * 24
            let grid = 2 * columnWidth + 12
            if windowWidth >= chrome + speedWidth + 4 * columnWidth + 5 * spacing + meterSize {
                self = .fourAcross
            } else if windowWidth >= chrome + speedWidth + grid + 2 * spacing + meterSize {
                self = .grid
            } else {
                self = .gridWithoutMeter
            }
        }
    }

    let player: ReplayPlayer
    let arrangement: Arrangement

    /// Speed wide enough for "188", so crossing 100 km/h never reflows the row.
    private static let speedWidth: CGFloat = 220
    private static let columnWidth: CGFloat = 110
    private static let spacing: CGFloat = 24
    fileprivate static let meterSize: CGFloat = 150

    var body: some View {
        let values = ReplayReadoutValues(player: player)
        HStack(alignment: .center, spacing: Self.spacing) {
            values.speed
                .frame(width: Self.speedWidth, alignment: .leading)
            Group {
                if arrangement == .fourAcross {
                    HStack(alignment: .top, spacing: Self.spacing) {
                        column(values.altitude)
                        column(values.course)
                        column(values.lateral)
                        column(values.longitudinal)
                    }
                } else {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack(alignment: .top, spacing: 12) {
                            column(values.altitude)
                            column(values.course)
                        }
                        HStack(alignment: .top, spacing: 12) {
                            column(values.lateral)
                            column(values.longitudinal)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if arrangement != .gridWithoutMeter {
                values.meter
            }
        }
        .padding(20)
        .readoutPanel()
    }

    private func column(_ content: some View) -> some View {
        content.frame(width: Self.columnWidth, alignment: .leading)
    }
}

private extension View {
    /// Mock: solid `#0B0D10`, 1 pt `#1F252C` border, radius 20.
    func readoutPanel() -> some View {
        let shape = RoundedRectangle(cornerRadius: 20)
        return background(Theme.background, in: shape)
            .overlay(shape.strokeBorder(Theme.divider, lineWidth: 1))
    }
}

// MARK: - Timeline bar

/// Speed profile (112 pt), scrubber, then marker chips · clock · transport, and the keyboard hint. Portrait is too
/// narrow for three chips beside the centered clock, so the chips get their own row there.
private struct ReplayTimelineBar: View {
    let player: ReplayPlayer
    let landscape: Bool

    var body: some View {
        VStack(spacing: 10) {
            SpeedSparkline(player: player, style: .pad)
            ReplayScrubber(player: player, style: .pad)
            ReplaySectionStrip(player: player)
            if landscape {
                // The chips and the transport share the sides equally, so the clock stays centered.
                HStack(spacing: 16) {
                    ReplayMarkerChips(player: player)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    ReplayBarClock(player: player)
                    ReplayTransport(player: player)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
            } else {
                if player.timeline?.markers.isEmpty == false {
                    ReplayMarkerChips(player: player)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                HStack(spacing: 16) {
                    ReplayBarClock(player: player)
                    Spacer(minLength: 0)
                    ReplayTransport(player: player)
                }
            }
            Text("Space play / pause · ← → 5 s · ⇧ ← → 30 s · [ ] previous / next marker")
                .font(.system(size: 13))
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .frame(maxWidth: .infinity)
        }
        .padding(.top, 16)
        .padding(.horizontal, 28)
        .padding(.bottom, 4)
        .background(Theme.background.ignoresSafeArea(edges: .bottom))
        .overlay(alignment: .top) {
            Rectangle().fill(Theme.divider).frame(height: 1)
        }
    }
}

/// "18:24.5 / 42:31"
private struct ReplayBarClock: View {
    let player: ReplayPlayer

    var body: some View {
        let longForm = ReplayFormat.isLongForm(duration: player.duration)
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(verbatim: ReplayFormat.playhead(player.time, longForm: longForm))
                .font(.hudNumber(size: 34, weight: .medium))
                .foregroundStyle(Theme.textPrimary)
            Text(verbatim: "/ " + ReplayFormat.clock(player.duration, longForm: longForm))
                .font(.hudNumber(size: 18))
                .foregroundStyle(Theme.textTertiary)
        }
        .lineLimit(1)
        .fixedSize()
        .accessibilityHidden(true)
    }
}

private struct ReplayMarkerChips: View {
    let player: ReplayPlayer

    /// More chips past the trailing edge: fade it so the cut-off chip reads as scrollable.
    @State private var moreTrailing = false

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 10) {
                ForEach(player.timeline?.markers ?? []) { marker in
                    let isSync = marker.kind == .sync
                    Button {
                        player.seek(to: marker.elapsed)
                    } label: {
                        Text(verbatim: ReplayFormat.markerChip(kind: marker.kind, elapsed: marker.elapsed))
                            .font(.hudNumber(size: 15))
                            .foregroundStyle(isSync ? Theme.good : Theme.textPrimary)
                            .padding(.horizontal, 14)
                            .frame(height: 44)
                            .background(isSync ? Theme.syncChipFill : Theme.replayControl,
                                        in: RoundedRectangle(cornerRadius: 10))
                            // 44 pt visible, 52 pt to the finger (the scroll view's 4 pt insets make room).
                            .contentShape(Rectangle().inset(by: -4))
                    }
                    .buttonStyle(HUDButtonStyle())
                    .accessibilityHint(Text("Jumps to this marker"))
                }
            }
            .padding(.vertical, 4)
        }
        .scrollIndicators(.hidden)
        .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
        // Only the mask depends on the scroll geometry, never the layout.
        .onScrollGeometryChange(for: Bool.self) { geometry in
            geometry.contentOffset.x + geometry.containerSize.width < geometry.contentSize.width - 1
        } action: { _, more in
            moreTrailing = more
        }
        .mask {
            // Only the alpha matters.
            HStack(spacing: 0) {
                Rectangle()
                LinearGradient(colors: [Theme.background, Theme.background.opacity(moreTrailing ? 0 : 1)],
                               startPoint: .leading, endPoint: .trailing)
                    .frame(width: 40)
            }
        }
    }
}

/// ⏮ (56) · play (72, amber) · rate (56).
private struct ReplayTransport: View {
    let player: ReplayPlayer

    var body: some View {
        HStack(spacing: 12) {
            Button { player.stepBack() } label: {
                Image(systemName: "backward.end.fill")
                    .font(.system(size: 22))
                    .foregroundStyle(Theme.textPrimary)
                    .frame(width: 56, height: 56)
                    .background(Theme.replayControl, in: Circle())
            }
            .accessibilityLabel(Text("Previous mark"))
            Button { player.togglePlay() } label: {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 28))
                    .foregroundStyle(Theme.background)
                    .frame(width: 72, height: 72)
                    .background(Theme.accent, in: Circle())
                    .contentTransition(.symbolEffect(.replace))
            }
            .accessibilityLabel(player.isPlaying ? Text("Pause") : Text("Play"))
            .accessibilityIdentifier("replayPlayButton")
            Button { player.cycleRate() } label: {
                Text(verbatim: player.rate.label)
                    .font(.hudNumber(size: 17, weight: .medium))
                    .foregroundStyle(Theme.textPrimary)
                    .frame(width: 56, height: 56)
                    .background(Theme.replayControl, in: Circle())
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
