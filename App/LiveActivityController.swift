// Activity is not Sendable, but its update / end are safe to call from the main actor.
@preconcurrency import ActivityKit
import DriveDomain
import DriveRecording
import DriveStorage
import Foundation
import OSLog

/// Drives the recording's Live Activity (PLAN §10): starts it with the session, pushes the HUD snapshot every
/// `preset.liveActivityInterval` seconds when something visible changed, reflects the watchdog (GPS searching,
/// alert at stage `.alerted`) and ends it on STOP.
@MainActor
final class LiveActivityController: RecordingObserver {
    private typealias State = DriveActivityAttributes.ContentState

    nonisolated static let log = Logger(subsystem: "com.miquottty.DriveScope", category: "LiveActivity")

    /// Without an update for this long the activity is marked stale (the app is probably suspended).
    private static let staleAfter: TimeInterval = 60

    private let recorder: RecordingController
    /// The in-app language is read on every update so a change in Settings reaches the activity.
    private let language: () -> AppLanguage
    private var activity: Activity<DriveActivityAttributes>?
    private var updates: Task<Void, Never>?
    private var lastState: State?
    private var lastPush = Date.distantPast
    private var timerStart = Date()
    private var gpsDegraded = false

    init(recorder: RecordingController, language: @escaping () -> AppLanguage = { AppLanguage() }) {
        self.recorder = recorder
        self.language = language
    }

    // MARK: - RecordingObserver

    func recordingDidStart(_ session: DriveSession, resumed: Bool) {
        gpsDegraded = false
        lastState = nil
        lastPush = .distantPast
        timerStart = session.startedAt
        let state = makeState()
        let existing = Activity<DriveActivityAttributes>.activities
        // A resumed session keeps the activity that survived the process; anything else is stale.
        let adopted = resumed ? existing.first { $0.attributes.sessionID == session.id } : nil
        for stale in existing where stale.id != adopted?.id {
            Task { await stale.end(nil, dismissalPolicy: .immediate) }
        }
        if let adopted {
            activity = adopted
            Task { await push(force: true) }
        } else {
            guard ActivityAuthorizationInfo().areActivitiesEnabled else {
                Self.log.info("Live Activities are disabled")
                return
            }
            let attributes = DriveActivityAttributes(
                sessionID: session.id, startedAt: session.startedAt, preset: session.preset.rawValue
            )
            do {
                activity = try Activity.request(
                    attributes: attributes, content: content(state), pushType: nil
                )
                lastState = state
                lastPush = Date()
            } catch {
                Self.log.error("Activity.request failed: \(String(describing: error), privacy: .public)")
                return
            }
        }
        startUpdates(interval: session.preset.liveActivityInterval)
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
            gpsAccuracyM: snapshot.horizontalAccuracy.map { $0.rounded() },
            lateralG: (snapshot.lateralG * 100).rounded() / 100,
            status: status,
            languageCode: language().languageCode,
            markCount: (session ?? recorder.session)?.markers.count ?? 0
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
