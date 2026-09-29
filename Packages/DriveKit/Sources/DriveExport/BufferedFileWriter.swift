import Foundation

/// Appends UTF-8 text to a file through a 64 KB buffer so exporters can stream multi-hour sessions
/// without holding the output in memory (PLAN §18: samples never live whole in RAM).
public final class BufferedFileWriter {
    public static let bufferSize = 64 * 1024

    private var handle: FileHandle?
    private var buffer: [UInt8] = []

    /// Creates (or truncates) the file at `url`.
    public init(url: URL) throws {
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: url.path])
        }
        handle = try FileHandle(forWritingTo: url)
        buffer.reserveCapacity(Self.bufferSize + 4096)
    }

    public func write(_ text: String) throws {
        buffer.append(contentsOf: text.utf8)
        if buffer.count >= Self.bufferSize { try flush() }
    }

    /// Flushes and closes. Safe to call more than once.
    public func close() throws {
        guard let handle else { return }
        defer { self.handle = nil }
        try flush()
        try handle.close()
    }

    private func flush() throws {
        guard let handle, !buffer.isEmpty else { return }
        try handle.write(contentsOf: buffer)
        buffer.removeAll(keepingCapacity: true)
    }
}
