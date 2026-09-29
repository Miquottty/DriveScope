import DriveDomain
import Foundation

/// The append-only sample streams of a session (PLAN §4.1).
public enum StreamKind: String, Sendable, CaseIterable, Codable, CodingKeyRepresentable {
    case location
    /// Device motion (`MotionSample`).
    case motion
    /// Accelerometer only, Eco preset (`AccelSample`). Stored in `motion.bin` too; the manifest says which.
    case accel
    case altitude
    case events

    public var fileName: String {
        switch self {
        case .location: "location.bin"
        case .motion, .accel: "motion.bin"
        case .altitude: "altitude.bin"
        case .events: "events.bin"
        }
    }

    public var recordSize: Int {
        switch self {
        case .location: LocationSample.recordSize
        case .motion: MotionSample.recordSize
        case .accel: AccelSample.recordSize
        case .altitude: AltitudeSample.recordSize
        case .events: EventRecord.recordSize
        }
    }

    public var formatVersion: UInt16 {
        switch self {
        case .location: LocationSample.formatVersion
        case .motion: MotionSample.formatVersion
        case .accel: AccelSample.formatVersion
        case .altitude: AltitudeSample.formatVersion
        case .events: EventRecord.formatVersion
        }
    }

    /// Four-character code written in the header; distinguishes the two `motion.bin` formats.
    var fourCC: UInt32 {
        let code: String = switch self {
        case .location: "LOCN"
        case .motion: "DMOT"
        case .accel: "ACCL"
        case .altitude: "ALTI"
        case .events: "EVNT"
        }
        return code.utf8.reduce(0) { $0 << 8 | UInt32($1) }
    }

    init?(fourCC: UInt32) {
        guard let kind = StreamKind.allCases.first(where: { $0.fourCC == fourCC }) else { return nil }
        self = kind
    }
}

/// 32-byte file header: magic, stream code, version, record size, creation time.
public struct StreamHeader: Equatable, Sendable {
    public static let size = 32
    static let magic: UInt32 = 0x4453_424E // "DSBN"

    public var kind: StreamKind
    public var version: UInt16
    public var recordSize: Int
    /// Seconds since 1970.
    public var createdAt: Double

    public init(kind: StreamKind, createdAt: Double) {
        self.kind = kind
        self.version = kind.formatVersion
        self.recordSize = kind.recordSize
        self.createdAt = createdAt
    }

    func encoded() -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: Self.size)
        bytes.withUnsafeMutableBytes { buffer in
            var w = RecordWriter(buffer, at: 0)
            w.put(Self.magic)
            w.put(kind.fourCC)
            w.put(version)
            w.put(UInt16(recordSize))
            w.put(UInt32(0))
            w.put(createdAt)
        }
        return bytes
    }

    public init(decoding buffer: UnsafeRawBufferPointer) throws(StreamFormatError) {
        guard buffer.count >= Self.size else { throw .truncatedHeader }
        var r = RecordReader(buffer, at: 0)
        guard r.get(UInt32.self) == Self.magic else { throw .badMagic }
        guard let kind = StreamKind(fourCC: r.get()) else { throw .unknownStream }
        self.kind = kind
        self.version = r.get()
        self.recordSize = Int(r.get(UInt16.self))
        _ = r.get(UInt32.self)
        self.createdAt = r.double()
        guard recordSize == kind.recordSize else { throw .recordSizeMismatch(expected: kind.recordSize, found: recordSize) }
    }
}

public enum StreamFormatError: Error, Equatable {
    case truncatedHeader
    case badMagic
    case unknownStream
    case recordSizeMismatch(expected: Int, found: Int)
    case wrongStream(expected: StreamKind, found: StreamKind)
}
