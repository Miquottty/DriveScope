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
    /// Recover finalizes it from the files; resume appends to the same files and logs `sessionResumed`.
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
        try await Task.sleep(for: .seconds(2.5))
        let accepted = first.live.snapshot.locationCount
        await first.simulateKill()
        let files = SessionFiles(root: root, sessionID: id)
        let onDisk = StreamReader.recordCount(at: files.url(for: .location), kind: .location)
        // The flush policy bounds the loss to ~2 s of real time (here ×60 in script time) plus one tick.
        #expect(onDisk > 60 && onDisk <= accepted && accepted - onDisk <= 180)

        // Relaunch: resume appends to the same files.
        let second = controller()
        let unfinished = try #require(second.unfinishedSessions().first)
        #expect(unfinished.id == id && second.canResume(unfinished))
        await second.resume(unfinished)
        #expect(second.phase == .recording)
        try await Task.sleep(for: .seconds(1))
        await second.stop()
        #expect(try files.locations().count > onDisk)
        #expect(try files.events().contains { $0.kind == .sessionResumed })

        // A second unfinished session is recovered from its files.
        let third = controller()
        await third.start(preset: .gpsOnly)
        let otherID = try #require(third.session?.id)
        try await Task.sleep(for: .seconds(2.5))
        await third.simulateKill()
        let fourth = controller()
        let other = try #require(fourth.unfinishedSessions().first { $0.id == otherID })
        await fourth.recover(other)
        #expect(other.state == .recovered)
        #expect(other.locationSampleCount > 60 && other.distance > 0 && other.duration > 60)
    }
}
