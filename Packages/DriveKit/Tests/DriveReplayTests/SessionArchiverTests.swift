import DriveDomain
import DriveRecording
import DriveReplay
import DriveSensors
import DriveStorage
import Foundation
import Testing

struct SessionArchiverTests {
    /// Everything a reader sees, so "archived" can be compared with "raw".
    private struct Snapshot: Equatable {
        var locations: [LocationSample]
        var motion: [MotionSample]
        var altitudes: [AltitudeSample]
        var events: [EventRecord]
        var counts: [Int]
        var frames: [ReplayTelemetryFrame]
        var quality: [Double]

        init(_ files: SessionFiles) throws {
            let reader = try TelemetryReader(files: files)
            locations = Array(reader.locations)
            motion = Array(reader.motion)
            altitudes = Array(reader.altitudes)
            events = reader.events
            #expect(try files.locations() == locations)
            counts = StreamKind.allCases.map { files.recordCount($0) }
            let interpolator = TelemetryInterpolator(reader: reader)
            frames = [5.5, 47.25, 101].map { interpolator.frame(at: $0) }
            let report = try QualityReport.make(files: files)
            quality = [
                Double(report.location.count), Double(report.motion.count), report.motion.span, report.motionDropRate ?? -1,
                report.accuracyP50, Double(report.altitude.count), Double(report.events.count),
            ]
        }
    }

    /// V1.1 LZFSE archive: lossless for every reader (Replay, export, statistics, Quality), smaller on disk,
    /// and the raw size still known for export estimates.
    @Test func archivedSessionReadsExactlyLikeRaw() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "DriveScopeArchive-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let built = try await ScriptedSessionBuilder.write(script: .akagi, preset: .logger, duration: 120, root: root)
        let files = SessionFiles(root: root, sessionID: built.manifest.sessionID)
        let before = try Snapshot(files)
        let diskBefore = files.byteSize(), rawBefore = files.rawByteSize()

        try SessionArchiver.archive(files)

        #expect(files.isArchived)
        #expect(!FileManager.default.fileExists(atPath: files.url(for: .motion).path))
        #expect(try files.readManifest().archivedAt != nil)
        #expect(files.byteSize() < diskBefore / 2, "\(files.byteSize()) vs \(diskBefore)")
        #expect(files.rawByteSize() >= rawBefore) // the manifest grew by `archivedAt`
        #expect(try Snapshot(files) == before)
    }

    /// Interrupted runs never lose data: archives written but raw files kept → the raw files are read; a junk
    /// temporary file and a truncated archive are cleaned up by the next run, which then finishes. An archived
    /// session can't be appended to.
    @Test func interruptedArchiveIsRepairedWithoutLoss() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "DriveScopeArchive-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let built = try await ScriptedSessionBuilder.write(script: .akagi, preset: .logger, duration: 60, root: root)
        let files = SessionFiles(root: root, sessionID: built.manifest.sessionID)
        let raw = try [StreamKind.location, .motion, .altitude, .events].map { try Data(contentsOf: files.url(for: $0)) }

        try SessionArchiver.archive(files, stopAfter: .archivesWritten)
        #expect(FileManager.default.fileExists(atPath: files.archiveURL(for: .motion).path))
        #expect(!files.isArchived)
        #expect(try files.streamData(.motion) == raw[1])

        try Data("junk".utf8).write(to: files.archiveURL(for: .location).appendingPathExtension("tmp"))
        let motionArchive = try Data(contentsOf: files.archiveURL(for: .motion))
        try motionArchive.prefix(motionArchive.count / 2).write(to: files.archiveURL(for: .motion))

        try SessionArchiver.archive(files)
        #expect(files.isArchived)
        let contents = try FileManager.default.contentsOfDirectory(atPath: files.directory.path)
        #expect(!contents.contains { $0.hasSuffix(".tmp") })
        #expect(try [StreamKind.location, .motion, .altitude, .events].map { try files.streamData($0) } == raw)

        #expect(throws: StreamFormatError.archived) {
            _ = try SampleWriter(files: files, kinds: [.location], createdAt: 0)
        }
    }
}
