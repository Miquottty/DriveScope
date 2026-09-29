import DriveRecording
import Testing

struct RecordingWatchdogTests {
    /// GPS lost in a tunnel: searching → alert → notification, one step each; then recovery reports the gap.
    /// A suspension that jumps straight past every threshold still yields every stage (so the notification fires).
    @Test func escalatesStageByStageAndRecovers() {
        var dog = RecordingWatchdog()
        #expect(dog.evaluate(now: 0, lastLocation: 0, lastMotion: 0) == [.rearmDeadman])
        #expect(dog.evaluate(now: 10, lastLocation: 10, lastMotion: 10).isEmpty) // re-arm is throttled to 15 s
        #expect(dog.evaluate(now: 16, lastLocation: 10, lastMotion: 16) == [.rearmDeadman])
        #expect(dog.evaluate(now: 26, lastLocation: 10, lastMotion: 26) == [.escalated(.gps, .degraded, silence: 16)])
        #expect(dog.evaluate(now: 71, lastLocation: 10, lastMotion: 71) == [.escalated(.gps, .alerted, silence: 61), .rearmDeadman])
        #expect(dog.evaluate(now: 131, lastLocation: 10, lastMotion: 131) == [.escalated(.gps, .notified, silence: 121), .rearmDeadman])
        // While the process runs, the dead-man keeps being pushed back even in a long tunnel.
        #expect(dog.evaluate(now: 160, lastLocation: 10, lastMotion: 160) == [.rearmDeadman])
        #expect(dog.evaluate(now: 161, lastLocation: 161, lastMotion: 161) == [.recovered(.gps, gap: 150)])

        var suspended = RecordingWatchdog()
        _ = suspended.evaluate(now: 0, lastLocation: 0, lastMotion: 0)
        let actions = suspended.evaluate(now: 200, lastLocation: 0, lastMotion: 0)
        #expect(actions.contains(.escalated(.gps, .notified, silence: 200)))
        #expect(actions.contains(.escalated(.motion, .degraded, silence: 200)))
        #expect(actions.filter { if case .escalated = $0 { true } else { false } }.count == 6)
    }
}
