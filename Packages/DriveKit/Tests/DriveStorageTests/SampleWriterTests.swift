import DriveDomain
import DriveStorage
import Foundation
import Synchronization
import Testing

struct SampleWriterTests {
    let files = SessionFiles(root: FileManager.default.temporaryDirectory.appending(path: "DriveScopeTests"), sessionID: UUID())

    func fix(_ i: Int) -> LocationSample {
        LocationSample(
            timestamp: 1_790_000_000 + Double(i), latitude: 36.4 + Double(i) * 1e-5, longitude: 139.1, altitude: 100,
            receivedUptime: Double(i), speed: 10, course: 90, horizontalAccuracy: 5, verticalAccuracy: 4,
            speedAccuracy: 0.5, courseAccuracy: 3
        )
    }

    /// A kill between flushes loses only the buffer; a torn trailing record is dropped on reopen and appends
    /// continue record-aligned.
    @Test func survivesKillAndTornWrite() async throws {
        defer { try? files.delete() }
        let writer = try SampleWriter(files: files, kinds: [.location, .events], createdAt: 0)
        for i in 0..<300 { await writer.append(fix(i), to: .location) }
        // Threshold flush happened at 256; the remaining 44 are only buffered. Simulate a kill: no close().
        #expect(StreamReader.recordCount(at: files.url(for: .location), kind: .location) == 256)

        // Torn write: half a record at the tail.
        let handle = try FileHandle(forWritingTo: files.url(for: .location))
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(repeating: 0xAB, count: 30))
        try handle.close()

        let resumed = try SampleWriter(files: files, kinds: [.location, .events], createdAt: 0)
        #expect(await resumed.recordCount(.location) == 256)
        for i in 256..<260 { await resumed.append(fix(i), to: .location) }
        await resumed.close()

        let read = try files.locations()
        #expect(read.count == 260)
        #expect(read.last == fix(259))
        #expect(read[255] == fix(255))
    }

    @Test func flushesQuietStreamsOnTime() async throws {
        defer { try? files.delete() }
        let clock = Mutex<TimeInterval>(0)
        let writer = try SampleWriter(files: files, kinds: [.events], createdAt: 0, uptime: { clock.withLock { $0 } })
        await writer.append(EventRecord(kind: .gpsLost, elapsed: 1), to: .events)
        await writer.flushIfDue()
        #expect(StreamReader.recordCount(at: files.url(for: .events), kind: .events) == 0)

        clock.withLock { $0 = 2.1 }
        await writer.flushIfDue()
        #expect(try files.events() == [EventRecord(kind: .gpsLost, elapsed: 1)])
    }
}
