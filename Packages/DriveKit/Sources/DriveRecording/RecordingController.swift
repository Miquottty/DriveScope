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

/// Side effects of recording that live in the app (Live Activity, notifications). All calls are on the main actor.
@MainActor
public protocol RecordingObserver: AnyObject {
    func recordingDidStart(_ session: DriveSession, resumed: Bool)
    func recordingWatchdog(_ action: RecordingWatchdog.Action, session: DriveSession)
    func recordingDidStop(_ session: DriveSession)
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
    /// Called after a session is finalized (geocoding — S4).
    public var onFinished: (@MainActor (DriveSession) async -> Void)?
    private var observers: [any RecordingObserver] = []
    /// Debug builds may shorten the watchdog thresholds (Settings → Debug).
    public var watchdogPolicy = RecordingWatchdog.Policy()
    /// Runs at STOP before the streams close — last-moment events (e.g. a final battery snapshot).
    public var willStop: (@MainActor () async -> Void)?
    /// Applied at every START / resume, so settings changed since launch take effect.
    public var prepareForStart: (@MainActor (RecordingController) -> Void)?

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

    /// Observers are retained for the controller's lifetime (they are app-lifetime objects).
    public func addObserver(_ observer: any RecordingObserver) {
        observers.append(observer)
    }

    public func start(preset: CapturePreset) async {
        guard phase == .idle || phase == .stopped else { return }
        phase = .preparing
        lastError = nil
        prepareForStart?(self)
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
            let session = try store.create(manifest: manifest)
            try await run(session: session, files: files, manifest: manifest, suite: suite, statistics: nil)
            observers.forEach { $0.recordingDidStart(session, resumed: false) }
        } catch {
            lastError = String(describing: error)
            phase = .idle
        }
    }

    private func run(
        session: DriveSession, files: SessionFiles, manifest: SessionManifest, suite: SensorSuite,
        statistics: SessionStatistics?
    ) async throws {
        let writer = try SampleWriter(
            files: files, kinds: SessionManifest.streamKinds(for: manifest.preset),
            createdAt: manifest.clock.startedAt.timeIntervalSince1970
        )
        let live = live
        let engine = TelemetryEngine(
            suite: suite, writer: writer, files: files, manifest: manifest, statistics: statistics,
            watchdogPolicy: watchdogPolicy,
            onSnapshot: { snapshot in Task { @MainActor in live.apply(snapshot) } },
            onWatchdog: { [weak self] action in Task { @MainActor in self?.handle(action) } },
            onCalibration: { [weak self] calibration in Task { @MainActor in self?.persist(calibration) } }
        )
        self.files = files
        self.engine = engine
        self.session = session
        live.reset()
        await engine.start()
        phase = .recording
    }

    private func persist(_ calibration: MountCalibration) {
        guard let session else { return }
        session.calibration = calibration
        try? store.save()
    }

    /// Recording screen: the auto calibration picked the wrong axis; turn "forward" by 90°.
    public func rotateMount() async {
        await engine?.rotateMountManually()
    }

    private func handle(_ action: RecordingWatchdog.Action) {
        guard let session, phase == .recording else { return }
        observers.forEach { $0.recordingWatchdog(action, session: session) }
    }

    public func stop() async {
        guard phase == .recording, let engine, let session, let files else { return }
        phase = .stopping
        await willStop?()
        let statistics = await engine.stop()
        let duration = max(0, await engine.elapsed)
        phase = .finalizing
        let endedAt = session.clock.date(elapsed: duration)
        writeEnd(endedAt, to: files)
        do {
            let preview = SessionStore.routePreview(from: (try? files.locations()) ?? [])
            try store.finish(
                session, state: .stopped, endedAt: endedAt,
                summary: Self.summary(statistics, duration: duration, files: files), routePreview: preview
            )
        } catch {
            lastError = String(describing: error)
        }
        self.engine = nil
        self.files = nil
        self.session = nil
        lastFinishedSessionID = session.id
        phase = .stopped
        observers.forEach { $0.recordingDidStop(session) }
        await onFinished?(session)
    }

    /// Returns to `idle` after the UI has handled `stopped`.
    public func acknowledgeStopped() {
        if phase == .stopped { phase = .idle }
    }

    /// Adds a SYNC / MARK marker at the current time (PLAN §3: elapsed + Date).
    /// `pressedAt`: when a remote control (the watch) was pressed. The marker stays at the iPhone's receive time;
    /// the press time goes to the event's value (unix seconds) so the link delay can be read back later.
    public func mark(_ kind: MarkerKind, source: EventSource = .phone, pressedAt: Date? = nil) async {
        guard phase == .recording, let engine, let session else { return }
        let elapsed = await engine.elapsed
        do {
            try store.addMarker(kind: kind, elapsed: elapsed, date: session.clock.date(elapsed: elapsed), to: session)
        } catch {
            lastError = String(describing: error)
        }
        await engine.record(EventRecord(
            kind: .marker, source: source, aux: kind == .sync ? 1 : 0, elapsed: elapsed,
            value: pressedAt?.timeIntervalSince1970 ?? 0
        ))
    }

    /// App lifecycle hook: push buffered samples to disk now (backgrounding).
    public func flush() async {
        await engine?.flush()
    }

    /// `willTerminate`: the main thread may block briefly, so flush on the engine's executor and wait for it.
    /// The engine and writer are actors off the main actor, so waiting here cannot deadlock.
    public func flushBeforeTermination(timeout: TimeInterval = 1.5) {
        guard let engine else { return }
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            await engine.flush()
            done.signal()
        }
        _ = done.wait(timeout: .now() + timeout)
    }

    public func record(_ kind: EventKind, value: Double = 0, aux: UInt32 = 0, source: EventSource = .system) async {
        guard let engine else { return }
        let elapsed = await engine.elapsed
        await engine.record(EventRecord(kind: kind, source: source, aux: aux, elapsed: elapsed, value: value))
    }

    /// Tests only: simulates the process dying mid-recording.
    package func simulateKill() async {
        await engine?.abandon()
        engine = nil
        session = nil
        phase = .idle
    }

    // MARK: - Unfinished sessions (PLAN §9.2 / §9.3)

    /// Sessions left in `.recording` by a crash, kill or suspension, excluding the live one.
    public func unfinishedSessions() -> [DriveSession] {
        store.sessions(in: .recording).filter { $0.id != session?.id }
    }

    /// Finalizes an unfinished session from what reached disk: statistics are recomputed from the files.
    public func recover(_ unfinished: DriveSession) async {
        let files = SessionFiles(root: filesRoot, sessionID: unfinished.id)
        do {
            let manifest = try files.readManifest()
            let (statistics, duration) = try await Self.recompute(files: files, manifest: manifest)
            let preview = SessionStore.routePreview(from: (try? files.locations()) ?? [])
            let endedAt = manifest.clock.date(elapsed: duration)
            writeEnd(endedAt, to: files)
            try store.finish(
                unfinished, state: .recovered, endedAt: endedAt,
                summary: Self.summary(statistics, duration: duration, files: files), routePreview: preview
            )
            await onFinished?(unfinished)
        } catch {
            lastError = String(describing: error)
        }
    }

    public func discard(_ unfinished: DriveSession) {
        do {
            try store.delete(unfinished, filesRoot: filesRoot)
        } catch {
            lastError = String(describing: error)
        }
    }

    /// Whether recording can continue in the same files: the uptime clock must not have been reset by a reboot.
    public func canResume(_ unfinished: DriveSession) -> Bool {
        guard phase == .idle || phase == .stopped else { return false }
        // (Scripted drives run a scaled clock, so a resumed script restarts its own timeline — fine for testing.)
        return ProcessInfo.processInfo.systemUptime >= unfinished.startUptime
    }

    /// How long after its last sample an unfinished session may still be continued (recovery sheet, robust mode).
    public nonisolated static let resumeWindow: TimeInterval = 30 * 60

    /// Whether an unfinished session may be continued: same boot (the uptime clock only resets on reboot) and not
    /// longer than `window` since its last sample on the wall clock (uptime pauses while the device sleeps).
    public nonisolated static func resumeDecision(
        startUptime: TimeInterval, nowUptime: TimeInterval, startedAt: Date, lastElapsed: TimeInterval, now: Date,
        window: TimeInterval = resumeWindow
    ) -> Bool {
        nowUptime >= startUptime && now.timeIntervalSince(startedAt.addingTimeInterval(lastElapsed)) <= window
    }

    /// Continues an unfinished session, appending to the same files (dead-man notification tap, PLAN §9.3).
    public func resume(_ unfinished: DriveSession) async {
        guard canResume(unfinished) else { return }
        phase = .preparing
        await continueSession(unfinished, automatic: false, now: Date())
    }

    /// Robust mode (PLAN §9.5): iOS relaunched the app in the background after the process died — continue the
    /// newest unfinished session without any UI when `resumeDecision` allows it. `.preparing` is set before the
    /// first suspension, so the recovery sheet never offers the session meanwhile. false → back to idle.
    public func autoResume(now: Date = Date()) async -> Bool {
        guard let candidate = unfinishedSessions().max(by: { $0.startedAt < $1.startedAt }), canResume(candidate) else { return false }
        phase = .preparing
        return await continueSession(candidate, automatic: true, now: now)
    }

    @discardableResult
    private func continueSession(_ unfinished: DriveSession, automatic: Bool, now: Date) async -> Bool {
        prepareForStart?(self)
        let files = SessionFiles(root: filesRoot, sessionID: unfinished.id)
        do {
            let manifest = try files.readManifest()
            let (statistics, lastElapsed) = try await Self.recompute(files: files, manifest: manifest)
            if automatic, !Self.resumeDecision(
                startUptime: unfinished.startUptime, nowUptime: ProcessInfo.processInfo.systemUptime,
                startedAt: unfinished.startedAt, lastElapsed: lastElapsed, now: now
            ) {
                phase = .idle
                return false
            }
            try await run(session: unfinished, files: files, manifest: manifest, suite: makeSuite(), statistics: statistics)
            if let engine {
                let elapsed = await engine.elapsed
                let gap = elapsed - lastElapsed
                await engine.record(EventRecord(kind: .sessionResumed, source: .system, elapsed: elapsed, value: gap))
                if automatic {
                    await engine.record(EventRecord(kind: .autoResumed, source: .system, elapsed: elapsed, value: gap))
                }
            }
            observers.forEach { $0.recordingDidStart(unfinished, resumed: true) }
            return true
        } catch {
            lastError = String(describing: error)
            phase = .idle
            return false
        }
    }

    /// Exports read `endedAt` from the manifest, not SwiftData. Called once the engine has stopped, so re-reading
    /// keeps its latest manifest writes (calibration, baseline) and nothing races. A failure must not keep the
    /// session from finishing.
    private func writeEnd(_ endedAt: Date, to files: SessionFiles) {
        do {
            var manifest = try files.readManifest()
            manifest.endedAt = endedAt
            try files.writeManifest(manifest)
        } catch {
            lastError = String(describing: error)
        }
    }

    private static func summary(_ statistics: SessionStatistics, duration: TimeInterval, files: SessionFiles) -> SessionSummary {
        var summary = statistics.summary(duration: duration)
        summary.batteryUsagePerHour = BatteryUsage(events: (try? files.events()) ?? []).overall
        return summary
    }

    /// Reads the files off the main actor.
    @concurrent nonisolated private static func recompute(files: SessionFiles, manifest: SessionManifest) async throws -> (SessionStatistics, TimeInterval) {
        try SessionStatistics.compute(files: files, manifest: manifest)
    }
}
