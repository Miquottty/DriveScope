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
            onHighlight: { await recorder.mark(.highlight) },
            onSync: {
                let tapped = Date()
                await recorder.sync(beep: await beeper?.play(), pressedAt: tapped)
            },
            onStop: { await recorder.stop() },
            onRotateMount: { await recorder.rotateMount() },
            batteryLow: battery.isLow
        )
        .persistentSystemOverlays(.hidden)
        // The HUD is glanced at on a mount for hours; auto-lock would hide it mid-drive.
        .onAppear {
            UIApplication.shared.isIdleTimerDisabled = true
            if beeper == nil { beeper = SyncBeeper.make() }
            Task { await beeper?.prepare() }
        }
        .onDisappear {
            UIApplication.shared.isIdleTimerDisabled = false
            Task { await beeper?.stop() }
        }
        .onChange(of: scenePhase) { _, phase in
            let beeper = beeper
            if phase == .active {
                Task { await beeper?.prepare() }
            } else if phase == .background {
                Task { await beeper?.stop() }
            }
        }
    }
}
