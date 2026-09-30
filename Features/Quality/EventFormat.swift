import DriveDomain
import SwiftUI

/// Names and payload text for `events.bin` records (PLAN §9.4).
struct EventFormat {
    let language: AppLanguage

    private var format: SessionFormat { SessionFormat(language: language) }

    func name(_ kind: EventKind) -> LocalizedStringKey {
        switch kind {
        case .unknown: "Unknown event"
        case .gpsLost: "GPS lost"
        case .gpsResumed: "GPS resumed"
        case .motionStalled: "Motion stalled"
        case .motionResumed: "Motion resumed"
        case .appDidEnterBackground: "Entered background"
        case .appWillEnterForeground: "Returning to foreground"
        case .watchdogFired: "Watchdog fired"
        case .resumedFromNotification: "Resumed from notification"
        case .calibrationUpdated: "Calibration updated"
        case .thermalStateChanged: "Thermal state changed"
        case .lowPowerModeChanged: "Low Power Mode changed"
        case .carPlayConnected: "CarPlay connected"
        case .carPlayDisconnected: "CarPlay disconnected"
        case .screenOn: "Screen on"
        case .screenOff: "Screen off"
        case .batterySnapshot: "Battery"
        case .batteryLowSuggested: "Low battery suggested"
        case .marker: "Marker"
        case .sessionResumed: "Session resumed"
        case .autoResumed: "Auto-resumed"
        case .mountChanged: "Mount changed"
        }
    }

    /// The payload in the unit its kind uses; empty when the kind carries none. `includingSource: false` leaves
    /// a marker's source out, for tables that show it in a column of its own.
    func value(_ event: EventRecord, includingSource: Bool = true) -> String {
        switch event.kind {
        case .gpsLost, .gpsResumed, .motionStalled, .motionResumed, .sessionResumed, .autoResumed:
            return format.seconds(event.value).text
        case .watchdogFired:
            // aux: 0 = GPS, 1 = motion.
            let stream = event.aux == 0 ? "GPS" : language.string("Motion")
            return "\(stream) · \(format.seconds(event.value).text)"
        case .batterySnapshot:
            let level = event.value >= 0 ? "\(Int((event.value * 100).rounded()))%" : "—"
            return [level, batteryState(event.aux)].compactMap { $0 }.joined(separator: " · ")
        case .marker:
            // aux: 0 = MARK, 1 = SYNC.
            let kind = event.aux == 1 ? "SYNC" : "MARK"
            return includingSource ? "\(kind) · \(source(event.source))" : kind
        case .thermalStateChanged:
            return thermalState(Int(event.aux))
        case .lowPowerModeChanged:
            // Recorded in `value` (1 = on), unlike the thermal state's `aux`.
            return event.value == 0 ? language.string("Off") : language.string("On")
        default:
            return ""
        }
    }

    /// `ProcessInfo.ThermalState` raw value.
    func thermalState(_ raw: Int) -> String {
        switch raw {
        case 0: language.string("Nominal")
        case 1: language.string("Fair")
        case 2: language.string("Serious")
        default: language.string("Critical")
        }
    }

    /// `UIDevice.BatteryState` raw value; nil when unknown.
    private func batteryState(_ raw: UInt32) -> String? {
        switch raw {
        case 1: language.string("Unplugged")
        case 2: language.string("Charging")
        case 3: language.string("Full")
        default: nil
        }
    }

    func source(_ source: EventSource) -> String {
        switch source {
        case .phone: language.string("Phone")
        case .liveActivity: language.string("Live Activity")
        case .watch: language.string("Watch")
        case .system: language.string("System")
        }
    }
}
