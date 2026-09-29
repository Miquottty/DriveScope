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
    /// Vehicle-frame G is available (mount calibrated). Before that, G is GPS-estimated (lateral only).
    public var isCalibrated = false
    public var lastLocation: RoutePoint?

    public init() {}
}

/// Consumes the sensor suite, writes every raw sample, and keeps running statistics (PLAN §6).
/// Sensor streams never touch the main actor; the HUD gets throttled snapshots through `onSnapshot`.
public actor TelemetryEngine {
    private let suite: SensorSuite
    private let writer: SampleWriter
    private let files: SessionFiles
    private var manifest: SessionManifest
    private let onSnapshot: @Sendable (TelemetrySnapshot) -> Void
    private let onWatchdog: @Sendable (RecordingWatchdog.Action) -> Void
    private var watchdog: RecordingWatchdog
    private let onCalibration: @Sendable (MountCalibration) -> Void
    private var calibrator = MountCalibrator()
    private var calibration: MountCalibration?
    /// Eco: low-passed raw acceleration ≈ gravity (device frame).
    private var ecoGravity: Vector3?
    /// Display / peak filter for vehicle G (~0.2 s time constant) — rejects road vibration.
    private var filteredG = (long: 0.0, lat: 0.0)
    private var lastMotionUptime: TimeInterval?
    private var hasFix = false
    private var statistics: SessionStatistics
    private var snapshot = TelemetrySnapshot()
    private var tasks: [Task<Void, Never>] = []
    private var lastFixUptime: TimeInterval
    /// Unix time this run (START or resume) began. Core Location hands over its cached fix first — on a device
    /// seen 2 minutes old — which is not part of the drive: it would start the route wherever the phone was then.
    private let runStartedAt: TimeInterval
    /// Fixes stamped this long before the run are still accepted (a fix computed just before START).
    static let staleFixTolerance: TimeInterval = 2
    private var baroRelativeAtBaseline: Double?
    private var lastRelativeAltitude: Double?

    public init(
        suite: SensorSuite, writer: SampleWriter, files: SessionFiles, manifest: SessionManifest,
        statistics: SessionStatistics? = nil,
        watchdogPolicy: RecordingWatchdog.Policy = .init(),
        onSnapshot: @escaping @Sendable (TelemetrySnapshot) -> Void,
        onWatchdog: @escaping @Sendable (RecordingWatchdog.Action) -> Void = { _ in },
        onCalibration: @escaping @Sendable (MountCalibration) -> Void = { _ in }
    ) {
        self.suite = suite
        self.writer = writer
        self.files = files
        self.manifest = manifest
        self.onSnapshot = onSnapshot
        self.onWatchdog = onWatchdog
        self.onCalibration = onCalibration
        calibration = manifest.calibration
        snapshot.isCalibrated = manifest.calibration != nil
        watchdog = RecordingWatchdog(policy: watchdogPolicy)
        // Silence is measured from (re)start, so a session that never gets a fix still escalates.
        let now = suite.clock.uptime
        runStartedAt = suite.clock.now.timeIntervalSince1970
        lastFixUptime = now
        lastMotionUptime = manifest.preset.motion == .none ? nil : now
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

    /// Tests only: stops every stream without flushing, like a process kill (buffered samples are lost).
    package func abandon() {
        for task in tasks { task.cancel() }
        tasks.removeAll()
    }

    public func record(_ event: EventRecord) async {
        await writer.append(event, to: .events)
    }

    /// Forces buffered samples to disk (app backgrounding / termination, PLAN §4.1).
    public func flush() async {
        // Called on backgrounding / termination: must complete even if the calling task is cancelled.
        await withTaskCancellationShield {
            await writer.flush(sync: true)
        }
    }

    public var elapsed: TimeInterval { suite.clock.uptime - manifest.clock.startUptime }

    public func currentStatistics() -> SessionStatistics { statistics }

    // MARK: - Streams

    private func handle(_ location: LocationSample) async {
        // Not recorded at all: a cached fix from before the run is not a sample of this drive (and not a sign
        // that GPS is alive, so the watchdog doesn't count it either).
        guard location.timestamp >= runStartedAt - Self.staleFixTolerance else { return }
        await writer.append(location, to: .location)
        (suite.motion as? any LocationFed)?.feed(location)
        (suite.altimeter as? any LocationFed)?.feed(location)
        statistics.add(location)
        lastFixUptime = suite.clock.uptime
        hasFix = true
        if let updated = calibrator.add(location, elapsed: elapsed) { await apply(updated) }

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
        let userAcceleration: Vector3
        let timestamp: Double
        switch event {
        case .deviceMotion(let sample):
            lastMotionUptime = suite.clock.uptime
            await writer.append(sample, to: .motion)
            timestamp = sample.timestamp
            userAcceleration = sample.userAcceleration
            if let updated = calibrator.add(sample, elapsed: manifest.clock.elapsed(uptime: timestamp)) { await apply(updated) }
        case .acceleration(let sample):
            lastMotionUptime = suite.clock.uptime
            await writer.append(sample, to: .accel)
            timestamp = sample.timestamp
            let hz = manifest.preset.motion.hz
            let alpha = Float(min(1, 1 / (2 * hz)))
            let gravity = ecoGravity.map { $0 + (sample.acceleration - $0) * alpha } ?? sample.acceleration
            ecoGravity = gravity
            userAcceleration = sample.acceleration - gravity
            if let updated = calibrator.add(sample, elapsed: manifest.clock.elapsed(uptime: timestamp), sampleRate: hz) {
                await apply(updated)
            }
        }
        statistics.addMotion(timestamp: timestamp)
        snapshot.motionCount = statistics.motionCount

        guard let calibration else {
            snapshot.lateralG = statistics.gpsLateralG
            return
        }
        let vehicle = calibration.apply(userAcceleration)
        let alpha = min(1, 1 / (0.2 * manifest.preset.motion.hz))
        filteredG.long += (Double(vehicle.x) - filteredG.long) * alpha
        filteredG.lat += (Double(vehicle.y) - filteredG.lat) * alpha
        statistics.add(lateralG: filteredG.lat)
        snapshot.longitudinalG = filteredG.long
        snapshot.lateralG = filteredG.lat
    }

    private func apply(_ updated: MountCalibration) async {
        calibration = updated
        manifest.calibration = updated
        try? files.writeManifest(manifest)
        snapshot.isCalibrated = true
        await writer.append(EventRecord(
            kind: .calibrationUpdated, source: updated.method == .manual ? .phone : .system,
            aux: updated.method == .manual ? 1 : 0, elapsed: elapsed, value: updated.confidence
        ), to: .events)
        onCalibration(updated)
    }

    /// Manual "rotate 90°" from the Recording screen (PLAN §7-4).
    public func rotateMountManually() async {
        if let updated = calibrator.rotateManually(elapsed: elapsed) { await apply(updated) }
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

    /// 10 Hz: publish the HUD snapshot; 1 Hz: watchdog and on-time flushing of quiet streams.
    private func tick() async {
        var ticks = 0
        while !Task.isCancelled {
            if ticks % 10 == 0 {
                await runWatchdog()
                await writer.flushIfDue()
            }
            snapshot.elapsed = elapsed
            snapshot.gpsStatus = !hasFix && watchdog.gpsStage == .ok ? .acquiring : (watchdog.gpsStage == .ok ? .good : .searching)
            onSnapshot(snapshot)
            ticks += 1
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    private func runWatchdog() async {
        let actions = watchdog.evaluate(now: suite.clock.uptime, lastLocation: lastFixUptime, lastMotion: lastMotionUptime)
        for action in actions {
            if let event = Self.event(for: action, elapsed: elapsed) {
                await writer.append(event, to: .events)
            }
            onWatchdog(action)
        }
    }

    static func event(for action: RecordingWatchdog.Action, elapsed: TimeInterval) -> EventRecord? {
        switch action {
        case .escalated(.gps, .degraded, let silence):
            EventRecord(kind: .gpsLost, source: .system, elapsed: elapsed, value: silence)
        case .escalated(.motion, .degraded, let silence):
            EventRecord(kind: .motionStalled, source: .system, elapsed: elapsed, value: silence)
        case .escalated(let stream, .notified, let silence):
            EventRecord(kind: .watchdogFired, source: .system, aux: stream == .gps ? 0 : 1, elapsed: elapsed, value: silence)
        case .recovered(.gps, let gap):
            EventRecord(kind: .gpsResumed, source: .system, elapsed: elapsed, value: gap)
        case .recovered(.motion, let gap):
            EventRecord(kind: .motionResumed, source: .system, elapsed: elapsed, value: gap)
        default:
            nil
        }
    }
}
