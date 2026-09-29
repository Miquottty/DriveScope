import DriveDomain
import DriveRecording
import DriveSensors
import DriveStorage
import Foundation
import SwiftData
import Testing

@MainActor
struct RecoveryTests {
    /// A process killed mid-recording leaves a `.recording` session whose files hold everything flushed.
    /// Recover finalizes it from the files; resume (here robust mode's automatic one) appends to the same files and
    /// logs `sessionResumed` + `autoResumed`.
    @Test func recoverAndResumeFromKilledSession() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "DriveScopeRecovery-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let container = try SessionStore.makeContainer(inMemory: true)
        func controller() -> RecordingController {
            RecordingController(
                store: SessionStore(context: container.mainContext), filesRoot: root,
                environment: AppEnvironment(appVersion: "t", deviceModel: "t", osVersion: "t"),
                makeSuite: { ScriptPlayback.suite(script: .akagi, rate: 60, label: "test") }
            )
        }

        // Run 1: record, then kill — only what was flushed survives.
        let first = controller()
        await first.start(preset: .eco)
        let id = try #require(first.session?.id)
        try await waitUntil { StreamReader.recordCount(at: SessionFiles(root: root, sessionID: id).url(for: .location), kind: .location) > 60 }
        let accepted = first.live.snapshot.locationCount
        await first.simulateKill()
        let files = SessionFiles(root: root, sessionID: id)
        let onDisk = StreamReader.recordCount(at: files.url(for: .location), kind: .location)
        // The flush policy bounds the loss to ~2 s of real time (here ×60 in script time) plus one tick.
        // (`accepted` is the throttled HUD count, so it may lag the disk slightly.)
        #expect(onDisk > 60 && accepted - onDisk <= 180)

        // Relaunch in the background (robust mode): the newest unfinished session continues in the same files.
        let second = controller()
        let unfinished = try #require(second.unfinishedSessions().first)
        #expect(unfinished.id == id && second.canResume(unfinished))
        #expect(await second.autoResume())
        #expect(second.phase == .recording && second.session?.id == id)
        try await Task.sleep(for: .seconds(1))
        await second.stop()
        #expect(try files.locations().count > onDisk)
        let events = try files.events()
        #expect(events.contains { $0.kind == .sessionResumed } && events.contains { $0.kind == .autoResumed })

        // A second unfinished session is recovered from its files.
        let third = controller()
        await third.start(preset: .gpsOnly)
        let otherID = try #require(third.session?.id)
        // Wait for flushed data rather than a fixed time: CI runners are slower than a dev Mac.
        let otherFiles = SessionFiles(root: root, sessionID: otherID)
        try await waitUntil { StreamReader.recordCount(at: otherFiles.url(for: .location), kind: .location) > 60 }
        await third.simulateKill()
        let fourth = controller()
        let other = try #require(fourth.unfinishedSessions().first { $0.id == otherID })
        await fourth.recover(other)
        #expect(other.state == .recovered)
        #expect(other.locationSampleCount > 60 && other.distance > 0 && other.duration > 60)
    }

    /// Robust mode only continues a session from the same boot and within 30 min of its last sample (wall clock:
    /// the uptime clock pauses while the device sleeps, so it can't measure the gap).
    @Test func resumeDecisionNeedsSameBootAndRecentData() {
        let started = Date(timeIntervalSince1970: 1_790_000_000)
        func decide(nowUptime: TimeInterval, minutesAfterLastSample: Double) -> Bool {
            RecordingController.resumeDecision(
                startUptime: 5_000, nowUptime: nowUptime, startedAt: started, lastElapsed: 3_600,
                now: started.addingTimeInterval(3_600 + minutesAfterLastSample * 60)
            )
        }
        #expect(decide(nowUptime: 9_000, minutesAfterLastSample: 2))
        #expect(decide(nowUptime: 5_100, minutesAfterLastSample: 29)) // uptime barely moved: the device slept
        #expect(!decide(nowUptime: 120, minutesAfterLastSample: 2)) // rebooted
        #expect(!decide(nowUptime: 9_000, minutesAfterLastSample: 31))
    }

    /// Polls every 100 ms; fails after `timeout` seconds.
    private func waitUntil(timeout: TimeInterval = 20, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else {
                Issue.record("condition not met within \(timeout) s")
                return
            }
            try await Task.sleep(for: .milliseconds(100))
        }
    }
}
