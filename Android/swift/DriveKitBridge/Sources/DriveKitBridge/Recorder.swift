import CJNI
import DriveDomain
import DriveRecording
import DriveReplay
import DriveSensors
import DriveStorage
import Foundation
import Synchronization
#if canImport(Android)
import Android
#endif

// The Android app records with DriveKit's own `TelemetryEngine` (docs/ANDROID_PLAN.md): Kotlin reads the sensors,
// converts them to the iOS conventions and pushes them here; the engine writes the `.bin` streams, keeps the
// statistics, the mount calibration, the satellite state and the watchdog exactly as on the iPhone.

/// `elapsedRealtime`: CLOCK_BOOTTIME, the clock of Android's sensor and location timestamps (sleep included).
struct AndroidClock: TelemetryClock {
    var now: Date { Date() }
    var uptime: TimeInterval { Self.boottime() }

    func sleep(for seconds: TimeInterval) async throws {
        try await Task.sleep(for: .seconds(seconds))
    }

    static func boottime() -> TimeInterval {
        #if os(Android)
        var ts = timespec()
        clock_gettime(CLOCK_BOOTTIME, &ts)
        return Double(ts.tv_sec) + Double(ts.tv_nsec) / 1e9
        #else
        return ProcessInfo.processInfo.systemUptime
        #endif
    }
}

/// A single-consumer stream fed from JNI; buffered from creation so nothing pushed before the engine starts is lost.
final class PushStream<Element: Sendable>: Sendable {
    let stream: AsyncStream<Element>
    private let continuation: AsyncStream<Element>.Continuation

    init() {
        (stream, continuation) = AsyncStream.makeStream(of: Element.self, bufferingPolicy: .bufferingNewest(1024))
    }

    func push(_ element: Element) { continuation.yield(element) }
    func finish() { continuation.finish() }
}

struct PushLocationSource: LocationSource {
    let pipe: PushStream<LocationSample>
    func locations() -> AsyncStream<LocationSample> { pipe.stream }
}

struct PushMotionSource: MotionSource {
    let pipe: PushStream<MotionEvent>
    let hasGyroscope: Bool

    func isAvailable(_ mode: CapturePreset.MotionMode) -> Bool {
        switch mode {
        case .none: false
        case .accelerometer: true
        case .deviceMotion: hasGyroscope
        }
    }

    func samples(mode: CapturePreset.MotionMode) -> AsyncStream<MotionEvent> { pipe.stream }
}

struct PushAltimeterSource: AltimeterSource {
    let pipe: PushStream<AltitudeSample>
    let isAvailable: Bool
    func altitudes() -> AsyncStream<AltitudeSample> { pipe.stream }
}

/// A value shared between the engine's callbacks and the JNI calls (a `Mutex` can't be captured by an escaping closure).
final class Locked<Value: Sendable>: Sendable {
    private let mutex: Mutex<Value>

    init(_ value: Value) {
        mutex = Mutex(value)
    }

    func withLock<R>(_ body: (inout sending Value) -> sending R) -> R {
        mutex.withLock(body)
    }
}

/// One recording run; owned by the Kotlin service through an opaque handle.
final class AndroidRecording: Sendable {
    let files: SessionFiles
    let manifest: SessionManifest
    let engine: TelemetryEngine
    let clock: AndroidClock
    let location: PushStream<LocationSample>
    let motion: PushStream<MotionEvent>
    let altitude: PushStream<AltitudeSample>
    let snapshot: Locked<TelemetrySnapshot>
    let watchdog: Locked<[RecordingWatchdog.Action]>

    init(files: SessionFiles, manifest: SessionManifest, hasGyroscope: Bool, hasBarometer: Bool, fastWatchdog: Bool) throws {
        let clock = AndroidClock()
        let location = PushStream<LocationSample>(), motion = PushStream<MotionEvent>(), altitude = PushStream<AltitudeSample>()
        let snapshot = Locked(TelemetrySnapshot()), watchdog = Locked<[RecordingWatchdog.Action]>([])
        self.files = files
        self.manifest = manifest
        self.clock = clock
        self.location = location
        self.motion = motion
        self.altitude = altitude
        self.snapshot = snapshot
        self.watchdog = watchdog
        let suite = SensorSuite(
            clock: clock,
            location: PushLocationSource(pipe: location),
            motion: PushMotionSource(pipe: motion, hasGyroscope: hasGyroscope),
            altimeter: PushAltimeterSource(pipe: altitude, isAvailable: hasBarometer),
            label: "android"
        )
        let writer = try SampleWriter(
            files: files, kinds: SessionManifest.streamKinds(for: manifest.preset),
            createdAt: manifest.clock.startedAt.timeIntervalSince1970, uptime: { clock.uptime }
        )
        let policy = RecordingWatchdog.Policy()
        engine = TelemetryEngine(
            suite: suite, writer: writer, files: files, manifest: manifest,
            watchdogPolicy: fastWatchdog ? policy.accelerated(by: 10) : policy,
            onSnapshot: { value in snapshot.withLock { $0 = value } },
            onWatchdog: { action in watchdog.withLock { $0.append(action) } }
        )
    }

