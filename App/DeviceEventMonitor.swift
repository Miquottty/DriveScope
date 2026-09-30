import DriveDomain
import DriveRecording
import DriveStorage
import Foundation
import UIKit

/// Records app / device state changes into the session's events stream while recording (PLAN §9.4), and pushes
/// buffered samples to disk when the app leaves the foreground or is terminated (PLAN §4.1).
@MainActor
final class DeviceEventMonitor: RecordingObserver {
    private let recorder: RecordingController
    private var tokens: [any NSObjectProtocol] = []
    /// Last recorded screen state. iOS can post the protected-data notification twice for one unlock.
    private var screenOn: Bool?

    init(recorder: RecordingController) {
        self.recorder = recorder
    }

    func recordingDidStart(_ session: DriveSession, resumed: Bool) {
        guard tokens.isEmpty else { return }
        let center = NotificationCenter.default
        func observe(_ name: Notification.Name, _ handler: @escaping @MainActor () -> Void) {
            tokens.append(center.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { handler() }
            })
        }
        observe(UIApplication.didEnterBackgroundNotification) { [recorder] in
            Task {
                await recorder.record(.appDidEnterBackground)
                await recorder.flush()
            }
        }
        observe(UIApplication.willEnterForegroundNotification) { [recorder] in
            Task { await recorder.record(.appWillEnterForeground) }
        }
        observe(UIApplication.willTerminateNotification) { [recorder] in
            recorder.flushBeforeTermination()
        }
        // With a passcode, protected data goes away when the screen locks — the best available screen-off signal.
        observe(UIApplication.protectedDataWillBecomeUnavailableNotification) { [weak self] in
            self?.recordScreen(on: false)
        }
        observe(UIApplication.protectedDataDidBecomeAvailableNotification) { [weak self] in
            self?.recordScreen(on: true)
        }
        observe(ProcessInfo.thermalStateDidChangeNotification) { [recorder] in
            let state = ProcessInfo.processInfo.thermalState.rawValue
            Task { await recorder.record(.thermalStateChanged, aux: UInt32(state)) }
        }
        observe(Notification.Name.NSProcessInfoPowerStateDidChange) { [recorder] in
            let lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
            Task { await recorder.record(.lowPowerModeChanged, value: lowPower ? 1 : 0) }
        }
        // Initial values, so every session states its starting conditions.
        Task { [recorder] in
            await recorder.record(.thermalStateChanged, aux: UInt32(ProcessInfo.processInfo.thermalState.rawValue))
            await recorder.record(.lowPowerModeChanged, value: ProcessInfo.processInfo.isLowPowerModeEnabled ? 1 : 0)
        }
    }

    private func recordScreen(on: Bool) {
        guard screenOn != on else { return }
        screenOn = on
        Task { [recorder] in await recorder.record(on ? .screenOn : .screenOff) }
    }

    func recordingWatchdog(_ action: RecordingWatchdog.Action, session: DriveSession) {}

    func recordingDidStop(_ session: DriveSession) {
        for token in tokens { NotificationCenter.default.removeObserver(token) }
        tokens.removeAll()
        screenOn = nil
    }
}
