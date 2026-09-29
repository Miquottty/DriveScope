import CoreLocation
import Observation

/// Location authorization state for the UI (Home status card, START gating). PLAN §2.1 / §9.1:
/// While Using is enough because START happens in the foreground; full accuracy is required before recording.
@MainActor
@Observable
final class LocationPermission: NSObject, CLLocationManagerDelegate {
    private(set) var authorizationStatus: CLAuthorizationStatus
    private(set) var accuracy: CLAccuracyAuthorization

    private let manager: CLLocationManager
    @ObservationIgnored private var statusWaiters: [CheckedContinuation<Void, Never>] = []

    override init() {
        let manager = CLLocationManager()
        self.manager = manager
        authorizationStatus = manager.authorizationStatus
        accuracy = manager.accuracyAuthorization
        super.init()
        manager.delegate = self
    }

    var isPrecise: Bool { accuracy == .fullAccuracy }

    var canRecord: Bool {
        authorizationStatus == .authorizedWhenInUse || authorizationStatus == .authorizedAlways
    }

    /// `UIBackgroundModes` declares `location`, so recording continues with the screen off.
    var backgroundAvailable: Bool {
        let modes = Bundle.main.object(forInfoDictionaryKey: "UIBackgroundModes") as? [String]
        return modes?.contains("location") ?? false
    }

    /// Shows the system prompt when undetermined and returns once the user has answered.
    @discardableResult
    func requestWhenInUse() async -> CLAuthorizationStatus {
        guard authorizationStatus == .notDetermined else { return authorizationStatus }
        manager.requestWhenInUseAuthorization()
        await withCheckedContinuation { statusWaiters.append($0) }
        return authorizationStatus
    }

    /// When the user granted only approximate location, asks for temporary full accuracy for this session.
    func ensureFullAccuracy() async -> Bool {
        guard canRecord else { return false }
        if accuracy == .reducedAccuracy {
            try? await manager.requestTemporaryFullAccuracyAuthorization(withPurposeKey: "DriveTelemetry")
            refresh()
        }
        return isPrecise
    }

    private func refresh() {
        authorizationStatus = manager.authorizationStatus
        accuracy = manager.accuracyAuthorization
        guard authorizationStatus != .notDetermined else { return }
        let waiters = statusWaiters
        statusWaiters = []
        for waiter in waiters { waiter.resume() }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in self.refresh() }
    }
}
