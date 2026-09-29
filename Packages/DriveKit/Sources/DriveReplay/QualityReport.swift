import DriveDomain
import DriveStorage
import Foundation

/// Log-quality figures for the Quality screen (PLAN §11 "Quality (Debug)").
/// Reads only what it needs: all fixes (1 Hz), but just the size and first / last record of the motion stream.
public struct QualityReport: Sendable {
    public struct Stream: Sendable {
        public var count = 0
        /// Seconds between first and last sample.
        public var span: TimeInterval = 0
        public var meanInterval: TimeInterval?
        public var maxGap: TimeInterval?
        public var effectiveHz: Double? { span > 0 && count > 1 ? Double(count - 1) / span : nil }
    }

    public var preset: CapturePreset
    public var location = Stream()
    public var motion = Stream()
    public var altitude = Stream()
    public var accuracyP50: Double = 0
    public var accuracyP95: Double = 0
    /// 1 - received / expected, over the motion span.
    public var motionDropRate: Double?
    public var battery = BatteryUsage()
    /// Highest `ProcessInfo.ThermalState` raw value seen (0 nominal … 3 critical).
    public var maxThermalState: Int?
    public var events: [EventRecord] = []
    public var bytesOnDisk = 0
    /// Size of the streams uncompressed; equals `bytesOnDisk` unless the session is archived.
    public var rawBytes = 0
    public var isArchived = false

    public static func make(files: SessionFiles) throws -> QualityReport {
        let manifest = try files.readManifest()
        var report = QualityReport(preset: manifest.preset)

        let fixes = try files.locations()
        report.location = stream(times: fixes.map(\.timestamp))
        let accuracies = fixes.map(\.horizontalAccuracy).filter { $0 > 0 }.sorted()
        report.accuracyP50 = SessionStatistics.percentile(accuracies, 0.5)
        report.accuracyP95 = SessionStatistics.percentile(accuracies, 0.95)

        if let kind = manifest.motionStream {
            let count = files.recordCount(kind)
            if count > 0, let (first, last) = try firstAndLastTimestamp(files: files, kind: kind) {
                report.motion.count = count
                report.motion.span = last - first
                report.motion.meanInterval = count > 1 ? (last - first) / Double(count - 1) : nil
                let expected = (last - first) * manifest.preset.motion.hz + 1
                report.motionDropRate = expected > 0 ? max(0, 1 - Double(count) / expected) : nil
            }
        }
        report.altitude = stream(times: try files.altitudes().map(\.timestamp))

        report.events = try files.events()
        report.battery = BatteryUsage(events: report.events)
        report.maxThermalState = report.events.filter { $0.kind == .thermalStateChanged }.map { Int($0.aux) }.max()
        report.bytesOnDisk = files.byteSize()
        report.rawBytes = files.rawByteSize()
        report.isArchived = files.isArchived
        return report
    }

    private static func stream(times: [Double]) -> Stream {
        var s = Stream()
        s.count = times.count
        guard let first = times.first, let last = times.last, times.count > 1 else { return s }
        s.span = last - first
        s.meanInterval = s.span / Double(times.count - 1)
        s.maxGap = zip(times, times.dropFirst()).map { $1 - $0 }.max()
        return s
    }

    private static func firstAndLastTimestamp(files: SessionFiles, kind: StreamKind) throws -> (Double, Double)? {
        let data = try files.streamData(kind)
        let count = (data.count - StreamHeader.size) / kind.recordSize
        guard count > 0 else { return nil }
        // Every record starts with its Double timestamp.
        return data.withUnsafeBytes { buffer in
            var first = RecordReader(buffer, at: StreamHeader.size)
            var last = RecordReader(buffer, at: StreamHeader.size + (count - 1) * kind.recordSize)
            return (first.double(), last.double())
        }
    }
}
