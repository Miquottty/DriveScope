// Activity is not Sendable, but its update / end are safe to call from the main actor.
@preconcurrency import ActivityKit
import DriveDomain
import DriveRecording
import DriveStorage
import Foundation
import OSLog
import UIKit

/// Drives the recording's Live Activity (PLAN §10): starts it with the session, pushes the HUD snapshot every
/// `preset.liveActivityInterval` seconds when something visible changed, reflects the watchdog (GPS searching,
/// alert at stage `.alerted`) and ends it on STOP.
@MainActor
final class LiveActivityController: RecordingObserver {
    private typealias State = DriveActivityAttributes.ContentState

    nonisolated static let log = Logger(subsystem: "com.miquottty.DriveScope", category: "LiveActivity")

    /// Without an update for this long the activity is marked stale (the app is probably suspended).
    private static let staleAfter: TimeInterval = 30

    private let recorder: RecordingController
    /// The in-app language is read on every update so a change in Settings reaches the activity.
    private let language: () -> AppLanguage
    private var activity: Activity<DriveActivityAttributes>?
    private var updates: Task<Void, Never>?
    private var lastState: State?
    private var lastPush = Date.distantPast
    private var timerStart = Date()
    private var gpsDegraded = false
    private var terminateObserver: (any NSObjectProtocol)?
    private var foregroundObserver: (any NSObjectProtocol)?

    init(recorder: RecordingController, language: @escaping () -> AppLanguage = { AppLanguage() }) {
        self.recorder = recorder
        self.language = language
        Self.current = self
    }

    // MARK: - MARK from the activity

    /// The one controller of the app process, reached by the intents.
    private static weak var current: LiveActivityController?
    private static var lastIntentMark = Date.distantPast
    /// Each press from the Watch reached `MarkIntent` twice, 0–0.1 s apart (events.bin of a device session, iOS 27.2).
    private static let intentMarkDebounce: TimeInterval = 0.5

    /// Whether a MARK from the activity is a new press rather than the duplicate delivery of the previous one.
    static func acceptIntentMark() -> Bool {
        let now = Date()
        guard now.timeIntervalSince(lastIntentMark) >= intentMarkDebounce else { return false }
        lastIntentMark = now
        return true
    }

    /// Shows the new MARK count now instead of at the next 2–5 s update — the Watch has no other feedback.
    static func markAdded() async {
        await current?.push(force: true)
    }

    // MARK: - RecordingObserver

