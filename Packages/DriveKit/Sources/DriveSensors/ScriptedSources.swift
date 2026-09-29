import DriveDomain
import Foundation
import Synchronization

/// Shared start time for all streams of one scripted drive, so GPS, motion and altimeter agree.
/// Playback begins when the first stream starts iterating.
public final class ScriptPlayback: Sendable {
    public let script: DriveScript
    public let clock: any TelemetryClock
    private let startUptime = Mutex<TimeInterval?>(nil)

    public init(script: DriveScript, clock: any TelemetryClock) {
        self.script = script
        self.clock = clock
    }

    /// Seconds into the script (clamped at the end: the car stays parked).
    public var elapsed: TimeInterval {
        let now = clock.uptime
        let start = startUptime.withLock { start in
            if start == nil { start = now }
            return start!
        }
        return now - start
    }

    public func state() -> DriveScript.State { script.state(at: elapsed) }

    /// Builds a complete suite playing this script.
    public static func suite(script: DriveScript, rate: Double, label: String) -> SensorSuite {
        let clock = ScaledClock(rate: rate)
        let playback = ScriptPlayback(script: script, clock: clock)
        return SensorSuite(
            clock: clock,
            location: ScriptedLocationSource(playback: playback),
            motion: ScriptedMotionSource(playback: playback),
            altimeter: ScriptedAltimeterSource(playback: playback),
            label: label
        )
    }
}

/// 1 Hz GPS along the script, with realistic noise and no fixes inside the tunnel.
public struct ScriptedLocationSource: LocationSource {
    let playback: ScriptPlayback

    public init(playback: ScriptPlayback) {
        self.playback = playback
    }

    public func locations() -> AsyncStream<LocationSample> {
        AsyncStream(bufferingPolicy: .bufferingNewest(64)) { continuation in
            let task = Task {
                var rng = SplitMix64(seed: 1)
                while !Task.isCancelled {
                    let state = playback.state()
                    if !state.inTunnel {
                        let clock = playback.clock
                        let accuracy = 4 + abs(rng.symmetric(2.5))
                        let jitter = rng.symmetric(1.2) / 111_000
                        continuation.yield(LocationSample(
                            timestamp: clock.now.timeIntervalSince1970,
                            latitude: state.latitude + jitter,
                            longitude: state.longitude + rng.symmetric(1.2) / 90_000,
                            altitude: state.altitude + rng.symmetric(3),
                            receivedUptime: clock.uptime,
                            speed: Float(state.speed + rng.symmetric(0.15)).clamped(min: 0),
                            course: state.speed > 0.5 ? Float(state.course) : -1,
                            horizontalAccuracy: Float(accuracy),
                            verticalAccuracy: Float(accuracy * 1.5),
                            speedAccuracy: 0.4,
                            courseAccuracy: state.speed > 0.5 ? 4 : -1,
                            flags: [.synthetic]
                        ))
                    }
                    try? await playback.clock.sleep(for: 1)
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

/// Motion along the script at the requested rate, as seen by a phone in `synthesizer.mount`.
public struct ScriptedMotionSource: MotionSource {
    let playback: ScriptPlayback
    public var synthesizer: MotionSynthesizer

    public init(playback: ScriptPlayback, synthesizer: MotionSynthesizer = MotionSynthesizer()) {
        self.playback = playback
        self.synthesizer = synthesizer
    }

    public func isAvailable(_ mode: CapturePreset.MotionMode) -> Bool { true }

    public func samples(mode: CapturePreset.MotionMode) -> AsyncStream<MotionEvent> {
        AsyncStream(bufferingPolicy: .bufferingNewest(2048)) { continuation in
            guard mode.hz > 0 else {
                continuation.finish()
                return
            }
            let task = Task {
                var rng = SplitMix64(seed: 2)
                let period = 1 / mode.hz
                let startElapsed = playback.elapsed
                let startUptime = playback.clock.uptime
                var tick = 0.0
                var yaw = 0.0
                while !Task.isCancelled {
                    // Emit every sample that is due, so bursts after a scheduling hiccup keep the rate exact.
                    let due = playback.elapsed - startElapsed
                    while tick <= due {
                        let state = playback.script.state(at: startElapsed + tick)
                        yaw += state.yawRate * period
                        let dynamics = MotionSynthesizer.Dynamics(
                            longitudinal: state.longitudinalAcceleration, lateral: state.lateralAcceleration,
                            yawRate: state.yawRate, yaw: yaw
                        )
                        if let event = synthesizer.event(mode: mode, timestamp: startUptime + tick, dynamics: dynamics, rng: &rng) {
                            continuation.yield(event)
                        }
                        tick += period
                    }
                    try? await playback.clock.sleep(for: min(period * 5, 0.05))
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

/// ~1 Hz barometer along the script's elevation profile.
public struct ScriptedAltimeterSource: AltimeterSource {
    let playback: ScriptPlayback

    public init(playback: ScriptPlayback) {
        self.playback = playback
    }

    public var isAvailable: Bool { true }

    public func altitudes() -> AsyncStream<AltitudeSample> {
        AsyncStream(bufferingPolicy: .bufferingNewest(64)) { continuation in
            let task = Task {
                var rng = SplitMix64(seed: 3)
                let base = playback.state().altitude
                while !Task.isCancelled {
                    let altitude = playback.state().altitude
                    continuation.yield(AltitudeSample(
                        timestamp: playback.clock.uptime,
                        relativeAltitude: Float(altitude - base + rng.symmetric(0.3)),
                        pressure: Float(Barometer.pressure(atAltitude: altitude))
                    ))
                    try? await playback.clock.sleep(for: 1)
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

enum Barometer {
    /// Standard atmosphere, kPa.
    static func pressure(atAltitude h: Double) -> Double {
        101.325 * pow(1 - 2.25577e-5 * h, 5.25588)
    }
}

extension Float {
    func clamped(min lower: Float) -> Float { Swift.max(self, lower) }
}
