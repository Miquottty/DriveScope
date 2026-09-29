import DriveDomain
import DriveStorage
import Foundation

/// A `.bin` stream as a random-access collection over memory-mapped bytes (PLAN §4.1).
/// Nothing is decoded up front, so a 2-hour, 100 Hz log opens instantly; records decode on access.
public struct MappedStream<Record: BinaryRecord>: RandomAccessCollection, Sendable {
    private let data: Data

    public init(files: SessionFiles, kind: StreamKind) throws {
        let bytes = try files.streamData(kind)
        guard !bytes.isEmpty else {
            data = Data()
            return
        }
        let header = try bytes.withUnsafeBytes { try StreamHeader(decoding: $0) }
        guard header.kind == kind else { throw StreamFormatError.wrongStream(expected: kind, found: header.kind) }
        data = bytes
    }

    public var startIndex: Int { 0 }
    public var endIndex: Int { data.count > StreamHeader.size ? (data.count - StreamHeader.size) / Record.recordSize : 0 }

    public subscript(position: Int) -> Record {
        precondition(indices.contains(position), "record index out of range")
        return data.withUnsafeBytes { Record(decoding: $0, at: StreamHeader.size + position * Record.recordSize) }
    }

    /// First index whose key is ≥ `value`, for keys that increase with the index (timestamps).
    public func partitionIndex(where key: (Record) -> Double, isAtLeast value: Double) -> Int {
        var lo = 0, hi = count
        while lo < hi {
            let mid = (lo + hi) / 2
            if key(self[mid]) < value { lo = mid + 1 } else { hi = mid }
        }
        return lo
    }
}

/// All streams of one session, mapped, with times normalized to session elapsed seconds (PLAN §3).
public struct TelemetryReader: Sendable {
    public let manifest: SessionManifest
    public let locations: MappedStream<LocationSample>
    public let motion: MappedStream<MotionSample>
    public let accelerations: MappedStream<AccelSample>
    public let altitudes: MappedStream<AltitudeSample>
    public let events: [EventRecord]

    public init(files: SessionFiles) throws {
        manifest = try files.readManifest()
        locations = try MappedStream(files: files, kind: .location)
        let motionStream = manifest.motionStream
        motion = try motionStream == .motion ? MappedStream(files: files, kind: .motion) : MappedStream(empty: ())
        accelerations = try motionStream == .accel ? MappedStream(files: files, kind: .accel) : MappedStream(empty: ())
        altitudes = try MappedStream(files: files, kind: .altitude)
        events = (try? files.events()) ?? []
    }

    public var clock: SessionClock { manifest.clock }

    public func elapsed(_ location: LocationSample) -> TimeInterval { clock.elapsed(unixTime: location.timestamp) }

    /// Session length covered by data.
    public var duration: TimeInterval {
        var end = 0.0
        if let last = locations.last { end = max(end, elapsed(last)) }
        if let last = motion.last { end = max(end, clock.elapsed(uptime: last.timestamp)) }
        if let last = accelerations.last { end = max(end, clock.elapsed(uptime: last.timestamp)) }
        if let last = altitudes.last { end = max(end, clock.elapsed(uptime: last.timestamp)) }
        return end
    }
}

extension MappedStream {
    init(empty: Void) {
        data = Data()
    }
}
