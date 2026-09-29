import DriveDomain
import DriveReplay
import DriveStorage
import Foundation
import Observation
import OSLog

/// Playback state of the Replay screen. Frames are interpolated on the main actor: a frame is a few binary searches
/// over the mapped streams (2-hour 100 Hz log: ≈ 4 µs optimized, ≈ 90 µs in a Debug build), far below the 2 ms
/// budget, so playback and scrubbing never wait on a background hop.
@Observable
final class ReplayPlayer {
    enum Rate: Int, CaseIterable {
        case x1 = 1, x2 = 2, x4 = 4, x8 = 8, x16 = 16

        var next: Rate {
            let all = Rate.allCases
            return all[(all.firstIndex(of: self)! + 1) % all.count]
        }

        var label: String { "\(rawValue)×" }
    }

    enum LoadState {
        case loading, ready, failed
    }

    nonisolated static let log = Logger(subsystem: "com.miquottty.DriveScope", category: "Replay")
    /// ~30 fps. The playhead advances by measured wall time, so a late tick never drifts the replay.
    private static let tick = Duration.milliseconds(33)
    /// Longest step a single tick may take: after a suspension (background, debugger) playback resumes where it
    /// was instead of jumping ahead.
    private static let maxStep = Duration.milliseconds(250)
    /// Below this speed (m/s) the course is held (see `seek`).
    private static let headingHoldSpeed = 1.0

    private(set) var loadState = LoadState.loading
    private(set) var timeline: ReplayTimeline?
    /// Session elapsed seconds of the playhead.
    private(set) var time: TimeInterval = 0
    /// Frame at `time`; nil until loaded.
    private(set) var frame: ReplayTelemetryFrame?
    private(set) var isPlaying = false
    var rate = Rate.x1

    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored private var isScrubbing = false
    @ObservationIgnored private var resumeAfterScrub = false

    var duration: TimeInterval { timeline?.duration ?? 0 }
    var canPlay: Bool { duration > 0 }

    func load(
        files: SessionFiles, calibration: MountCalibration?, markers: [ReplayTimeline.MarkerInput],
        fallbackDuration: TimeInterval
    ) async {
        let clock = ContinuousClock()
        let start = clock.now
        do {
            let timeline = try await ReplayTimeline.load(
                files: files, calibration: calibration, markers: markers, fallbackDuration: fallbackDuration
            )
            self.timeline = timeline
            loadState = .ready
            seek(to: 0)
            Self.log.debug("""
                Replay loaded in \(clock.now - start, privacy: .public): \(timeline.duration, format: .fixed(precision: 0))s, \
                route \(timeline.route.count) pts
                """)
        } catch {
            loadState = .failed
            Self.log.error("Replay load failed: \(error, privacy: .public)")
        }
    }

    func togglePlay() {
        isPlaying ? pause() : play()
    }

    func play() {
        guard canPlay, !isPlaying else { return }
        isScrubbing = false
        resumeAfterScrub = false
        if time >= duration { seek(to: 0) }
        isPlaying = true
        loop = Task { [weak self] in
            let clock = ContinuousClock()
            var last = clock.now
            while !Task.isCancelled {
                try? await clock.sleep(for: Self.tick, tolerance: .milliseconds(4))
                let now = clock.now
                guard let self, !Task.isCancelled else { return }
                self.advance(by: min(now - last, Self.maxStep))
                last = now
            }
        }
    }

    /// Explicit pause (button, background). Also drops a pending resume: a drag cancelled by the system never
    /// delivers `onEnded`, and must not restart playback on the next scrub.
    func pause() {
        stopLoop()
        isScrubbing = false
        resumeAfterScrub = false
    }

    func seek(to target: TimeInterval) {
        guard let timeline else { return }
        time = min(max(target, 0), timeline.duration)
        var next = timeline.interpolator.frame(at: time)
        // Core Location reports no course when stopped (-1, which interpolates to ~359°): keep the last heading so the
        // arrow, CRS and the 3D chase camera don't snap north at every stop.
        if next.speed < Self.headingHoldSpeed, let held = frame?.course ?? timeline.initialCourse {
            next.course = held
            next.yaw = held
        }
        frame = next
    }

    /// Drag on the scrubber or the chart: playback holds while the finger is down and resumes on release.
    func scrub(to target: TimeInterval) {
        if !isScrubbing {
            isScrubbing = true
            resumeAfterScrub = isPlaying
            stopLoop()
        }
        seek(to: target)
    }

    func endScrub() {
        guard isScrubbing else { return }
        isScrubbing = false
        if resumeAfterScrub, time < duration { play() }
    }

    func cycleRate() {
        rate = rate.next
    }

    /// The marker before the playhead (with a 1 s grace so a repeated tap keeps stepping back), else the start.
    func stepBack() {
        let previous = timeline?.markers.last { $0.elapsed < time - 1 }
        seek(to: previous?.elapsed ?? 0)
    }

    private func advance(by step: Duration) {
        let seconds = Double(step.components.seconds) + Double(step.components.attoseconds) / 1e18
        let next = time + seconds * Double(rate.rawValue)
        if next >= duration {
            seek(to: duration)
            stopLoop()
        } else {
            seek(to: next)
        }
    }

    private func stopLoop() {
        isPlaying = false
        loop?.cancel()
        loop = nil
    }
}
