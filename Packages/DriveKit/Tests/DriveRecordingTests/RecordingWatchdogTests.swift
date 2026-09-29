import DriveRecording
import Testing

struct RecordingWatchdogTests {
    /// GPS lost in a tunnel: searching → alert → notification, one step each; then recovery reports the gap.
    /// A suspension that jumps straight past every threshold still yields every stage (so the notification fires).
    @Test func escalatesStageByStageAndRecovers() {
        var dog = RecordingWatchdog()
        #expect(dog.evaluate(now: 0, lastLocation: 0, lastMotion: 0) == [.rearmDeadman])
        #expect(dog.evaluate(now: 16, lastLocation: 0, lastMotion: 16) == [.escalated(.gps, .degraded, silence: 16)])
        #expect(dog.evaluate(now: 61, lastLocation: 0, lastMotion: 61) == [.escalated(.gps, .alerted, silence: 61)])
        #expect(dog.evaluate(now: 121, lastLocation: 0, lastMotion: 121) == [.escalated(.gps, .notified, silence: 121)])
        // No re-arm while GPS is out: a suspended process must let the dead-man fire.
        #expect(dog.evaluate(now: 150, lastLocation: 0, lastMotion: 150).isEmpty)
        #expect(dog.evaluate(now: 151, lastLocation: 151, lastMotion: 151) == [.recovered(.gps, gap: 150), .rearmDeadman])

        var suspended = RecordingWatchdog()
        _ = suspended.evaluate(now: 0, lastLocation: 0, lastMotion: 0)
        let actions = suspended.evaluate(now: 200, lastLocation: 0, lastMotion: 0)
        #expect(actions.contains(.escalated(.gps, .notified, silence: 200)))
        #expect(actions.contains(.escalated(.motion, .degraded, silence: 200)))
        #expect(actions.filter { if case .escalated = $0 { true } else { false } }.count == 6)
    }
}