    /// Unix time of a fix stamped on the boot clock: the same mapping the engine uses for motion, so GPS and motion line up.
    func unixTime(boot: Double) -> Double {
        manifest.clock.startedAt.timeIntervalSince1970 + (boot - manifest.clock.startUptime)
    }

    func finishStreams() {
        location.finish(); motion.finish(); altitude.finish()
    }
}

/// Runs async engine work from a JNI call (a Kotlin worker thread) and waits for it.
func blocking<T: Sendable>(_ operation: @escaping @Sendable () async -> T) -> T {
    let result = Locked<T?>(nil)
    let done = DispatchSemaphore(value: 0)
    Task {
        let value = await operation()
        result.withLock { $0 = value }
        done.signal()
    }
    done.wait()
    return result.withLock { $0! }
}

private func recording(_ handle: jlong) -> AndroidRecording? {
    guard handle != 0, let pointer = UnsafeRawPointer(bitPattern: Int(handle)) else { return nil }
    return Unmanaged<AndroidRecording>.fromOpaque(pointer).takeUnretainedValue()
}

private func json<T: Encodable>(_ value: T) -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    return (try? encoder.encode(value)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
}

/// `recorderStart(root, preset, appVersion, deviceModel, osVersion, timeZoneID, hasGyroscope, hasBarometer, fastWatchdog)`
/// → handle (0 on failure). Creates `<root>/<UUID>/` with its manifest and opens the streams.
@_cdecl("Java_com_miquottty_drivescope_bridge_DriveKitBridge_recorderStart")
public func recorderStart(
    env: UnsafeMutablePointer<JNIEnv?>, type: jclass?, root: jstring?, preset: jstring?, appVersion: jstring?,
    deviceModel: jstring?, osVersion: jstring?, timeZoneID: jstring?, hasGyroscope: jboolean, hasBarometer: jboolean,
    fastWatchdog: jboolean
) -> jlong {
    guard let preset = CapturePreset(rawValue: env.string(preset)) else { return 0 }
    let clock = AndroidClock()
    let manifest = SessionManifest(
        sessionID: UUID(), clock: SessionClock(startedAt: clock.now, startUptime: clock.uptime),
        timeZoneID: env.string(timeZoneID), preset: preset, appVersion: env.string(appVersion),
        deviceModel: env.string(deviceModel), osVersion: env.string(osVersion)
    )
    let files = SessionFiles(root: URL(filePath: env.string(root), directoryHint: .isDirectory), sessionID: manifest.sessionID)
    do {
        try files.createDirectory()
        try files.writeManifest(manifest)
        let recording = try AndroidRecording(
            files: files, manifest: manifest, hasGyroscope: hasGyroscope != 0, hasBarometer: hasBarometer != 0,
            fastWatchdog: fastWatchdog != 0
        )
        blocking { await recording.engine.start() }
        return jlong(Int(bitPattern: Unmanaged.passRetained(recording).toOpaque()))
    } catch {
        return 0
    }
}

@_cdecl("Java_com_miquottty_drivescope_bridge_DriveKitBridge_recorderSessionID")
public func recorderSessionID(env: UnsafeMutablePointer<JNIEnv?>, type: jclass?, handle: jlong) -> jstring? {
    env.jstring(recording(handle)?.manifest.sessionID.uuidString ?? "")
}

/// A fix in the iOS conventions (speed / course / accuracies −1 when invalid), stamped on the boot clock.
@_cdecl("Java_com_miquottty_drivescope_bridge_DriveKitBridge_pushLocation")
public func pushLocation(
    env: UnsafeMutablePointer<JNIEnv?>, type: jclass?, handle: jlong, boot: jdouble, latitude: jdouble, longitude: jdouble,
    altitude: jdouble, speed: jfloat, course: jfloat, horizontalAccuracy: jfloat, verticalAccuracy: jfloat,
    speedAccuracy: jfloat, courseAccuracy: jfloat, flags: jint
) {
    guard let r = recording(handle) else { return }
    r.location.push(LocationSample(
        timestamp: r.unixTime(boot: boot), latitude: latitude, longitude: longitude, altitude: altitude,
        receivedUptime: r.clock.uptime, speed: speed, course: course, horizontalAccuracy: horizontalAccuracy,
        verticalAccuracy: verticalAccuracy, speedAccuracy: speedAccuracy, courseAccuracy: courseAccuracy,
        flags: LocationSample.Flags(rawValue: UInt32(bitPattern: flags))
    ))
}

