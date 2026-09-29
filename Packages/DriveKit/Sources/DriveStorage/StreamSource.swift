import DriveDomain
import Foundation

/// The one way to read a finished session's streams (V1.1). A stream is either the raw `.bin` the writer appended
/// to, or — once the session is archived — its LZFSE copy (`SessionArchiver`); only this extension knows which.
/// The raw file wins while both exist (an archive run that didn't finish).
/// Recording and recovery keep using the raw file directly (`StreamReader.recordCount(at:)`, `SampleWriter`).
extension SessionFiles {
    /// Header + records exactly as the writer produced them: memory-mapped when raw, decompressed when archived.
    /// Empty when the stream doesn't exist.
    public func streamData(_ kind: StreamKind) throws -> Data {
        let raw = url(for: kind)
        if FileManager.default.fileExists(atPath: raw.path) {
            return try Data(contentsOf: raw, options: .alwaysMapped)
        }
        let archive = archiveURL(for: kind)
        guard FileManager.default.fileExists(atPath: archive.path) else { return Data() }
        return try SessionArchiver.decompress(archive)
    }

    /// Complete records in a stream; 0 when it doesn't exist. Reads only the archive header when archived.
    public func recordCount(_ kind: StreamKind) -> Int {
        let raw = url(for: kind)
        if FileManager.default.fileExists(atPath: raw.path) { return StreamReader.recordCount(at: raw, kind: kind) }
        guard let size = try? SessionArchiver.rawSize(of: archiveURL(for: kind)), size > StreamHeader.size else { return 0 }
        return (size - StreamHeader.size) / kind.recordSize
    }

    /// Bytes of the session in raw form — what export sizes scale with, however the streams are stored.
    public func rawByteSize() -> Int {
        let fm = FileManager.default
        var total = (try? manifestURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        for name in SessionArchiver.streamFileNames {
            let raw = directory.appending(path: name)
            if let size = try? raw.resourceValues(forKeys: [.fileSizeKey]).fileSize {
                total += size
            } else if fm.fileExists(atPath: SessionArchiver.archiveURL(for: raw).path) {
                total += (try? SessionArchiver.rawSize(of: SessionArchiver.archiveURL(for: raw))) ?? 0
            }
        }
        return total
    }

    /// Every stream is stored compressed (no raw file left).
    public var isArchived: Bool {
        let fm = FileManager.default
        let names = SessionArchiver.streamFileNames
        return names.contains { fm.fileExists(atPath: SessionArchiver.archiveURL(for: directory.appending(path: $0)).path) }
            && !names.contains { fm.fileExists(atPath: directory.appending(path: $0).path) }
    }

    public func archiveURL(for kind: StreamKind) -> URL {
        SessionArchiver.archiveURL(for: url(for: kind))
    }
}
