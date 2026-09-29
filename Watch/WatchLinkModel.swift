import Foundation
import Observation
import WatchConnectivity

/// Watch side of the link (PLAN §19 W3): the iPhone's recording state, and MARK / STOP sent to it.
/// Commands are never queued for later — a MARK delivered late would land at the wrong moment of the drive.
@MainActor
@Observable
final class WatchLinkModel: NSObject {
    private(set) var state: WatchState?
    private(set) var isReachable = false
    /// Bumped on every acknowledged command / every failure: the haptics' triggers.
    private(set) var acknowledged = 0
    private(set) var failed = 0
    /// A MARK is on its way (the button shows it until the iPhone answers).
    private(set) var markInFlight = false

    override init() {
        super.init()
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        session.delegate = self
        session.activate()
    }

    func send(_ kind: WatchCommand.Kind) {
        let session = WCSession.default
        guard session.activationState == .activated, session.isReachable else {
            failed += 1
            return
        }
        let command = WatchCommand(id: UUID(), kind: kind, pressedAt: Date())
        if kind == .mark { markInFlight = true }
        let handlers = Self.handlers(for: kind, model: self)
        session.sendMessage(
            WatchCoding.encode(command, key: WatchCommand.key), replyHandler: handlers.reply, errorHandler: handlers.error
        )
    }

    /// WatchConnectivity calls these on its own queue. Made in a nonisolated context so they aren't inferred to be
    /// main-actor closures (which traps at runtime when called off the main actor).
    private nonisolated static func handlers(
        for kind: WatchCommand.Kind, model: WatchLinkModel
    ) -> (reply: @Sendable ([String: Any]) -> Void, error: @Sendable (any Error) -> Void) {
        (
            reply: { reply in
                let ack = WatchCoding.decode(WatchAck.self, key: WatchAck.key, from: reply)
                Task { @MainActor in model.finish(kind, ack: ack) }
            },
            error: { _ in
                Task { @MainActor in model.finish(kind, ack: nil) }
            }
        )
    }

    private func finish(_ kind: WatchCommand.Kind, ack: WatchAck?) {
        if kind == .mark { markInFlight = false }
        guard let ack, ack.accepted else {
            failed += 1
            return
        }
        acknowledged += 1
        if kind == .mark { state?.markCount = ack.markCount }
    }

    fileprivate func apply(_ state: WatchState?, reachable: Bool) {
        if let state { self.state = state }
        isReachable = reachable
    }
}

extension WatchLinkModel: WCSessionDelegate {
    nonisolated func session(_ session: WCSession, activationDidCompleteWith state: WCSessionActivationState, error: (any Error)?) {
        let context = WatchCoding.decode(WatchState.self, key: WatchState.key, from: session.receivedApplicationContext)
        let reachable = session.isReachable
        Task { @MainActor in self.apply(context, reachable: reachable) }
    }

    nonisolated func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        let state = WatchCoding.decode(WatchState.self, key: WatchState.key, from: applicationContext)
        let reachable = session.isReachable
        Task { @MainActor in self.apply(state, reachable: reachable) }
    }

    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        let state = WatchCoding.decode(WatchState.self, key: WatchState.key, from: message)
        let reachable = session.isReachable
        Task { @MainActor in self.apply(state, reachable: reachable) }
    }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        let reachable = session.isReachable
        Task { @MainActor in self.apply(nil, reachable: reachable) }
    }
}
