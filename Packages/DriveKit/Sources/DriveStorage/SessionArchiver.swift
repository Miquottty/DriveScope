#if canImport(Accelerate)
import Accelerate
#endif
#if canImport(Android)
import Android
#endif
import DriveDomain
import Foundation

/// LZFSE archive of a finished session's streams (PLAN §4.4, V1.1). Each `<name>.bin` becomes
/// `<name>.bin.lzfse`: a 16-byte header (magic "DSLZ", version, raw size) and the whole raw file — its own
/// 32-byte header included — byte-shuffled, then compressed with LZFSE. Lossless: readers get back exactly the
/// bytes the writer produced, through `SessionFiles.streamData(_:)`.
///
/// Byte shuffle: the records are stored as planes (byte 0 of every record, then byte 1, …; within a plane the
/// records run last to first, as vImage's 90° rotation lays them out). Sensor floats barely compress as they are
/// (real 50 Hz motion: 82–88 % of raw with LZFSE alone); in planes the sign / exponent bytes line up and it drops
/// to 57–68 %. vImage keeps the transpose fast in Debug builds too (a Swift loop took 2 s for a 2-hour log).
///
/// Crash safety: an archive is written to a temporary file, verified, synced and renamed; the raw file is deleted
/// only after every archive is durable and the manifest records `archivedAt`. The raw file always wins while
/// both exist, and `repair` finishes or undoes an interrupted run.
public enum SessionArchiver {
    public static let fileExtension = "lzfse"
    static let magic: UInt32 = 0x4453_4C5A // "DSLZ"
    static let version: UInt32 = 1
    static let headerSize = 16

    public enum ArchiveError: Error, Equatable {
        case badArchive
        case verificationFailed
        /// LZFSE and vImage are Apple-only; Android never archives (and gets iOS sessions raw).
        case unsupportedPlatform
    }

    /// Tests only: stop after a step to leave the files as a crash would.
    package enum Step: Sendable {
        case archivesWritten
    }

    /// Compresses every raw stream of the session. The caller guarantees nothing is writing to it
    /// (only stopped / recovered sessions are archived).
    public static func archive(_ files: SessionFiles) throws {
        try archive(files, stopAfter: nil)
    }

    package static func archive(_ files: SessionFiles, stopAfter step: Step?) throws {
        try repair(files)
        let fm = FileManager.default
        let raws = Self.streamFileNames.map { files.directory.appending(path: $0) }.filter { fm.fileExists(atPath: $0.path) }
        guard !raws.isEmpty else { return }
        for raw in raws {
            try writeArchive(of: raw, to: archiveURL(for: raw))
        }
        if step == .archivesWritten { return }
        try syncDirectory(files.directory)
        var manifest = try files.readManifest()
        manifest.archivedAt = Date()
        try files.writeManifest(manifest)
        for raw in raws {
            try fm.removeItem(at: raw)
        }
    }

    /// Cleans up after an interrupted `archive`: leftover temporary files go, and an archive that sits next to its
    /// raw file (the run stopped before deleting raw files) is kept only if it still matches the raw file.
    public static func repair(_ files: SessionFiles) throws {
        let fm = FileManager.default
        let contents = (try? fm.contentsOfDirectory(at: files.directory, includingPropertiesForKeys: nil)) ?? []
        for url in contents where url.pathExtension == "tmp" {
            try fm.removeItem(at: url)
        }
        for name in streamFileNames {
            let raw = files.directory.appending(path: name)
            let archive = archiveURL(for: raw)
            guard fm.fileExists(atPath: raw.path), fm.fileExists(atPath: archive.path) else { continue }
            let matches = (try? decompress(archive)) == (try Data(contentsOf: raw, options: .alwaysMapped))
            if !matches { try fm.removeItem(at: archive) }
        }
    }

    /// The raw bytes of an archived stream, checked against the size recorded in its header.
    public static func decompress(_ url: URL) throws -> Data {
        let data = try Data(contentsOf: url, options: .alwaysMapped)
        let rawSize = try header(of: data)
        let body = data.subdata(in: headerSize..<data.count)
        #if canImport(Accelerate)
        guard let shuffled = try? (body as NSData).decompressed(using: .lzfse) as Data, shuffled.count == rawSize else {
            throw ArchiveError.badArchive
        }
        return try reorder(shuffled, toPlanes: false)
        #else
        _ = (body, rawSize)
        throw ArchiveError.unsupportedPlatform
        #endif
    }

