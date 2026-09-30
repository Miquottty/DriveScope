import DriveDomain
import Foundation

/// `manifest.json` — everything needed to interpret the `.bin` files without SwiftData (PLAN §4.1).
/// Written at START (before any sample) and rewritten when session-level facts change (baseline, stop).
public struct SessionManifest: Codable, Sendable, Equatable {
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public var sessionID: UUID
    public var clock: SessionClock
    public var timeZoneID: String
    public var preset: CapturePreset
    /// Stream kind → record size, for every stream this session writes.
    public var streams: [StreamKind: Int]
    public var appVersion: String
    public var deviceModel: String
    public var osVersion: String
    /// GPS altitude (m) used as the barometric baseline (PLAN §2.3). Set once the first good fix arrives.
    public var altitudeBaseline: Double?
    /// Latest mount calibration, so file-only recovery / replay can use it (PLAN §7).
    public var calibration: MountCalibration?
    public var endedAt: Date?
    /// When the streams were compressed (V1.1, `SessionArchiver`); nil while they are raw.
    public var archivedAt: Date?

    public init(
        sessionID: UUID, clock: SessionClock, timeZoneID: String, preset: CapturePreset,
        appVersion: String, deviceModel: String, osVersion: String
    ) {
        self.schemaVersion = Self.currentSchemaVersion
        self.sessionID = sessionID
        self.clock = clock
        self.timeZoneID = timeZoneID
        self.preset = preset
        self.streams = Dictionary(uniqueKeysWithValues: Self.streamKinds(for: preset).map { ($0, $0.recordSize) })
        self.appVersion = appVersion
        self.deviceModel = deviceModel
        self.osVersion = osVersion
    }

    /// Streams a preset produces. GPS Only writes no motion file (PLAN §4.1).
    public static func streamKinds(for preset: CapturePreset) -> [StreamKind] {
        var kinds: [StreamKind] = [.location, .altitude, .events]
        switch preset.motion {
        case .none: break
        case .accelerometer: kinds.append(.accel)
        case .deviceMotion: kinds.append(.motion)
        }
        return kinds
    }

    public var motionStream: StreamKind? {
        if streams[.motion] != nil { return .motion }
        if streams[.accel] != nil { return .accel }
        return nil
    }
}

/// On-disk layout: `Application Support/Sessions/<sessionID>/`.
public struct SessionFiles: Sendable, Equatable {
    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    public init(root: URL, sessionID: UUID) {
        self.directory = root.appending(path: sessionID.uuidString, directoryHint: .isDirectory)
    }

    /// Default root for all sessions.
    public static func defaultRoot() throws -> URL {
        let support = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        )
        return support.appending(path: "Sessions", directoryHint: .isDirectory)
    }

    public var manifestURL: URL { directory.appending(path: "manifest.json") }

    public func url(for kind: StreamKind) -> URL { directory.appending(path: kind.fileName) }

    public func createDirectory() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    public func writeManifest(_ manifest: SessionManifest) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(ManifestDate.string(from: date))
        }
        try encoder.encode(manifest).write(to: manifestURL, options: .atomic)
    }

    public func readManifest() throws -> SessionManifest {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let text = try decoder.singleValueContainer().decode(String.self)
            guard let date = ManifestDate.date(from: text) else {
                throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Invalid ISO 8601 date: \(text)"))
            }
            return date
        }
        return try decoder.decode(SessionManifest.self, from: Data(contentsOf: manifestURL))
    }

    public func delete() throws {
        try FileManager.default.removeItem(at: directory)
    }

    /// Total bytes on disk for this session.
    public func byteSize() -> Int {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        return files.reduce(0) { $0 + ((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
    }
}

/// ISO 8601 with microsecond fractional seconds. The stock `.iso8601` strategy drops the fraction, which moved
/// `clock.startedAt` (the reference for Location timestamps) by up to a second and so shifted GPS against motion.
/// Manifests written before that fix carry whole seconds only and must still load.
enum ManifestDate {
    static func string(from date: Date) -> String {
        let unix = date.timeIntervalSince1970
        var whole = unix.rounded(.down)
        var micros = Int(((unix - whole) * 1_000_000).rounded())
        if micros == 1_000_000 {
            whole += 1
            micros = 0
        }
        let seconds = Date(timeIntervalSince1970: whole).formatted(.iso8601)
        let digits = String(micros)
        return seconds.dropLast() + "." + String(repeating: "0", count: 6 - digits.count) + digits + "Z"
    }

    static func date(from text: String) -> Date? {
        guard let dot = text.firstIndex(of: ".") else { return try? Date(text, strategy: .iso8601) }
        let digits = text[text.index(after: dot)...].prefix(while: \.isNumber)
        guard !digits.isEmpty, let fraction = Double("0." + digits),
              let whole = try? Date(String(text[..<dot]) + text[digits.endIndex...], strategy: .iso8601)
        else { return nil }
        return whole.addingTimeInterval(fraction)
    }
}
