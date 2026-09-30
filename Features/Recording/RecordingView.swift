import DriveDomain
import DriveRecording
import DriveStorage
import SwiftUI
import UIKit

/// Recording HUD (portrait + landscape). Wires `RecordingController` into `RecordingHUD`.
struct RecordingView: View {
    @Environment(RecordingController.self) private var recorder
    @Environment(BatteryMonitor.self) private var battery

    var body: some View {
        RecordingHUD(
            snapshot: recorder.live.snapshot,
            preset: recorder.session?.preset,
            isSaving: recorder.phase == .stopping || recorder.phase == .finalizing,
            onMark: { await recorder.mark(.mark) },
            onHighlight: { await recorder.mark(.highlight) },
            onSync: { await recorder.mark(.sync) },
            onStop: { await recorder.stop() },
            onRotateMount: { await recorder.rotateMount() },
            batteryLow: battery.isLow
        )
        .persistentSystemOverlays(.hidden)
        // The HUD is glanced at on a mount for hours; auto-lock would hide it mid-drive.
        .onAppear { UIApplication.shared.isIdleTimerDisabled = true }
        .onDisappear { UIApplication.shared.isIdleTimerDisabled = false }
    }
}
