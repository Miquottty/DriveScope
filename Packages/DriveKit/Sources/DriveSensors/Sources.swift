import DriveDomain
import Foundation

/// Wall + uptime clock used by the whole recording pipeline. Injected so simulated drives can run faster
/// than real time and tests can be deterministic.
public protocol TelemetryClock: Sendable {
    /// Absolute time (stamped on Location samples).
    var now: Date { get }
    /// Monotonic seconds, same domain as `ProcessInfo.systemUptime` / `CMLogItem.timestamp`.
    var uptime: TimeInterval { get }
    /// Sleeps for `seconds` of this clock's time.
    func sleep(for seconds: TimeInterval) async throws
}

public struct SystemClock: TelemetryClock {
    public init() {}
    public var now: Date { Date() }
    public var uptime: TimeInterval { ProcessInfo.processInfo.systemUptime }
    public func sleep(for seconds: TimeInterval) async throws {
        try await Task.sleep(for: .seconds(seconds))
    }
}

/// Runs `rate` times faster than real time (DriveSim). Both domains start at the real values when created.
public struct ScaledClock: TelemetryClock {
    public let rate: Double
    private let baseDate: Date
    private let baseUptime: TimeInterval

    public init(rate: Double) {
        self.rate = rate
        baseDate = Date()
        baseUptime = ProcessInfo.processInfo.systemUptime
    }

    private var scaledElapsed: TimeInterval { (ProcessInfo.processInfo.systemUptime - baseUptime) * rate }
    public var now: Date { baseDate.addingTimeInterval(scaledElapsed) }
    public var uptime: TimeInterval { baseUptime + scaledElapsed }
    public func sleep(for seconds: TimeInterval) async throws {
        try await Task.sleep(for: .seconds(seconds / rate))
    }
}

/// Location fixes. Iterating the stream starts updates; cancelling the iterating task stops them.
public protocol LocationSource: Sendable {
    func locations() -> AsyncStream<LocationSample>
}

public enum MotionEvent: Sendable, Equatable {
    case deviceMotion(MotionSample)
    case acceleration(AccelSample)
}

public protocol MotionSource: Sendable {
    /// Whether this source can deliver `mode` (device motion needs a gyro; the simulator has none).
    func isAvailable(_ mode: CapturePreset.MotionMode) -> Bool
    func samples(mode: CapturePreset.MotionMode) -> AsyncStream<MotionEvent>
}

public protocol AltimeterSource: Sendable {
    var isAvailable: Bool { get }
    func altitudes() -> AsyncStream<AltitudeSample>
}

/// Sources derived from GPS (simulator without Core Motion) receive every fix the engine gets.
public protocol LocationFed: Sendable {
    func feed(_ location: LocationSample)
}

/// Everything the engine reads from. Swapped as a unit: real device, simulator route, or scripted drive.
public struct SensorSuite: Sendable {
    public var clock: any TelemetryClock
    public var location: any LocationSource
    public var motion: any MotionSource
    public var altimeter: any AltimeterSource
    /// Human-readable origin for Quality / debug ("device", "simulator-route", "script:akagi").
    public var label: String

    public init(
        clock: any TelemetryClock, location: any LocationSource, motion: any MotionSource,
        altimeter: any AltimeterSource, label: String
    ) {
        self.clock = clock
        self.location = location
        self.motion = motion
        self.altimeter = altimeter
        self.label = label
    }
}
