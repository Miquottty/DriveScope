import DriveDomain
import DriveReplay
import DriveSensors
import DriveStorage
import Foundation

/// What the HUD shows, published at ≤10 Hz (PLAN §6).
public struct TelemetrySnapshot: Sendable, Equatable {
    public enum GPSStatus: String, Sendable {
        /// No fix yet.
        case acquiring
        case good
        /// No fix for > 15 s (PLAN §9.3 stage 1).
        case searching
    }

    public var elapsed: TimeInterval = 0
    /// m/s, nil until the first valid speed.
    public var speed: Double?
    /// m, barometric when available (baseline + relative), else GPS.
    public var altitude: Double?
    /// Compass degrees.
    public var course: Double?
    public var distance: Double = 0
    public var horizontalAccuracy: Double?
    public var gpsStatus: GPSStatus = .acquiring
    /// g, + = left. GPS-estimated until motion calibration exists (S3).
    public var lateralG: Double = 0
    /// g, + = accelerating.
    public var longitudinalG: Double = 0
    public var locationCount = 0
    public var motionCount = 0
    public var lastLocation: RoutePoint?

    public init() {}
}

/// Consumes the sensor suite, writes every raw sample, and keeps running statistics (PLAN §6).
/// Sensor streams never touch the main actor; the HUD gets throttled snapshots through `onSnapshot`.
public actor TelemetryEngine {
    public static let gpsSearchingAfter: TimeInterval = 15

    private let suite: SensorSuite
    private let writer: SampleWriter
    private let files: SessionFiles
    private var manifest: SessionManifest
    private let onSnapshot: @Sendable (TelemetrySnapshot) -> Void
    private var statistics: SessionStatistics
    private var snapshot = TelemetrySnapshot()
    private var tasks: [Task<Void, Never>] = []
    private var lastFixUptime: TimeInterval?
    private var baroRelativeAtBaseline: Double?
    private var lastRelativeAltitude: Double?

    public init(
        suite: SensorSuite, writer: SampleWriter, files: SessionFiles, manifest: SessionManifest,
        statistics: SessionStatistics? = nil,
        onSnapshot: @escaping @Sendable (TelemetrySnapshot) -> Void
    ) {
        self.suite = suite
        self.writer = writer
        self.files = files
        self.manifest = manifest
        self.onSnapshot = onSnapshot
        self.statistics = statistics ?? SessionStatistics(clock: manifest.clock, expectedMotionHz: manifest.preset.motion.hz)
        snapshot.distance = self.statistics.distance
    }

    public func start() {
        guard tasks.isEmpty else { return }
        // Tasks created here inherit the actor, so each element is handled without an extra hop.
        let locations = suite.location.locations()
        tasks.append(Task { for await location in locations { await handle(location) } })

        let mode = manifest.preset.motion
        if mode != .none, suite.motion.isAvailable(mode) {
            let motion = suite.motion.samples(mode: mode)
            tasks.append(Task { for await event in motion { await handle(event) } })
        }
        if suite.altimeter.isAvailable {
            let altitudes = suite.altimeter.altitudes()
            tasks.append(Task { for await altitude in altitudes { await handle(altitude) } })
        }
        tasks.append(Task { await tick() })
    }

    /// Stops every stream and closes the files. Returns the final statistics.
    public func stop() async -> SessionStatistics {
        for task in tasks { task.cancel() }
        tasks.removeAll()
        await writer.close()
        return statistics
    }

    public func record(_ event: EventRecord) async {
        await writer.append(event, to: .events)
    }

    /// Forces buffered samples to disk (app backgrounding / termination, PLAN §4.1).
    public func flush() async {
        await writer.flush(sync: true)
    }

    public var elapsed: TimeInterval { suite.clock.uptime - manifest.clock.startUptime }

    public func currentStatistics() -> SessionStatistics { statistics }

    // MARK: - Streams

    private func handle(_ location: LocationSample) async {
        await writer.append(location, to: .location)
        (suite.motion as? any LocationFed)?.feed(location)
        (suite.altimeter as? any LocationFed)?.feed(location)
        statistics.add(location)
        lastFixUptime = suite.clock.uptime

        if manifest.altitudeBaseline == nil, location.verticalAccuracy > 0, location.verticalAccuracy <= 20 {
            manifest.altitudeBaseline = location.altitude
            baroRelativeAtBaseline = lastRelativeAltitude
            try? files.writeManifest(manifest)
        }

        snapshot.speed = location.hasValidSpeed ? Double(location.speed) : snapshot.speed
        snapshot.course = location.hasValidCourse ? Double(location.course) : snapshot.course
        snapshot.horizontalAccuracy = Double(location.horizontalAccuracy)
        snapshot.distance = statistics.distance
        snapshot.locationCount = statistics.locationCount
        snapshot.lastLocation = RoutePoint(latitude: location.latitude, longitude: location.longitude)
        if baroRelativeAtBaseline == nil { snapshot.altitude = location.altitude }
        if manifest.preset.motion == .none { snapshot.lateralG = statistics.gpsLateralG }
    }

    private func handle(_ event: MotionEvent) async {
        switch event {
        case .deviceMotion(let sample):
            await writer.append(sample, to: .motion)
            statistics.addMotion(timestamp: sample.timestamp)
        case .acceleration(let sample):
            await writer.append(sample, to: .accel)
            statistics.addMotion(timestamp: sample.timestamp)
        }
        snapshot.motionCount = statistics.motionCount
        // Vehicle-frame G needs the mount calibration (S3); until then the HUD shows GPS-estimated lateral g.
        snapshot.lateralG = statistics.gpsLateralG
    }

    private func handle(_ altitude: AltitudeSample) async {
        await writer.append(altitude, to: .altitude)
        statistics.add(altitude)
        let relative = Double(altitude.relativeAltitude)
        lastRelativeAltitude = relative
        if let baseline = manifest.altitudeBaseline {
            let reference = baroRelativeAtBaseline ?? relative
            baroRelativeAtBaseline = reference
            snapshot.altitude = baseline + relative - reference
        }
    }

    /// 10 Hz: publish the HUD snapshot, and let quiet streams reach disk on time.
    private func tick() async {
        var ticks = 0
        while !Task.isCancelled {
            snapshot.elapsed = elapsed
            if let last = lastFixUptime {
                snapshot.gpsStatus = suite.clock.uptime - last > Self.gpsSearchingAfter ? .searching : .good
            }
            onSnapshot(snapshot)
            ticks += 1
            if ticks % 10 == 0 { await writer.flushIfDue() }
            try? await Task.sleep(for: .milliseconds(100))
        }
    }
}
