import DriveDomain
import Foundation

/// Reads `.bin` streams. Files are memory-mapped, so opening a multi-hour log is cheap (PLAN §4.1).
public enum StreamReader {
    /// Complete records in a stream, from the file size alone — this is the crash-recovery count
    /// `(fileSize - header) / recordSize`. Returns 0 when the file does not exist.
    public static func recordCount(at url: URL, kind: StreamKind) -> Int {
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > StreamHeader.size else { return 0 }
        return (size - StreamHeader.size) / kind.recordSize
    }

    public static func header(at url: URL) throws -> StreamHeader {
        let data = try Data(contentsOf: url, options: .alwaysMapped)
        return try data.withUnsafeBytes { try StreamHeader(decoding: $0) }
    }

    /// Decodes every complete record. A partial trailing record is ignored.
    public static func read<R: BinaryRecord>(_ type: R.Type, at url: URL, kind: StreamKind) throws -> [R] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        return try read(type, from: Data(contentsOf: url, options: .alwaysMapped), kind: kind)
    }

    /// Decodes every complete record of a stream's bytes (header included); empty data is an empty stream.
    public static func read<R: BinaryRecord>(_ type: R.Type, from data: Data, kind: StreamKind) throws -> [R] {
        guard !data.isEmpty else { return [] }
        return try data.withUnsafeBytes { buffer -> [R] in
            let header = try StreamHeader(decoding: buffer)
            guard header.kind == kind else { throw StreamFormatError.wrongStream(expected: kind, found: header.kind) }
            let count = (buffer.count - StreamHeader.size) / R.recordSize
            var records: [R] = []
            records.reserveCapacity(count)
            for i in 0..<count {
                records.append(R(decoding: buffer, at: StreamHeader.size + i * R.recordSize))
            }
            return records
        }
    }
}

extension SessionFiles {
    public func locations() throws -> [LocationSample] {
        try StreamReader.read(LocationSample.self, from: streamData(.location), kind: .location)
    }

    public func deviceMotion() throws -> [MotionSample] {
        try StreamReader.read(MotionSample.self, from: streamData(.motion), kind: .motion)
    }

    public func accelerations() throws -> [AccelSample] {
        try StreamReader.read(AccelSample.self, from: streamData(.accel), kind: .accel)
    }

    public func altitudes() throws -> [AltitudeSample] {
        try StreamReader.read(AltitudeSample.self, from: streamData(.altitude), kind: .altitude)
    }

    public func events() throws -> [EventRecord] {
        try StreamReader.read(EventRecord.self, from: streamData(.events), kind: .events)
    }
}
