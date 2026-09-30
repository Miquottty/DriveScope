import DriveDomain
import DriveRecording
import DriveStorage
import SwiftUI
import UIKit

/// Recording HUD (portrait + landscape). Wires `RecordingController` into `RecordingHUD`.
struct RecordingView: View {
    @Environment(RecordingController.self) private var recorder
    @Environment(BatteryMonitor.self) private var battery
    @Environment(\.scenePhase) private var scenePhase
    /// Created on appear: an AVAudioEngine per view-struct init would be thrown away on every parent update.
    @State private var beeper: SyncBeeper?

    var body: some View {
        RecordingHUD(
            snapshot: recorder.live.snapshot,
            preset: recorder.session?.preset,
            isSaving: recorder.phase == .stopping || recorder.phase == .finalizing,
            onMark: { await recorder.mark(.mark) },
            onSync: {
                let tapped = Date()
                await recorder.sync(beep: beeper?.play(), pressedAt: tapped)
            },
            onStop: { await recorder.stop() },
            onRotateMount: { await recorder.rotateMount() },
            batteryLow: battery.isLow
        )
        .persistentSystemOverlays(.hidden)
        // The HUD is glanced at on a mount for hours; auto-lock would hide it mid-drive.
        .onAppear {
            UIApplication.shared.isIdleTimerDisabled = true
            if beeper == nil { beeper = SyncBeeper() }
            beeper?.prepare()
        }
        .onDisappear {
            UIApplication.shared.isIdleTimerDisabled = false
            beeper?.stop()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { beeper?.prepare() } else if phase == .background { beeper?.stop() }
        }
    }
}
