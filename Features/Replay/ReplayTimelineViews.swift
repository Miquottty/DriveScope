import Charts
import DriveDomain
import SwiftUI

/// Speed over the whole session (mock: 44 pt amber area + line), SYNC / MARK rules, and the playhead rule.
/// The chart itself never reads the playhead: only the overlay does, so playback redraws a 2 pt rule, not 600 points.
struct SpeedSparkline: View {
    let player: ReplayPlayer
    var style = Style.phone

    struct Style {
        var height: CGFloat = 44
        var lineWidth: CGFloat = 1.5
        var ruleDash: [CGFloat] = [2, 2]
        var playheadWidth: CGFloat = 2

        static let phone = Style()
        /// iPad timeline bar (mock artboard 14): 112 pt profile, 4-4 dashed marker rules, 2.5 pt playhead.
        static let pad = Style(height: 112, lineWidth: 2, ruleDash: [4, 4], playheadWidth: 2.5)
    }

    var body: some View {
        let timeline = player.timeline
        let profile = timeline?.speedProfile ?? []
        let duration = max(timeline?.duration ?? 0, 1)
        Chart {
            AreaPlot(profile, x: .value("Time", \.time), y: .value("Speed", \.kmh))
                .foregroundStyle(Theme.accent.opacity(0.14))
            LinePlot(profile, x: .value("Time", \.time), y: .value("Speed", \.kmh))
                .foregroundStyle(Theme.accent)
                .lineStyle(StrokeStyle(lineWidth: style.lineWidth, lineJoin: .round))
            ForEach(timeline?.markers ?? []) { marker in
                RuleMark(x: .value("Marker", marker.elapsed))
                    .foregroundStyle(marker.kind == .sync ? Theme.good : Theme.textPrimary)
                    .lineStyle(StrokeStyle(lineWidth: 1.5, dash: style.ruleDash))
            }
        }
        .chartXScale(domain: 0...duration, range: .plotDimension(padding: 0))
        // Headroom above the peak, like the mock's profile.
        .chartYScale(domain: 0...max((timeline?.maxKmh ?? 0) * 1.15, 10), range: .plotDimension(padding: 0))
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .chartLegend(.hidden)
        .chartOverlay { proxy in
            GeometryReader { geometry in
                let plot = proxy.plotFrame.map { geometry[$0] } ?? CGRect(origin: .zero, size: geometry.size)
                Playhead(player: player, plot: plot, width: style.playheadWidth)
            }
        }
        .frame(height: style.height)
        .accessibilityElement()
        .accessibilityLabel(Text("Speed profile"))
    }
}

/// The playhead rule, plus tap / drag anywhere on the chart to scrub.
private struct Playhead: View {
    let player: ReplayPlayer
    let plot: CGRect
    let width: CGFloat

    var body: some View {
        let duration = player.duration
        let fraction = duration > 0 ? player.time / duration : 0
        ZStack(alignment: .topLeading) {
            Color.clear
                .contentShape(Rectangle())
                .gesture(scrubGesture(duration: duration))
            if player.timeline != nil {
                Rectangle()
                    .fill(Theme.textPrimary)
                    .frame(width: width, height: plot.height)
                    .offset(x: plot.minX + plot.width * fraction - width / 2, y: plot.minY)
                    .allowsHitTesting(false)
            }
        }
    }

    private func scrubGesture(duration: TimeInterval) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                guard duration > 0, plot.width > 0 else { return }
                player.scrub(to: (value.location.x - plot.minX) / plot.width * duration)
            }
            .onEnded { _ in player.endScrub() }
    }
}

/// Mock scrubber: 4 pt track, amber fill to the 24 pt thumb, 28 pt tall (iPad: 6 / 28). Accessibility sees a real
/// slider.
struct ReplayScrubber: View {
    let player: ReplayPlayer
    var style = Style.phone

    struct Style {
        var trackHeight: CGFloat = 4
        var trackColor = Theme.dividerStrong
        var thumbSize: CGFloat = 24

        static let phone = Style()
        /// iPad timeline bar (mock artboard 14): 6 pt track, 28 pt thumb.
        static let pad = Style(trackHeight: 6, trackColor: Theme.divider, thumbSize: 28)
    }

    var body: some View {
        let duration = player.duration
        let fraction = duration > 0 ? min(max(player.time / duration, 0), 1) : 0
        GeometryReader { geometry in
            let width = geometry.size.width
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(style.trackColor)
                    .frame(height: style.trackHeight)
                Capsule()
                    .fill(Theme.accent)
                    .frame(width: width * fraction, height: style.trackHeight)
                Circle()
                    .fill(Theme.textPrimary)
                    .frame(width: style.thumbSize, height: style.thumbSize)
                    .shadow(color: Theme.hudBackground.opacity(0.5), radius: 4, y: 2)
                    .offset(x: width * fraction - style.thumbSize / 2)
            }
            .frame(width: width, height: geometry.size.height)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        guard duration > 0, width > 0 else { return }
                        player.scrub(to: value.location.x / width * duration)
                    }
                    .onEnded { _ in player.endScrub() }
            )
        }
        .frame(height: 28)
        .disabled(!player.canPlay)
        .accessibilityRepresentation {
            Slider(
                value: Binding(get: { player.time }, set: { player.seek(to: $0) }),
                in: 0...max(duration, 1)
            ) {
                Text("Timeline")
            }
            .accessibilityValue(Text(verbatim: ReplayFormat.playhead(player.time, longForm: ReplayFormat.isLongForm(duration: duration))))
            .accessibilityIdentifier("replayScrubber")
        }
    }
}
