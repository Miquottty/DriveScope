import DriveDomain
import DriveRecording
import DriveStorage
import Foundation
import UserNotifications

/// Watchdog notifications (PLAN §9.3).
/// - Stage 1: an immediate notification when GPS / motion has been silent for `notify` seconds.
/// - Stage 2 (dead-man switch): a notification scheduled `deadman` seconds ahead and pushed back while GPS is
///   healthy. If the process is suspended or killed, nobody pushes it back and iOS delivers it on its own.
///   Tapping it relaunches the app, which resumes the unfinished session.
@MainActor
final class RecordingNotifications: NSObject, RecordingObserver, UNUserNotificationCenterDelegate {
    nonisolated static let deadmanID = "recording.deadman"
    private static let silenceID = "recording.silence"

    private let center = UNUserNotificationCenter.current()
    private let recorder: RecordingController

    init(recorder: RecordingController) {
        self.recorder = recorder
        super.init()
        center.delegate = self
    }

    // MARK: RecordingObserver

    func recordingDidStart(_ session: DriveSession, resumed: Bool) {
        armDeadman()
    }

    func recordingWatchdog(_ action: RecordingWatchdog.Action, session: DriveSession) {
        switch action {
        case .rearmDeadman:
            armDeadman()
        case .escalated(let stream, .notified, let silence):
            notifySilence(stream, minutes: Int(silence / 60))
        case .recovered:
            center.removeDeliveredNotifications(withIdentifiers: [Self.silenceID])
        default:
            break
        }
    }

    func recordingDidStop(_ session: DriveSession) {
        center.removePendingNotificationRequests(withIdentifiers: [Self.deadmanID])
        center.removeDeliveredNotifications(withIdentifiers: [Self.deadmanID, Self.silenceID])
    }

    // MARK: Scheduling

    static func requestAuthorizationIfNeeded() async {
        let center = UNUserNotificationCenter.current()
        guard await center.notificationSettings().authorizationStatus == .notDetermined else { return }
        _ = try? await center.requestAuthorization(options: [.alert, .sound, .badge])
    }

    /// Re-adding a request with the same identifier replaces it, which pushes the trigger back.
    private func armDeadman() {
        let language = AppLanguage()
        let content = UNMutableNotificationContent()
        content.title = language.string("Recording may have stopped")
        content.body = language.string("DriveScope hasn't received data for a while. Tap to resume recording.")
        content.sound = .default
        content.interruptionLevel = .timeSensitive
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: max(recorder.watchdogPolicy.deadman, 1), repeats: false)
        center.add(UNNotificationRequest(identifier: Self.deadmanID, content: content, trigger: trigger))
    }

    private func notifySilence(_ stream: RecordingWatchdog.Stream, minutes: Int) {
        let language = AppLanguage()
        let content = UNMutableNotificationContent()
        switch stream {
        case .gps:
            content.title = language.string("GPS signal lost")
            content.body = language.string("No GPS for \(max(minutes, 1)) min. Recording continues.")
        case .motion:
            content.title = language.string("Motion sensor stalled")
            content.body = language.string("No motion data for \(max(minutes, 1)) min. Recording continues.")
        }
        content.sound = .default
        content.interruptionLevel = .timeSensitive
        center.add(UNNotificationRequest(identifier: Self.silenceID, content: content, trigger: nil))
    }

    // MARK: UNUserNotificationCenterDelegate

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    /// Dead-man tap: continue the unfinished session in the same files (PLAN §9.3).
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        guard response.notification.request.identifier == Self.deadmanID else { return }
        _ = await MainActor.run {
            Task { await self.resumeAfterDeadman() }
        }
    }

    private func resumeAfterDeadman() async {
        guard !recorder.isRecording, let unfinished = recorder.unfinishedSessions().first, recorder.canResume(unfinished) else { return }
        await recorder.resume(unfinished)
        await recorder.record(.resumedFromNotification, source: .system)
    }
}
