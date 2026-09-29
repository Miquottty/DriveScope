import DriveDomain
import DriveRecording
import DriveStorage
import Foundation
import OSLog
import WatchConnectivity

/// iPhone side of the Apple Watch companion (PLAN §19 W3): publishes the recording state to the watch and runs the
/// watch's MARK / STOP. SYNC never comes from the watch — the link delay (100–500 ms, uneven) is too coarse for
/// video sync.
@MainActor
final class WatchLink: NSObject, RecordingObserver {
    nonisolated static let log = Logger(subsystem: "com.miquottty.DriveScope", category: "Watch")

    private let recorder: RecordingController
    private let environment: SensorEnvironment
    private let language: () -> AppLanguage
    private var session: WCSession?
    private var ticker: Task<Void, Never>?
    /// Ids of the last commands run: one press delivered twice is run once.
    private var recentCommands: [UUID] = []
    private var timerStart = Date()

    init(
        recorder: RecordingController, environment: SensorEnvironment,
        language: @escaping () -> AppLanguage = { AppLanguage() }
    ) {
        self.recorder = recorder
        self.environment = environment
        self.language = language
        super.init()
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        session.delegate = self
        session.activate()
        self.session = session
    }

    // MARK: - RecordingObserver

    func recordingDidStart(_ session: DriveSession, resumed: Bool) {
        timerStart = Date().addingTimeInterval(-recorder.live.snapshot.elapsed)
        publishContext()
        ticker?.cancel()
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                self?.publishLive()
            }
        }
    }

    func recordingWatchdog(_ action: RecordingWatchdog.Action, session: DriveSession) {}

    func recordingDidStop(_ session: DriveSession) {
        ticker?.cancel()
        ticker = nil
        publishContext()
    }

    // MARK: - State

    private func makeState() -> WatchState {
        let snapshot = recorder.live.snapshot
        let phase: WatchState.Phase = switch recorder.phase {
        case .recording: .recording
        case .stopping, .finalizing: .saving
        default: .idle
        }
        // Same clock rule as the Live Activity: follow the recorded elapsed only when it drifts.
        let derivedStart = Date().addingTimeInterval(-snapshot.elapsed)
        if phase == .recording, abs(derivedStart.timeIntervalSince(timerStart)) > 2 { timerStart = derivedStart }
        return WatchState(
            phase: phase,
            timerStart: timerStart,
            speedKmh: snapshot.speed.map { Units.kmh(fromMetersPerSecond: max(0, $0)).rounded() },
            markCount: recorder.session?.markers.count ?? 0,
            gpsSearching: snapshot.gpsStatus == .searching,
            canStart: RemoteStart.isAvailable(recorder: recorder, environment: environment),
            languageCode: language().languageCode
        )
    }

    private var watchReady: WCSession? {
        guard let session, session.activationState == .activated, session.isPaired, session.isWatchAppInstalled else { return nil }
        return session
    }

    /// Phase changes: the application context reaches the watch even when its app isn't running.
    private func publishContext() {
        guard let session = watchReady else { return }
        let message = WatchCoding.encode(makeState(), key: WatchState.key)
        do {
            try session.updateApplicationContext(message)
        } catch {
            Self.log.error("updateApplicationContext: \(String(describing: error), privacy: .public)")
        }
        if session.isReachable { session.sendMessage(message, replyHandler: nil, errorHandler: nil) }
    }

    /// While recording: speed and marks at 1 Hz, only when the watch app is in front (reachable).
    private func publishLive() {
        guard let session = watchReady, session.isReachable else { return }
        session.sendMessage(WatchCoding.encode(makeState(), key: WatchState.key), replyHandler: nil, errorHandler: nil)
    }

    // MARK: - Commands

    private func handle(_ command: WatchCommand) async -> WatchAck {
        func ack(_ accepted: Bool) -> WatchAck {
            WatchAck(id: command.id, accepted: accepted, markCount: recorder.session?.markers.count ?? 0)
        }
        guard !recentCommands.contains(command.id) else { return ack(true) }
        recentCommands.append(command.id)
        if recentCommands.count > 16 { recentCommands.removeFirst() }
        Self.log.info("\(command.kind.rawValue, privacy: .public) from watch")
        switch command.kind {
        case .mark:
            guard recorder.isRecording else { return ack(false) }
            await recorder.mark(.mark, source: .watch, pressedAt: command.pressedAt)
            await LiveActivityController.markAdded()
            publishLive()
            return ack(true)
        case .stop:
            guard recorder.isRecording else { return ack(false) }
            // Answer first: finalizing takes a moment and the watch is waiting for its haptic.
            Task { await recorder.stop() }
            return ack(true)
        case .start:
            // Needs robust mode (Always permission): the iPhone app may be in the background.
            return ack(await RemoteStart.start(recorder: recorder, environment: environment))
        }
    }
}

/// WatchConnectivity calls back on its own queue; everything hops to the main actor.
extension WatchLink: WCSessionDelegate {
    nonisolated func session(_ session: WCSession, activationDidCompleteWith state: WCSessionActivationState, error: (any Error)?) {
        Task { @MainActor in self.publishContext() }
    }

    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}

    /// The user switched to another watch: activate again for it.
    nonisolated func sessionDidDeactivate(_ session: WCSession) {
        session.activate()
    }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        Task { @MainActor in self.publishLive() }
    }

    nonisolated func session(
        _ session: WCSession, didReceiveMessage message: [String: Any], replyHandler: @escaping ([String: Any]) -> Void
    ) {
        guard let command = WatchCoding.decode(WatchCommand.self, key: WatchCommand.key, from: message) else {
            replyHandler([:])
            return
        }
        let reply = WatchReply(send: replyHandler)
        Task { @MainActor in
            let ack = await self.handle(command)
            reply.send(WatchCoding.encode(ack, key: WatchAck.key))
        }
    }
}

/// WatchConnectivity's reply handler, carried to the main actor and called once.
private nonisolated struct WatchReply: @unchecked Sendable {
    let send: ([String: Any]) -> Void
}
