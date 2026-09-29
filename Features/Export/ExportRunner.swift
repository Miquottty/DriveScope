import DriveExport
import DriveStorage
import Foundation

/// A finished export in the temporary Exports folder.
nonisolated struct ExportedFile: Sendable, Equatable {
    var url: URL
    var bytes: Int

    var name: String { url.lastPathComponent }
}

/// Rough output sizes shown before exporting. Per-record byte counts come from measured exports.
nonisolated struct ExportEstimate: Sendable {
    /// Total size of the session's `.bin` files; nil until read.
    var binaryBytes: Int?
    var duration: TimeInterval
    var locationFixCount: Int

    func bytes(for kind: ExportKind) -> Int? {
        switch kind {
        case .json: binaryBytes.map { Int(Double($0) * 2.5) }
        case .csv30: Int(115 * duration * 30)
        case .csv10: Int(115 * duration * 10)
        case .gpx: 190 * locationFixCount
        }
    }
}

/// File-system side of the Export screen. Every entry point runs on the global executor (`@concurrent`):
/// a multi-hour session is hundreds of thousands of rows.
nonisolated enum ExportRunner {
    static var directory: URL {
        FileManager.default.temporaryDirectory.appending(path: "Exports", directoryHint: .isDirectory)
    }

    /// Drops exports from earlier visits (the share sheet copies files out, so nothing depends on them) and
    /// returns the session's binary size for the JSON estimate.
    @concurrent
    static func prepare(files: SessionFiles) async -> Int {
        try? FileManager.default.removeItem(at: directory)
        return files.byteSize()
    }

    @concurrent
    static func run(_ kind: ExportKind, files: SessionFiles, metadata: ExportMetadata) async throws -> ExportedFile {
        let url = try SessionExporter.export(kind, files: files, metadata: metadata, into: directory)
        let bytes = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        return ExportedFile(url: url, bytes: bytes)
    }
}
