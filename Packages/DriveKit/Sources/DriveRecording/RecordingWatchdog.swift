import DriveDomain
import Foundation

/// Stage-1 watchdog (PLAN §9.3): escalates while a stream is silent, all inside the running process.
/// Stage 2 (the dead-man notification that fires even if the process is gone) is driven by `deadmanDue`.
public struct RecordingWatchdog: Sendable {
    public struct Policy: Sendable, Equatable {
        public var gpsSearching: TimeInterval = 15
        public var motionStalled: TimeInterval = 10
        /// Live Activity alert, measured from the last sample.
        public var alert: TimeInterval = 60
        /// Local notification, measured from the last sample.
        public var notify: TimeInterval = 120
        /// Dead-man notification delay, re-armed every `deadmanRefresh`.
        public var deadman: TimeInterval = 180
        public var deadmanRefresh: TimeInterval = 15

        public init() {}

        /// Debug: every threshold divided by `factor` so the simulator can exercise the stages quickly.
        public func accelerated(by factor: Double) -> Policy {
            var p = self
            p.gpsSearching /= factor
            p.motionStalled /= factor
            p.alert /= factor
            p.notify /= factor
            p.deadman /= factor
            p.deadmanRefresh /= factor
            return p
        }
    }

    public enum Stream: String, Sendable {
        case gps
        case motion
    }

    public enum Stage: Int, Sendable, Comparable {
        case ok
        /// HUD / Live Activity show "searching" (no notification).
        case degraded
        /// Live Activity updated with an alert configuration.
        case alerted
        /// Local notification sent.
        case notified

        public static func < (a: Stage, b: Stage) -> Bool { a.rawValue < b.rawValue }
    }

    public enum Action: Sendable, Equatable {
        /// A stream moved to a worse stage; `silence` is seconds since its last sample.
        case escalated(Stream, Stage, silence: TimeInterval)
        /// A stream delivered again after being degraded; `gap` is the longest silence observed (≈ evaluation interval).
        case recovered(Stream, gap: TimeInterval)
        /// Push the dead-man notification out by `policy.deadman` again.
        case rearmDeadman
    }

    public let policy: Policy
    public private(set) var gpsStage: Stage = .ok
    public private(set) var motionStage: Stage = .ok
    private var gpsPeakSilence: TimeInterval = 0
    private var motionPeakSilence: TimeInterval = 0
    private var lastDeadmanArm: TimeInterval?

    public init(policy: Policy = Policy()) {
        self.policy = policy
    }

    /// Evaluates silence at `now` (uptime). `lastMotion` is nil when the preset records no motion.
    public mutating func evaluate(now: TimeInterval, lastLocation: TimeInterval, lastMotion: TimeInterval?) -> [Action] {
        var actions: [Action] = []
        step(.gps, stage: &gpsStage, peak: &gpsPeakSilence, silence: now - lastLocation, degradedAfter: policy.gpsSearching, into: &actions)
        if let lastMotion {
            step(.motion, stage: &motionStage, peak: &motionPeakSilence, silence: now - lastMotion, degradedAfter: policy.motionStalled, into: &actions)
        }
        // Evaluation only happens while the process runs, so re-arming proves liveness: once the process is
        // suspended or killed, the last armed notification fires on its own (a tunnel alone is stage 1's job).
        if lastDeadmanArm.map({ now - $0 >= policy.deadmanRefresh }) ?? true {
            lastDeadmanArm = now
            actions.append(.rearmDeadman)
        }
        return actions
    }

    private func step(
        _ stream: Stream, stage: inout Stage, peak: inout TimeInterval, silence: TimeInterval,
        degradedAfter: TimeInterval, into actions: inout [Action]
    ) {
        let target: Stage = if silence > policy.notify {
            .notified
        } else if silence > policy.alert {
            .alerted
        } else if silence > degradedAfter {
            .degraded
        } else {
            .ok
        }
        if target > stage {
            // Report every stage crossed, so a long suspension still yields the notification.
            for s in [Stage.degraded, .alerted, .notified] where s > stage && s <= target {
                actions.append(.escalated(stream, s, silence: silence))
            }
            stage = target
        } else if target == .ok, stage != .ok {
            actions.append(.recovered(stream, gap: peak))
            stage = .ok
        }
        peak = stage == .ok ? 0 : max(peak, silence)
    }
}
