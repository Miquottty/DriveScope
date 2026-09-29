import CoreLocation
import DriveDomain
import DriveRecording
import Foundation

/// START from outside the Home button — the Apple Watch (PLAN §19 W3). It never shows a prompt, so it only starts
/// when what Home would ask for is already granted: robust mode (Always permission — recording may begin while the
/// iPhone app is in the background) and full accuracy. SYNC stays iPhone-only.
@MainActor
enum RemoteStart {
    static func isAvailable(recorder: RecordingController, environment: SensorEnvironment) -> Bool {
        guard recorder.phase == .idle || recorder.phase == .stopped else { return false }
        // Scripted drives need no location permission, only the setting.
        guard environment.needsLocationPermission else { return UserDefaults.standard.bool(forKey: RobustMode.defaultsKey) }
        return RobustMode.isActive && CLLocationManager().accuracyAuthorization == .fullAccuracy
    }

    /// Starts with the preset Home would use; false when START isn't available or didn't reach recording.
    static func start(recorder: RecordingController, environment: SensorEnvironment) async -> Bool {
        guard isAvailable(recorder: recorder, environment: environment) else { return false }
        let preset = CapturePreset(rawValue: UserDefaults.standard.string(forKey: "capturePreset") ?? "") ?? .default
        await recorder.start(preset: preset)
        return recorder.isRecording
    }
}
