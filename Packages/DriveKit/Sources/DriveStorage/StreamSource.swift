import DriveDomain
import Foundation

/// The one way to read a finished session's streams (V1.1). Today a stream is the raw `.bin` the writer appended
/// to; once sessions can be archived (compressed) it may be stored differently, and only this extension will know.
/// Recording and recovery keep using the raw file directly (`StreamReader.recordCount(at:)`, `SampleWriter`).
extension SessionFiles {
    /// Header + records exactly as the writer produced them, memory-mapped. Empty when the stream doesn't exist.
    public func streamData(_ kind: StreamKind) throws -> Data {
        let raw = url(for: kind)
        guard FileManager.default.fileExists(atPath: raw.path) else { return Data() }
        return try Data(contentsOf: raw, options: .alwaysMapped)
    }

    /// Complete records in a stream; 0 when it doesn't exist.
    public func recordCount(_ kind: StreamKind) -> Int {
        StreamReader.recordCount(at: url(for: kind), kind: kind)
    }

    /// Bytes of the streams in their raw form — what export sizes scale with, however the session is stored.
    public func rawByteSize() -> Int {
        byteSize()
    }
}