/// Device motion: `values` = userAcceleration xyz (g), gravity xyz (g), rotationRate xyz (rad/s), attitude wxyz,
/// magneticField xyz (µT) — 16 floats, already in Core Motion's conventions.
@_cdecl("Java_com_miquottty_drivescope_bridge_DriveKitBridge_pushMotion")
public func pushMotion(
    env: UnsafeMutablePointer<JNIEnv?>, type: jclass?, handle: jlong, boot: jdouble, values: jfloatArray?, magneticAccuracy: jint
) {
    guard let r = recording(handle) else { return }
    let v = env.floats(values)
    guard v.count >= 16 else { return }
    r.motion.push(.deviceMotion(MotionSample(
        timestamp: boot,
        userAcceleration: Vector3(x: v[0], y: v[1], z: v[2]),
        gravity: Vector3(x: v[3], y: v[4], z: v[5]),
        rotationRate: Vector3(x: v[6], y: v[7], z: v[8]),
        attitude: Quaternion(w: v[9], x: v[10], y: v[11], z: v[12]),
        magneticField: Vector3(x: v[13], y: v[14], z: v[15]),
        magneticAccuracy: magneticAccuracy
    )))
}

/// Eco: raw acceleration including gravity, in g with Core Motion's sign.
@_cdecl("Java_com_miquottty_drivescope_bridge_DriveKitBridge_pushAccel")
public func pushAccel(env: UnsafeMutablePointer<JNIEnv?>, type: jclass?, handle: jlong, boot: jdouble, x: jfloat, y: jfloat, z: jfloat) {
    recording(handle)?.motion.push(.acceleration(AccelSample(timestamp: boot, acceleration: Vector3(x: x, y: y, z: z))))
}

@_cdecl("Java_com_miquottty_drivescope_bridge_DriveKitBridge_pushAltitude")
public func pushAltitude(
    env: UnsafeMutablePointer<JNIEnv?>, type: jclass?, handle: jlong, boot: jdouble, relativeAltitude: jfloat, kPa: jfloat
) {
    recording(handle)?.altitude.push(AltitudeSample(timestamp: boot, relativeAltitude: relativeAltitude, pressure: kPa))
}

/// Fields of `snapshot`, in order (NaN = none).
enum SnapshotField: Int, CaseIterable {
    case elapsed, speed, altitude, course, distance, horizontalAccuracy, gpsStatus, lateralG, longitudinalG
    case locationCount, motionCount, isCalibrated, satelliteFixAfter, latitude, longitude
}

/// The HUD's 10 Hz view of the run (`TelemetrySnapshot`); gpsStatus 0 acquiring, 1 good, 2 searching.
@_cdecl("Java_com_miquottty_drivescope_bridge_DriveKitBridge_snapshot")
public func snapshot(env: UnsafeMutablePointer<JNIEnv?>, type: jclass?, handle: jlong) -> jdoubleArray? {
    guard let r = recording(handle) else { return env.doubleArray([]) }
    let s = r.snapshot.withLock { $0 }
    let status: Double = switch s.gpsStatus {
    case .acquiring: 0
    case .good: 1
    case .searching: 2
    }
    return env.doubleArray([
        s.elapsed, s.speed ?? .nan, s.altitude ?? .nan, s.course ?? .nan, s.distance, s.horizontalAccuracy ?? .nan, status,
        s.lateralG, s.longitudinalG, Double(s.locationCount), Double(s.motionCount), s.isCalibrated ? 1 : 0,
        s.satelliteFixAfter ?? .nan, s.lastLocation?.latitude ?? .nan, s.lastLocation?.longitude ?? .nan,
    ])
}

/// Watchdog actions since the last call: [kind (0 escalated, 1 recovered, 2 rearm dead-man), stream (0 GPS, 1 motion),
/// stage (1 degraded, 2 alerted, 3 notified), seconds] × actions.
@_cdecl("Java_com_miquottty_drivescope_bridge_DriveKitBridge_drainWatchdog")
public func drainWatchdog(env: UnsafeMutablePointer<JNIEnv?>, type: jclass?, handle: jlong) -> jdoubleArray? {
    guard let r = recording(handle) else { return env.doubleArray([]) }
    let actions = r.watchdog.withLock { actions in defer { actions.removeAll() }; return actions }
    return env.doubleArray(actions.flatMap { action -> [Double] in
        switch action {
        case .escalated(let stream, let stage, let silence): [0, stream == .gps ? 0 : 1, Double(stage.rawValue), silence]
        case .recovered(let stream, let gap): [1, stream == .gps ? 0 : 1, 0, gap]
        case .rearmDeadman: [2, 0, 0, 0]
        }
    })
}

