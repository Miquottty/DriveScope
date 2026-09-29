import DriveDomain
import DriveReplay
import DriveStorage
import Foundation

public enum ExportKind: Sendable, CaseIterable {
    case json
    case csv30
    case csv10
    case gpx

    public var fileExtension: String {
        switch self {
        case .json: "json"
        case .csv30: "csv"
        case .csv10: "10hz.csv"
        case .gpx: "gpx"
        }
    }
}

/// Picks the exporter and file name for the Export screen / share sheet.
public enum SessionExporter {
    /// `<sanitized title>.<ext>`, or `DriveScope yyyy-MM-dd HHmm.<ext>` (session-local time) for an untitled session.
    public static func fileName(metadata: ExportMetadata, startedAt: Date, ext: String, timeZone: TimeZone = .current) -> String {
        var base = sanitized(metadata.title)
        if base.isEmpty {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = timeZone
            let c = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: startedAt)
            func two(_ v: Int?) -> String { String(format: "%02d", v ?? 0) }
            base = "DriveScope \(c.year ?? 0)-\(two(c.month))-\(two(c.day)) \(two(c.hour))\(two(c.minute))"
        }
        return "\(base).\(ext)"
    }

    /// Writes one export into `directory` (created if needed) and returns the file URL. A failed export leaves no partial file.
    public static func export(_ kind: ExportKind, files: SessionFiles, metadata: ExportMetadata, into directory: URL) throws -> URL {
        let reader = try TelemetryReader(files: files)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let name = fileName(
            metadata: metadata, startedAt: reader.clock.startedAt, ext: kind.fileExtension,
            timeZone: TimeZone(identifier: reader.manifest.timeZoneID) ?? .current
        )
        let url = directory.appending(path: name)
        do {
            switch kind {
            case .json: try JSONExporter.export(reader: reader, metadata: metadata, to: url)
            case .csv30: try CSVExporter.export(reader: reader, metadata: metadata, rate: .fps30, to: url)
            case .csv10: try CSVExporter.export(reader: reader, metadata: metadata, rate: .hz10, to: url)
            case .gpx: try GPXExporter.export(reader: reader, metadata: metadata, to: url)
            }
        } catch {
            try? FileManager.default.removeItem(at: url)
            throw error
        }
        return url
    }

    /// Strips characters that are illegal or troublesome in file names and bounds the length.
    private static func sanitized(_ title: String) -> String {
        let banned = CharacterSet(charactersIn: "/\\:*?\"<>|").union(.controlCharacters).union(.newlines)
        let cleaned = String(String.UnicodeScalarView(title.unicodeScalars.map { banned.contains($0) ? " " : $0 }))
        let collapsed = cleaned.split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
        let trimmed = String(collapsed.prefix(80)).trimmingCharacters(in: CharacterSet(charactersIn: ". "))
        return trimmed
    }
}
