import DriveDomain
import Foundation

/// Battery drain in %/h from `batterySnapshot` events (PLAN §2.2.2, Test E), split by screen state.
/// Only intervals between two non-charging snapshots count; unknown levels (simulator: -1) are skipped.
public struct BatteryUsage: Sendable, Equatable {
    public var overall: Double?
    public var screenOn: Double?
    public var screenOff: Double?

    /// `UIDevice.BatteryState.unplugged` raw value, stored in the snapshot's `aux`.
    public static let unpluggedState: UInt32 = 1

    public init(overall: Double? = nil, screenOn: Double? = nil, screenOff: Double? = nil) {
        self.overall = overall
        self.screenOn = screenOn
        self.screenOff = screenOff
    }

    public init(events: [EventRecord]) {
        var screenIsOn = true
        var previous: EventRecord?
        var drop = (on: 0.0, off: 0.0), time = (on: 0.0, off: 0.0)
        for event in events.sorted(by: { $0.elapsed < $1.elapsed }) {
            switch event.kind {
            case .screenOn, .appWillEnterForeground:
                screenIsOn = true
            case .screenOff, .appDidEnterBackground:
                screenIsOn = false
            case .batterySnapshot:
                let usable = event.value >= 0 && event.aux == Self.unpluggedState
                if usable, let p = previous {
                    let dt = event.elapsed - p.elapsed
                    let dl = (p.value - event.value) * 100
                    // An interval is attributed to the screen state at its end; snapshots are 5 min apart.
                    if dt > 0, dl >= 0 {
                        if screenIsOn { drop.on += dl; time.on += dt } else { drop.off += dl; time.off += dt }
                    }
                }
                previous = usable ? event : nil
            default:
                break
            }
        }
        func rate(_ d: Double, _ t: Double) -> Double? { t >= 600 ? d / t * 3600 : nil }
        overall = rate(drop.on + drop.off, time.on + time.off)
        screenOn = rate(drop.on, time.on)
        screenOff = rate(drop.off, time.off)
    }
}
