import DriveDomain
import Foundation

/// Buffers samples in memory and appends them to the session's `.bin` streams (PLAN §4.1).
///
/// Durability policy: buffers are written with `write(2)` every `flushInterval` seconds or once any stream holds
/// `flushThreshold` records, and `fsync`ed every `syncInterval`. A process kill therefore loses at most the last
/// flush interval; `write(2)` data survives an app crash even before `fsync` (it is in the kernel).
public actor SampleWriter {
    public struct Policy: Sendable {
        public var flushInterval: TimeInterval = 2
        public var flushThreshold = 256
        public var syncInterval: TimeInterval = 10

        public init() {}
    }

    private final class Stream {
        let file: StreamFile
        var buffer: [UInt8] = []
        var pending = 0

        init(file: StreamFile) {
            self.file = file
        }
    }

    private let policy: Policy
    private let uptime: @Sendable () -> TimeInterval
    private var streams: [StreamKind: Stream] = [:]
    private var lastFlush: TimeInterval
    private var lastSync: TimeInterval
    private var isClosed = false

    /// The most recent I/O failure (e.g. disk full). Appends keep buffering; the next flush retries.
    public private(set) var lastError: (any Error)?

    /// Opens every stream for appending. Existing files (a resumed or recovered session) are continued.
    public init(
        files: SessionFiles,
        kinds: [StreamKind],
        createdAt: Double,
        policy: Policy = Policy(),
        uptime: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    ) throws {
        try files.createDirectory()
        self.policy = policy
        self.uptime = uptime
        let now = uptime()
        lastFlush = now
        lastSync = now
        for kind in kinds {
            let file = try StreamFile(url: files.url(for: kind), kind: kind, createdAt: createdAt)
            streams[kind] = Stream(file: file)
        }
    }

    public func append<R: BinaryRecord>(_ record: R, to kind: StreamKind) {
        guard !isClosed, let stream = streams[kind] else { return }
        precondition(R.recordSize == kind.recordSize, "record type does not match stream \(kind)")
        let start = stream.buffer.count
        stream.buffer.append(contentsOf: repeatElement(0, count: R.recordSize))
        stream.buffer.withUnsafeMutableBytes { record.encode(into: $0, at: start) }
        stream.pending += 1
        if stream.pending >= policy.flushThreshold || uptime() - lastFlush >= policy.flushInterval {
            flush()
        }
    }

    /// Called periodically so quiet streams (e.g. GPS lost) still reach disk on time.
    public func flushIfDue() {
        let now = uptime()
        if now - lastFlush >= policy.flushInterval { flush() }
        if now - lastSync >= policy.syncInterval { sync() }
    }

    /// Writes all buffered records. With `sync`, also `fsync`s every stream.
    public func flush(sync shouldSync: Bool = false) {
        guard !isClosed else { return }
        lastFlush = uptime()
        for stream in streams.values where !stream.buffer.isEmpty {
            do {
                try stream.file.append(stream.buffer)
                stream.buffer.removeAll(keepingCapacity: true)
                stream.pending = 0
            } catch {
                lastError = error
            }
        }
        if shouldSync { sync() }
    }

    private func sync() {
        lastSync = uptime()
        for stream in streams.values {
            do { try stream.file.sync() } catch { lastError = error }
        }
    }

    /// Flushes, syncs and closes every stream. Further appends are ignored.
    public func close() {
        guard !isClosed else { return }
        flush(sync: true)
        for stream in streams.values { stream.file.close() }
        isClosed = true
    }

    /// Records accepted for `kind` (on disk + buffered).
    public func recordCount(_ kind: StreamKind) -> Int {
        guard let stream = streams[kind] else { return 0 }
        return stream.file.recordCount + stream.pending
    }
}
