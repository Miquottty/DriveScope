import AVFoundation
import DriveRecording

/// The SYNC beep: three 2.5 kHz pips that the cameras and the DJI Mic record, so the editor aligns the audio to
/// the sample instead of hunting for a clap. The SYNC marker is the first pip's onset at the output, which is
/// scheduled on the audio clock rather than taken from the tap.
///
/// Pattern "chirp3-v1" (keep the editor's detector in step): 40 ms pips, gaps 120 ms then 200 ms — uneven, so
/// the pattern cannot line up with a copy of itself shifted by one pip.
@MainActor
final class SyncBeeper {
    static let frequency = 2_500.0
    static let pipDuration = 0.040
    static let pipOnsets: [TimeInterval] = [0, 0.160, 0.400]
    /// Head start for scheduling: the buffer must be queued before its host time or the pips play late.
    static let lead: TimeInterval = 0.1
    /// After a cold start the output needs longer before the first render.
    static let coldLead: TimeInterval = 0.3

    private static let sampleRate = 48_000.0
    /// Raised-cosine ramps so the pips don't click (a click is broadband and blurs the onset).
    private static let ramp = 0.005

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let buffer: AVAudioPCMBuffer?

    init() {
        buffer = Self.makeBuffer()
        engine.attach(player)
        if let buffer {
            engine.connect(player, to: engine.mainMixerNode, format: buffer.format)
        }
    }

    /// Starts the output while the HUD is on screen, so a tap only schedules the buffer.
    func prepare() {
        _ = startIfNeeded()
    }

    /// Releases the output (HUD gone or app in the background — without the audio background mode the system
    /// stops it anyway).
    func stop() {
        player.stop()
        engine.stop()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    /// Plays the pattern and returns when its first pip reaches the output, or nil when audio is unavailable
    /// (the SYNC then falls back to the tap time).
    func play() -> SyncBeep? {
        let wasRunning = engine.isRunning
        guard let buffer, startIfNeeded() else { return nil }
        let lead = wasRunning ? Self.lead : Self.coldLead
        let hostTime = mach_absolute_time() + AVAudioTime.hostTime(forSeconds: lead)
        player.scheduleBuffer(buffer, at: AVAudioTime(hostTime: hostTime))
        let session = AVAudioSession.sharedInstance()
        // Host time and `ProcessInfo.systemUptime` share mach_absolute_time, so the conversion is direct.
        let latency = session.outputLatency
        return SyncBeep(
            onsetUptime: AVAudioTime.seconds(forHostTime: hostTime) + latency,
            outputLatency: latency,
            route: Self.route(session.currentRoute)
        )
    }

    private func startIfNeeded() -> Bool {
        if engine.isRunning, player.isPlaying { return true }
        do {
            let session = AVAudioSession.sharedInstance()
            // `.playback` sounds with the ring switch on silent; mixing leaves the driver's music playing.
            try session.setCategory(.playback, options: [.mixWithOthers])
            try session.setActive(true)
            if !engine.isRunning { try engine.start() }
            player.play()
            return true
        } catch {
            return false
        }
    }

    private static func route(_ route: AVAudioSessionRouteDescription) -> SyncBeep.Route {
        switch route.outputs.first?.portType {
        case .builtInSpeaker?: .speaker
        case .bluetoothA2DP?, .bluetoothLE?, .bluetoothHFP?, .carAudio?, .airPlay?: .wireless
        default: .other
        }
    }

    private static func makeBuffer() -> AVAudioPCMBuffer? {
        let total = pipOnsets.last! + pipDuration
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(total * sampleRate)),
              let samples = buffer.floatChannelData?[0]
        else { return nil }
        buffer.frameLength = buffer.frameCapacity
        let count = Int(buffer.frameLength)
        for i in 0..<count { samples[i] = 0 }
        let pipFrames = Int(pipDuration * sampleRate)
        let rampFrames = Double(ramp * sampleRate)
        for onset in pipOnsets {
            let start = Int(onset * sampleRate)
            for j in 0..<pipFrames where start + j < count {
                let edge = Double(min(j, pipFrames - 1 - j))
                let gain = edge < rampFrames ? 0.5 - 0.5 * cos(.pi * edge / rampFrames) : 1
                samples[start + j] = Float(0.9 * gain * sin(2 * .pi * frequency * Double(j) / sampleRate))
            }
        }
        return buffer
    }
}
