import DriveDomain
import Foundation

#if canImport(Darwin)
import Darwin
#endif

/// One open `.bin` stream, appended with `write(2)` (PLAN §4.1). Not thread-safe; owned by `SampleWriter`.
final class StreamFile {
    let kind: StreamKind
    let url: URL
    private var fd: Int32
    /// Complete records on disk (after the last successful write).
    private(set) var recordCount: Int

    /// Opens (or creates) a stream for appending. An existing file is validated and any partial trailing
    /// record — left by a crash mid-write — is truncated so appends stay record-aligned.
    init(url: URL, kind: StreamKind, createdAt: Double) throws {
        self.kind = kind
        self.url = url
        fd = open(url.path, O_RDWR | O_CREAT, 0o644)
        guard fd >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }

        var info = stat()
        guard fstat(fd, &info) == 0 else { throw Self.closeAndError(fd) }
        let size = Int(info.st_size)

        if size >= StreamHeader.size {
            var headerBytes = [UInt8](repeating: 0, count: StreamHeader.size)
            guard pread(fd, &headerBytes, StreamHeader.size, 0) == StreamHeader.size else { throw Self.closeAndError(fd) }
            let header = try headerBytes.withUnsafeBytes { try StreamHeader(decoding: $0) }
            guard header.kind == kind else {
                Darwin.close(fd)
                throw StreamFormatError.wrongStream(expected: kind, found: header.kind)
            }
            recordCount = (size - StreamHeader.size) / kind.recordSize
            let aligned = StreamHeader.size + recordCount * kind.recordSize
            if aligned != size, ftruncate(fd, off_t(aligned)) != 0 { throw Self.closeAndError(fd) }
        } else {
            // Empty or torn header: start over.
            guard ftruncate(fd, 0) == 0 else { throw Self.closeAndError(fd) }
            recordCount = 0
            let header = StreamHeader(kind: kind, createdAt: createdAt).encoded()
            try Self.writeAll(fd, header)
        }
        guard lseek(fd, 0, SEEK_END) >= 0 else { throw Self.closeAndError(fd) }
    }

    deinit {
        if fd >= 0 { Darwin.close(fd) }
    }

    /// Appends whole records. `bytes.count` must be a multiple of the record size.
    func append(_ bytes: [UInt8]) throws {
        precondition(bytes.count % kind.recordSize == 0, "unaligned append")
        try Self.writeAll(fd, bytes)
        recordCount += bytes.count / kind.recordSize
    }

    func sync() throws {
        guard fsync(fd) == 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
    }

    func close() {
        if fd >= 0 { Darwin.close(fd) }
        fd = -1
    }

    private static func writeAll(_ fd: Int32, _ bytes: [UInt8]) throws {
        try bytes.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let n = write(fd, buffer.baseAddress! + offset, buffer.count - offset)
                if n < 0 {
                    if errno == EINTR { continue }
                    throw POSIXError(.init(rawValue: errno) ?? .EIO)
                }
                offset += n
            }
        }
    }

    private static func closeAndError(_ fd: Int32) -> POSIXError {
        let error = POSIXError(.init(rawValue: errno) ?? .EIO)
        Darwin.close(fd)
        return error
    }
}