    /// Raw size recorded in an archive's header (reads 16 bytes).
    public static func rawSize(of url: URL) throws -> Int {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        return try header(of: handle.readData(ofLength: headerSize))
    }

    static func archiveURL(for raw: URL) -> URL {
        raw.appendingPathExtension(fileExtension)
    }

    /// Distinct stream files (`motion.bin` holds either motion kind).
    static var streamFileNames: [String] {
        var seen = Set<String>()
        return StreamKind.allCases.map(\.fileName).filter { seen.insert($0).inserted }
    }

    private static func header(of data: Data) throws -> Int {
        guard data.count >= headerSize else { throw ArchiveError.badArchive }
        return try data.withUnsafeBytes { buffer in
            var r = RecordReader(buffer, at: 0)
            guard r.get(UInt32.self) == magic, r.get(UInt32.self) == version else { throw ArchiveError.badArchive }
            return Int(r.get(UInt64.self))
        }
    }

    private static func writeArchive(of raw: URL, to archive: URL) throws {
        let bytes = try Data(contentsOf: raw, options: .alwaysMapped)
        #if canImport(Accelerate)
        let compressed = try (reorder(bytes, toPlanes: true) as NSData).compressed(using: .lzfse) as Data
        #else
        let compressed = Data()
        throw ArchiveError.unsupportedPlatform
        #endif
        var header = Data(count: headerSize)
        header.withUnsafeMutableBytes { buffer in
            var w = RecordWriter(buffer, at: 0)
            w.put(magic)
            w.put(version)
            w.put(UInt64(bytes.count))
        }
        let temporary = archive.appendingPathExtension("tmp")
        try (header + compressed).write(to: temporary)
        // Verify what is on disk, not what is in memory, before it replaces anything.
        guard try decompress(temporary) == bytes else {
            try? FileManager.default.removeItem(at: temporary)
            throw ArchiveError.verificationFailed
        }
        let handle = try FileHandle(forWritingTo: temporary)
        try handle.synchronize()
        try handle.close()
        if FileManager.default.fileExists(atPath: archive.path) { try FileManager.default.removeItem(at: archive) }
        try FileManager.default.moveItem(at: temporary, to: archive)
    }

    #if canImport(Accelerate)
    /// Records ⇄ byte planes. The stream's own header (which gives the record size) and a torn trailing record
    /// stay as they are.
    private static func reorder(_ data: Data, toPlanes: Bool) throws -> Data {
        guard data.count > StreamHeader.size else { return data }
        let recordSize = try data.withUnsafeBytes { try StreamHeader(decoding: $0).recordSize }
        guard recordSize > 1 else { return data }
        let count = (data.count - StreamHeader.size) / recordSize
        guard count > 0 else { return data }
        var out = data
        let error = data.withUnsafeBytes { (source: UnsafeRawBufferPointer) -> vImage_Error in
            out.withUnsafeMutableBytes { (target: UnsafeMutableRawBufferPointer) -> vImage_Error in
                // Records as an image: one row per record, one Planar8 pixel per byte. Planes are that image turned
                // 90° clockwise (one row per byte position); turning back counter-clockwise restores it exactly.
                let records = (height: vImagePixelCount(count), width: vImagePixelCount(recordSize), rowBytes: recordSize)
                let planes = (height: vImagePixelCount(recordSize), width: vImagePixelCount(count), rowBytes: count)
                let from = toPlanes ? records : planes, to = toPlanes ? planes : records
                var src = vImage_Buffer(
                    data: UnsafeMutableRawPointer(mutating: source.baseAddress!.advanced(by: StreamHeader.size)),
                    height: from.height, width: from.width, rowBytes: from.rowBytes
                )
                var dst = vImage_Buffer(
                    data: target.baseAddress!.advanced(by: StreamHeader.size),
                    height: to.height, width: to.width, rowBytes: to.rowBytes
                )
                let rotation = UInt8(toPlanes ? kRotate90DegreesClockwise : kRotate90DegreesCounterClockwise)
                return vImageRotate90_Planar8(&src, &dst, rotation, 0, vImage_Flags(kvImageNoFlags))
            }
        }
        guard error == kvImageNoError else { throw ArchiveError.badArchive }
        return out
    }
    #endif

    private static func syncDirectory(_ directory: URL) throws {
        let fd = open(directory.path, O_RDONLY)
        guard fd >= 0 else { throw CocoaError(.fileReadUnknown) }
        defer { close(fd) }
        fsync(fd)
    }
}