    func recordingDidStart(_ session: DriveSession, resumed: Bool) {
        gpsDegraded = false
        lastState = nil
        lastPush = .distantPast
        timerStart = session.startedAt
        // Robust mode's background relaunch keeps the dead process's activity for the session it continues
        // (`endLeftoversAtLaunch(keeping:)`): adopt it, since a new one can't be requested from the background.
        // Everything else still around belongs to a process that is gone.
        let existing = Activity<DriveActivityAttributes>.activities
        let adopted = resumed
            ? existing.first { $0.attributes.sessionID == session.id && ($0.activityState == .active || $0.activityState == .stale) }
            : nil
        for leftover in existing where leftover.id != adopted?.id {
            Task { await leftover.end(nil, dismissalPolicy: .immediate) }
        }
        if let adopted {
            activity = adopted
            Task { await push(force: true) }
        } else if !requestActivity(for: session) {
            return
        }
        startUpdates(interval: session.preset.liveActivityInterval)
        terminateObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.willTerminateNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.endBeforeTermination() }
        }
    }

    /// false when there is no activity to update. Requesting fails in the background (robust mode relaunch without
    /// a leftover to adopt): then it is requested again when the app next comes to the foreground.
    private func requestActivity(for session: DriveSession) -> Bool {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            Self.log.info("Live Activities are disabled")
            return false
        }
        let state = makeState()
        let attributes = DriveActivityAttributes(
            sessionID: session.id, startedAt: session.startedAt, preset: session.preset.rawValue
        )
        do {
            activity = try Activity.request(attributes: attributes, content: content(state), pushType: nil)
            lastState = state
            lastPush = Date()
            return true
        } catch {
            Self.log.error("Activity.request failed: \(String(describing: error), privacy: .public)")
            guard UIApplication.shared.applicationState == .background, foregroundObserver == nil else { return false }
            foregroundObserver = NotificationCenter.default.addObserver(
                forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.retryRequest() }
            }
            // The update loop still runs so the request can be retried with the current state.
            return true
        }
    }

    private func retryRequest() {
        if let foregroundObserver { NotificationCenter.default.removeObserver(foregroundObserver) }
        foregroundObserver = nil
        guard activity == nil, let session = recorder.session, recorder.isRecording else { return }
        _ = requestActivity(for: session)
    }

    func recordingWatchdog(_ action: RecordingWatchdog.Action, session: DriveSession) {
        switch action {
        case .escalated(.gps, .degraded, _):
            gpsDegraded = true
            Task { await push(force: true) }
        case .escalated(let stream, .alerted, _):
            let lang = language()
            let alert = switch stream {
            case .gps:
                AlertConfiguration(
                    title: Self.resolved(lang.string("GPS signal lost")),
                    body: Self.resolved(lang.string("No GPS fix for a while. Recording continues.")),
                    sound: .default
                )
            case .motion:
                AlertConfiguration(
                    title: Self.resolved(lang.string("Motion sensor stalled")),
                    body: Self.resolved(lang.string("No motion data for a while. Recording continues.")),
                    sound: .default
                )
            }
            Task { await push(alert: alert) }
        case .recovered(.gps, _):
            gpsDegraded = false
            Task { await push(force: true) }
        default:
            break
        }
    }

    func recordingDidStop(_ session: DriveSession) {
        updates?.cancel()
        updates = nil
        removeTerminateObserver()
        if let foregroundObserver { NotificationCenter.default.removeObserver(foregroundObserver) }
        foregroundObserver = nil
        guard let activity else { return }
        self.activity = nil
        var state = makeState(session: session)
        state.status = .saved
        state.elapsed = session.duration
        state.distanceKm = session.distance / 1000
        state.speedKmh = nil
        Task {
            await activity.end(ActivityContent(state: state, staleDate: nil), dismissalPolicy: .after(.now + 60))
        }
    }

    // MARK: - Leftovers

    /// iOS keeps a Live Activity after its process dies (force quit, crash, jetsam). A new process never owns a
    /// running recording, so every activity it finds is a leftover: ended at launch, and by MARK / STOP pressed on
    /// one while nothing records. (After a force quit iOS does not launch the app for those intents at all — seen on
    /// iOS 27.2 — hence the widget turns STOP into an open-app link once the activity goes stale.)
    static func endLeftovers() async {
        await end(Activity<DriveActivityAttributes>.activities)
    }

    /// At launch the list is taken synchronously, before anything can start a recording, so a session resumed while
    /// the leftovers are still being ended keeps its new activity. `keeping`: sessions robust mode is about to
    /// continue — their activity is adopted instead.
    static func endLeftoversAtLaunch(keeping: Set<UUID> = []) {
        let leftovers = Activity<DriveActivityAttributes>.activities.filter { !keeping.contains($0.attributes.sessionID) }
        guard !leftovers.isEmpty else { return }
        Task { await end(leftovers) }
    }

    private static func end(_ activities: [Activity<DriveActivityAttributes>]) async {
        for activity in activities where activity.activityState == .active || activity.activityState == .stale {
            log.info("Ending leftover activity \(activity.id, privacy: .public)")
            await activity.end(nil, dismissalPolicy: .immediate)
        }
    }

    /// Best effort on force quit while running in the background: the app gets a moment in `willTerminate`, so the
    /// activity goes away with it. Not guaranteed (a suspended app is killed without notice) — the widget's
    /// interrupted look and `endLeftovers` at the next launch cover that.
    private func endBeforeTermination(timeout: TimeInterval = 1) {
        updates?.cancel()
        updates = nil
        removeTerminateObserver()
        guard let activity else { return }
        self.activity = nil
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            await activity.end(nil, dismissalPolicy: .immediate)
            done.signal()
        }
        _ = done.wait(timeout: .now() + timeout)
    }

    private func removeTerminateObserver() {
        if let terminateObserver { NotificationCenter.default.removeObserver(terminateObserver) }
        terminateObserver = nil
    }

    // MARK: - Updates

    private func startUpdates(interval: TimeInterval) {
        updates?.cancel()
        updates = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(interval))
                guard !Task.isCancelled, let self else { return }
                await self.push()
            }
        }
    }

    /// Pushes the current state when something visible changed, an alert is due, or the stale date is near.
    private func push(alert: AlertConfiguration? = nil, force: Bool = false) async {
        guard let activity else { return }
        let state = makeState()
        let now = Date()
        let changed = lastState.map { !state.looksSame(as: $0) } ?? true
        guard force || alert != nil || changed || now.timeIntervalSince(lastPush) > Self.staleAfter / 2 else { return }
        lastState = state
        lastPush = now
        await activity.update(content(state), alertConfiguration: alert)
    }

    private func content(_ state: State) -> ActivityContent<State> {
        ActivityContent(state: state, staleDate: Date().addingTimeInterval(Self.staleAfter))
    }

    private func makeState(session: DriveSession? = nil) -> State {
        let snapshot = recorder.live.snapshot
        // Follow the recorded clock only when it drifts from the wall clock (scripted drives run faster than real
        // time; the uptime clock pauses while the device sleeps). Re-deriving it every update would make the
        // ticking clock jitter by a second.
        let derivedStart = Date().addingTimeInterval(-snapshot.elapsed)
        if abs(derivedStart.timeIntervalSince(timerStart)) > 2 { timerStart = derivedStart }
        let status: State.Status = switch recorder.phase {
        case .stopping, .finalizing: .saving
        default: gpsDegraded || snapshot.gpsStatus == .searching ? .gpsSearching : .recording
        }
        // Rounded to what the widget shows, so "changed" means visibly changed.
        return State(
            timerStart: timerStart,
            elapsed: snapshot.elapsed.rounded(),
            speedKmh: snapshot.speed.map { Units.kmh(fromMetersPerSecond: max(0, $0)).rounded() },
            distanceKm: (snapshot.distance / 100).rounded() / 10,
            // Before the satellite lock the fixes are Wi‑Fi ones (±40 m): not an accuracy worth showing.
            gpsAccuracyM: snapshot.gpsStatus == .good ? snapshot.horizontalAccuracy.map { $0.rounded() } : nil,
            lateralG: (snapshot.lateralG * 100).rounded() / 100,
            status: status,
            languageCode: language().languageCode,
            // MARKs only, like the watch: the badge is on the MARK button; SYNC is not counted.
            markCount: (session ?? recorder.session)?.markers.filter { $0.kind == .mark }.count ?? 0
        )
    }

    /// Alert text is resolved in the in-app language up front: a `LocalizedStringResource` would be looked up by
    /// the system in the OS language. An already-translated key is not in the catalog and so displays as is.
    private static func resolved(_ text: String) -> LocalizedStringResource {
        LocalizedStringResource(stringLiteral: text)
    }
}

private extension DriveActivityAttributes.ContentState {
    /// Equal apart from the elapsed seconds, which the widget's own timer shows.
    func looksSame(as other: Self) -> Bool {
        var a = self
        a.elapsed = other.elapsed
        return a == other
    }
}
