import CoreLocation
import DriveRecording
import DriveStorage
import OSLog

/// Robust mode (PLAN §9.5, V1.1; off by default, Settings → Recording). With Always permission, significant-change
/// monitoring runs while recording, so iOS relaunches the app in the background if the process dies mid-drive
/// (crash, memory pressure); that launch continues the session by itself (`RecordingController.autoResume`).
/// Whether a user force-quit also relaunches is for the real-car test to find out (PLAN §17).
@MainActor
final class RobustMode: NSObject, RecordingObserver {
    nonisolated static let defaultsKey = "robustMode"
    nonisolated static let log = Logger(subsystem: "com.miquottty.DriveScope", category: "RobustMode")

    /// The setting is on and Always is granted — only then is anything armed.
    nonisolated static var isActive: Bool {
        UserDefaults.standard.bool(forKey: defaultsKey) && CLLocationManager().authorizationStatus == .authorizedAlways
    }

    /// Also the delegate that receives the relaunch's location events (they carry nothing we use).
    private let manager = CLLocationManager()
    private var armed = false

    override init() {
        super.init()
        manager.delegate = self
    }

    func recordingDidStart(_ session: DriveSession, resumed: Bool) {
        guard Self.isActive, CLLocationManager.significantLocationChangeMonitoringAvailable() else { return }
        manager.startMonitoringSignificantLocationChanges()
        armed = true
        Self.log.info("armed (resumed: \(resumed))")
    }

    func recordingWatchdog(_ action: RecordingWatchdog.Action, session: DriveSession) {}

    func recordingDidStop(_ session: DriveSession) {
        disarm()
    }

    /// Nothing is recording: stop monitoring so iOS doesn't keep relaunching an idle app. Monitoring outlives the
    /// process, so this also runs at every launch that doesn't continue a session.
    func disarm() {
        manager.stopMonitoringSignificantLocationChanges()
        if armed { Self.log.info("disarmed") }
        armed = false
    }
}

extension RobustMode: CLLocationManagerDelegate {
    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {}
    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: any Error) {}
}
