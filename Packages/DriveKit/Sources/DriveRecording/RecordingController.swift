import DriveDomain
import DriveReplay
import DriveSensors
import DriveStorage
import Foundation
import Observation

/// HUD state on the main actor, fed ≤10 Hz by the engine (PLAN §6).
@MainActor
@Observable
public final class LiveTelemetry {
    public private(set) var snapshot = TelemetrySnapshot()

    public init() {}

    func apply(_ snapshot: TelemetrySnapshot) {
        if snapshot != self.snapshot { self.snapshot = snapshot }
    }

    func reset() {
        snapshot = TelemetrySnapshot()
    }
}

/// App / device facts stamped into every session.
public struct AppEnvironment: Sendable {
    public var appVersion: String
    public var deviceModel: String
    public var osVersion: String

    public init(appVersion: String, deviceModel: String, osVersion: String) {
        self.appVersion = appVersion
        self.deviceModel = deviceModel
        self.osVersion = osVersion
    }
}

/// The only owner of recording state (PLAN §6):
/// `idle → preparing → recording → stopping → finalizing → stopped`, plus `interrupted` for recovery.
@MainActor
@Observable
public final class RecordingController {
    public private(set) var phase: RecorderPhase = .idle
    public private(set) var session: DriveSession?
    /// The session that most recently finished, for navigation to its detail.
    public private(set) var lastFinishedSessionID: UUID?
    public private(set) var lastError: String?
    public let live = LiveTelemetry()

    private let store: SessionStore
    private let filesRoot: URL
    private let environment: AppEnvironment
    private let makeSuite: @MainActor () -> SensorSuite
    private var engine: TelemetryEngine?
    private var files: SessionFiles?
    /// Called after a session is finalized (geocoding, notifications — later sprints).
    public var onFinished: (@MainActor (DriveSession) async -> Void)?

    public init(
        store: SessionStore, filesRoot: URL, environment: AppEnvironment,
        makeSuite: @escaping @MainActor () -> SensorSuite
    ) {
        self.store = store
        self.filesRoot = filesRoot
        self.environment = environment
        self.makeSuite = makeSuite
    }

    public var isRecording: Bool { phase == .recording }

    public func start(preset: CapturePreset) async {
        guard phase == .idle || phase == .stopped else { return }
        phase = .preparing
        lastError = nil
        let suite = makeSuite()
        let clock = SessionClock(startedAt: suite.clock.now, startUptime: suite.clock.uptime)
        let manifest = SessionManifest(
            sessionID: UUID(), clock: clock, timeZoneID: TimeZone.current.identifier, preset: preset,
            appVersion: environment.appVersion, deviceModel: environment.deviceModel, osVersion: environment.osVersion
        )
        do {
            let files = SessionFiles(root: filesRoot, sessionID: manifest.sessionID)
            try files.createDirectory()
            try files.writeManifest(manifest)
            let writer = try SampleWriter(
                files: files, kinds: SessionManifest.streamKinds(for: preset),
                createdAt: clock.startedAt.timeIntervalSince1970
            )
            let session = try store.create(manifest: manifest)
            let live = live
            let engine = TelemetryEngine(suite: suite, writer: writer, files: files, manifest: manifest) { snapshot in
                Task { @MainActor in live.apply(snapshot) }
            }
            self.files = files
            self.engine = engine
            self.session = session
            live.reset()
            await engine.start()
            phase = .recording
        } catch {
            lastError = String(describing: error)
            phase = .idle
        }
    }

    public func stop() async {
        guard phase == .recording, let engine, let session, let files else { return }
        phase = .stopping
        let statistics = await engine.stop()
        let duration = max(0, await engine.elapsed)
        phase = .finalizing
        do {
            let preview = SessionStore.routePreview(from: (try? files.locations()) ?? [])
            try store.finish(
                session, state: .stopped, endedAt: session.clock.date(elapsed: duration),
                summary: statistics.summary(duration: duration), routePreview: preview
            )
        } catch {
            lastError = String(describing: error)
        }
        self.engine = nil
        self.files = nil
        self.session = nil
        lastFinishedSessionID = session.id
        phase = .stopped
        await onFinished?(session)
    }

    /// Returns to `idle` after the UI has handled `stopped`.
    public func acknowledgeStopped() {
        if phase == .stopped { phase = .idle }
    }

    /// Adds a SYNC / MARK marker at the current time (PLAN §3: elapsed + Date).
    public func mark(_ kind: MarkerKind, source: EventSource = .phone) async {
        guard phase == .recording, let engine, let session else { return }
        let elapsed = await engine.elapsed
        do {
            try store.addMarker(kind: kind, elapsed: elapsed, date: session.clock.date(elapsed: elapsed), to: session)
        } catch {
            lastError = String(describing: error)
        }
        await engine.record(EventRecord(kind: .marker, source: source, aux: kind == .sync ? 1 : 0, elapsed: elapsed))
    }

    /// App lifecycle hook: push buffered samples to disk now (backgrounding / termination).
    public func flush() async {
        await engine?.flush()
    }

    public func record(_ kind: EventKind, value: Double = 0, aux: UInt32 = 0, source: EventSource = .system) async {
        guard let engine else { return }
        let elapsed = await engine.elapsed
        await engine.record(EventRecord(kind: kind, source: source, aux: aux, elapsed: elapsed, value: value))
    }
}
