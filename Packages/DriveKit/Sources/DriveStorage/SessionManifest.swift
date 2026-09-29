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
    public var endedAt: Date?

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
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(manifest).write(to: manifestURL, options: .atomic)
    }

    public func readManifest() throws -> SessionManifest {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
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
