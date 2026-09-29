import AppIntents
import Foundation
#if !WIDGET_EXTENSION
import DriveDomain
import DriveRecording
import OSLog
#endif

// MARK / STOP buttons of the Live Activity (PLAN §10). The widget extension compiles these types only so that
// `Button(intent:)` can reference them; `LiveActivityIntent.perform()` runs in the app process, where the recorder
// lives (`allowedExecutionTargets = .main` makes that explicit). The widget does not link DriveKit, hence the
// no-op bodies under `WIDGET_EXTENSION`.

struct MarkIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Add Marker"
    static let isDiscoverable = false
    static let allowedExecutionTargets: IntentExecutionTargets = .main

    #if !WIDGET_EXTENSION
    @Dependency private var recorder: RecordingController
    #endif

    init() {}

    func perform() async throws -> some IntentResult {
        #if !WIDGET_EXTENSION
        LiveActivityController.log.info("MARK from Live Activity")
        if await recorder.isRecording {
            guard await LiveActivityController.acceptIntentMark() else { return .result() }
            // Watch Double Tap also lands here; the intent cannot tell the two apart, so both record `.liveActivity`.
            await recorder.mark(.mark, source: .liveActivity)
            await LiveActivityController.markAdded()
        } else {
            // Pressed on an activity left by a crashed / jetsammed process (a force-quit app is not launched for
            // intents). Awaited: a background launch may be suspended as soon as perform() returns.
            await LiveActivityController.endLeftovers()
        }
        #endif
        return .result()
    }
}

struct StopRecordingIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Stop Recording"
    static let isDiscoverable = false
    static let allowedExecutionTargets: IntentExecutionTargets = .main

    #if !WIDGET_EXTENSION
    @Dependency private var recorder: RecordingController
    #endif

    init() {}

    func perform() async throws -> some IntentResult {
        #if !WIDGET_EXTENSION
        LiveActivityController.log.info("STOP from Live Activity")
        if await recorder.isRecording {
            await recorder.stop()
        } else {
            // A leftover activity (see MarkIntent); the unfinished session itself is offered for recovery at launch.
            await LiveActivityController.endLeftovers()
        }
        #endif
        return .result()
    }
}