/// A MARK / SYNC / HIGHLIGHT marker now (`kind` = `MarkerKind.eventAux`); returns its elapsed. `pressedAt` (unix s, 0 for
/// the phone) is a remote press time, as on iOS.
@_cdecl("Java_com_miquottty_drivescope_bridge_DriveKitBridge_mark")
public func mark(
    env: UnsafeMutablePointer<JNIEnv?>, type: jclass?, handle: jlong, kind: jint, source: jint, pressedAt: jdouble
) -> jdouble {
    guard let r = recording(handle), let source = EventSource(rawValue: UInt8(clamping: source)) else { return .nan }
    return blocking {
        let elapsed = await r.engine.elapsed
        await r.engine.record(EventRecord(kind: .marker, source: source, aux: UInt32(kind), elapsed: elapsed, value: pressedAt))
        return elapsed
    }
}

/// SYNC with its beep: the marker sits at the beep's onset (boot clock), the tap time goes to its value, and a
/// `syncBeep` event carries the output latency and route (0 speaker, 1 wireless, 2 other) — as on iOS.
@_cdecl("Java_com_miquottty_drivescope_bridge_DriveKitBridge_sync")
public func sync(
    env: UnsafeMutablePointer<JNIEnv?>, type: jclass?, handle: jlong, onsetBoot: jdouble, latency: jdouble, route: jint,
    pressedAt: jdouble
) -> jdouble {
    guard let r = recording(handle) else { return .nan }
    return blocking {
        let elapsed = onsetBoot.isNaN ? await r.engine.elapsed : await r.engine.elapsed(clockUptime: onsetBoot)
        await r.engine.record(EventRecord(
            kind: .marker, source: .phone, aux: MarkerKind.sync.eventAux, elapsed: elapsed, value: pressedAt
        ))
        if !onsetBoot.isNaN {
            await r.engine.record(EventRecord(kind: .syncBeep, source: .phone, aux: UInt32(route), elapsed: elapsed, value: latency))
        }
        return elapsed
    }
}

/// Any other event (device state, battery…), stamped now.
@_cdecl("Java_com_miquottty_drivescope_bridge_DriveKitBridge_recordEvent")
public func recordEvent(
    env: UnsafeMutablePointer<JNIEnv?>, type: jclass?, handle: jlong, kind: jint, source: jint, aux: jint, value: jdouble
) {
    guard let r = recording(handle), let kind = EventKind(rawValue: UInt16(clamping: kind)),
          let source = EventSource(rawValue: UInt8(clamping: source)) else { return }
    blocking {
        let elapsed = await r.engine.elapsed
        await r.engine.record(EventRecord(kind: kind, source: source, aux: UInt32(bitPattern: aux), elapsed: elapsed, value: value))
    }
}

@_cdecl("Java_com_miquottty_drivescope_bridge_DriveKitBridge_rotateMount")
public func rotateMount(env: UnsafeMutablePointer<JNIEnv?>, type: jclass?, handle: jlong) {
    guard let r = recording(handle) else { return }
    blocking { await r.engine.rotateMountManually() }
}

@_cdecl("Java_com_miquottty_drivescope_bridge_DriveKitBridge_flush")
public func flush(env: UnsafeMutablePointer<JNIEnv?>, type: jclass?, handle: jlong) {
    guard let r = recording(handle) else { return }
    blocking { await r.engine.flush() }
}

private struct StopResult: Encodable {
    var sessionID: String
    var endedAt: Double
    var summary: SessionSummary
    var routePreview: [RoutePoint]
}

/// Stops the run, closes the streams, writes `endedAt`; returns {sessionID, endedAt, summary, routePreview} as JSON and
/// releases the handle.
@_cdecl("Java_com_miquottty_drivescope_bridge_DriveKitBridge_recorderStop")
public func recorderStop(env: UnsafeMutablePointer<JNIEnv?>, type: jclass?, handle: jlong) -> jstring? {
    guard let r = recording(handle) else { return env.jstring("{}") }
    defer { Unmanaged.passUnretained(r).release() }
    let (statistics, duration) = blocking {
        let statistics = await r.engine.stop()
        return (statistics, max(0, await r.engine.elapsed))
    }
    r.finishStreams()
    let endedAt = r.manifest.clock.date(elapsed: duration)
    if var manifest = try? r.files.readManifest() {
        manifest.endedAt = endedAt
        try? r.files.writeManifest(manifest)
    }
    var summary = statistics.summary(duration: duration)
    summary.batteryUsagePerHour = BatteryUsage(events: (try? r.files.events()) ?? []).overall
    let preview = RoutePreview.make(from: (try? r.files.locations()) ?? [])
    return env.jstring(json(StopResult(
        sessionID: r.manifest.sessionID.uuidString, endedAt: endedAt.timeIntervalSince1970, summary: summary,
        routePreview: preview
    )))
}
