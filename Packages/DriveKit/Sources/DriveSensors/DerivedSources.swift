import DriveDomain
import Foundation
import Synchronization

/// Simulator stand-in for Core Motion: synthesizes motion from the GPS fixes the engine feeds it
/// (`simctl location` routes). Coarse — dynamics only change once per fix — but exercises the whole pipeline.
public final class LocationDerivedMotionSource: MotionSource, LocationFed {
    private struct Fix {
        var uptime: Double
        var speed: Double
        var course: Double
    }

    private struct State {
        var previous: Fix?
        var latest: Fix?
    }

    private let clock: any TelemetryClock
    private let synthesizer: MotionSynthesizer
    private let state = Mutex(State())

    public init(clock: any TelemetryClock, synthesizer: MotionSynthesizer = MotionSynthesizer()) {
        self.clock = clock
        self.synthesizer = synthesizer
    }

    public func feed(_ location: LocationSample) {
        guard location.hasValidSpeed else { return }
        let fix = Fix(uptime: location.receivedUptime, speed: Double(location.speed), course: Double(location.course))
        state.withLock { s in
            s.previous = s.latest
            s.latest = fix
        }
    }

    public func isAvailable(_ mode: CapturePreset.MotionMode) -> Bool { true }

    private func dynamics(yaw: inout Double, period: Double) -> MotionSynthesizer.Dynamics {
        let (previous, latest) = state.withLock { ($0.previous, $0.latest) }
        guard let a = previous, let b = latest, b.uptime > a.uptime else {
            return .init(longitudinal: 0, lateral: 0, yawRate: 0, yaw: yaw)
        }
        let dt = b.uptime - a.uptime
        // Compass course is clockwise; yaw rate is counter-clockwise positive.
        let yawRate = a.course >= 0 && b.course >= 0 && b.speed > 1
            ? -Units.headingDelta(from: a.course, to: b.course) * .pi / 180 / dt
            : 0
        yaw += yawRate * period
        return .init(longitudinal: (b.speed - a.speed) / dt, lateral: b.speed * yawRate, yawRate: yawRate, yaw: yaw)
    }

    public func samples(mode: CapturePreset.MotionMode) -> AsyncStream<MotionEvent> {
        AsyncStream(bufferingPolicy: .bufferingNewest(2048)) { continuation in
            guard mode.hz > 0 else {
                continuation.finish()
                return
            }
            let task = Task {
                var rng = SplitMix64(seed: 4)
                var yaw = 0.0
                let period = 1 / mode.hz
                var next = clock.uptime
                while !Task.isCancelled {
                    let now = clock.uptime
                    while next <= now {
                        let d = dynamics(yaw: &yaw, period: period)
                        if let event = synthesizer.event(mode: mode, timestamp: next, dynamics: d, rng: &rng) {
                            continuation.yield(event)
                        }
                        next += period
                    }
                    try? await clock.sleep(for: min(period * 5, 0.05))
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

/// Simulator stand-in for the barometer: relative altitude from GPS altitude.
public final class LocationDerivedAltimeterSource: AltimeterSource, LocationFed {
    private struct State {
        var continuation: AsyncStream<AltitudeSample>.Continuation?
        var base: Double?
    }

    private let state = Mutex(State())

    public init() {}

    public var isAvailable: Bool { true }

    public func feed(_ location: LocationSample) {
        guard location.verticalAccuracy > 0 else { return }
        state.withLock { s in
            let base = s.base ?? location.altitude
            s.base = base
            s.continuation?.yield(AltitudeSample(
                timestamp: location.receivedUptime,
                relativeAltitude: Float(location.altitude - base),
                pressure: Float(Barometer.pressure(atAltitude: location.altitude))
            ))
        }
    }

    public func altitudes() -> AsyncStream<AltitudeSample> {
        AsyncStream(bufferingPolicy: .bufferingNewest(64)) { continuation in
            state.withLock { $0 = State(continuation: continuation, base: nil) }
            continuation.onTermination = { [weak self] _ in
                self?.state.withLock { $0.continuation = nil }
            }
        }
    }
}

/// For devices / modes without the sensor (e.g. GPS Only never asks for motion).
public struct UnavailableMotionSource: MotionSource {
    public init() {}
    public func isAvailable(_ mode: CapturePreset.MotionMode) -> Bool { mode == .none }
    public func samples(mode: CapturePreset.MotionMode) -> AsyncStream<MotionEvent> { AsyncStream { $0.finish() } }
}

public struct UnavailableAltimeterSource: AltimeterSource {
    public init() {}
    public var isAvailable: Bool { false }
    public func altitudes() -> AsyncStream<AltitudeSample> { AsyncStream { $0.finish() } }
}
