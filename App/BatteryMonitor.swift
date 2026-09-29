import DriveDomain
import DriveRecording
import DriveStorage
import Foundation
import Observation
import UIKit

/// Battery state for the UI (PLAN §2.2.1 low-battery suggestion) and `batterySnapshot` events every 5 minutes
/// while recording (PLAN §9.4), from which %/h is computed.
@MainActor
@Observable
final class BatteryMonitor: RecordingObserver {
    static let snapshotInterval: TimeInterval = 5 * 60
    /// Below this, unplugged, suggest Eco / GPS Only.
    static let lowThreshold: Float = 0.20

    /// 0…1, nil when unknown (simulator).
    private(set) var level: Float?
    private(set) var state: UIDevice.BatteryState = .unknown

    @ObservationIgnored private let recorder: RecordingController
    @ObservationIgnored private var snapshotTask: Task<Void, Never>?
    @ObservationIgnored private var tokens: [any NSObjectProtocol] = []
    @ObservationIgnored private var suggestedThisSession = false

    init(recorder: RecordingController) {
        self.recorder = recorder
        UIDevice.current.isBatteryMonitoringEnabled = true
        refresh()
        for name in [UIDevice.batteryLevelDidChangeNotification, UIDevice.batteryStateDidChangeNotification] {
            tokens.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            })
        }
    }

    var isCharging: Bool { state == .charging || state == .full }

    /// PLAN §2.2.1: < 20 % and not charging → suggest (never switch automatically).
    var isLow: Bool { (level ?? 1) < Self.lowThreshold && !isCharging }

    private func refresh() {
        let device = UIDevice.current
        level = device.batteryLevel >= 0 ? device.batteryLevel : nil
        state = device.batteryState
        if recorder.isRecording, isLow, !suggestedThisSession {
            suggestedThisSession = true
            Task { await recorder.record(.batteryLowSuggested, value: Double(level ?? -1)) }
        }
    }

    // MARK: RecordingObserver

    func recordingDidStart(_ session: DriveSession, resumed: Bool) {
        suggestedThisSession = false
        snapshotTask?.cancel()
        snapshotTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.snapshot()
                try? await Task.sleep(for: .seconds(Self.snapshotInterval))
            }
        }
    }

    func recordingWatchdog(_ action: RecordingWatchdog.Action, session: DriveSession) {}

    func recordingDidStop(_ session: DriveSession) {
        snapshotTask?.cancel()
        snapshotTask = nil
    }

    /// Also called right before STOP so the last interval counts.
    func snapshot() async {
        refresh()
        await recorder.record(.batterySnapshot, value: Double(level ?? -1), aux: UInt32(state.rawValue))
    }
}
