import DriveDomain
import DriveReplay
import DriveStorage
import Foundation

extension SessionExporter {
    /// Exports a session from its folder alone — no SwiftData — deriving what the app keeps there: markers from
    /// events.bin, the summary (`SessionStatistics`), the mount (`MountSolver`) and the sections. No places (the
    /// geocoder is MapKit). Used by `drivekit-cli` on the Mac and by the Android app through JNI.
    ///
    /// Works on a copy in `workDirectory` (the mount solution is written into its manifest), so the recorded folder
    /// stays as it was.
    public static func exportDerivingMetadata(
        _ kind: ExportKind, files: SessionFiles, title: String, workDirectory: URL, into directory: URL
    ) throws -> URL {
        let fm = FileManager.default
        let work = workDirectory.appending(path: "export-\(UUID().uuidString)", directoryHint: .isDirectory)
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        // File contents only: `copyItem` also copies owners and modes, which Android refuses from its shared storage.
        for name in try fm.contentsOfDirectory(atPath: files.directory.path) {
            let source = files.directory.appending(path: name)
            guard (try? source.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { continue }
            try Data(contentsOf: source).write(to: work.appending(path: name))
        }
        defer { try? fm.removeItem(at: work) }
        let copy = SessionFiles(directory: work)

        var manifest = try copy.readManifest()
        let calibration = MountSolver.solve(reader: try TelemetryReader(files: copy)) ?? manifest.calibration
        if calibration != manifest.calibration {
            manifest.calibration = calibration
            try copy.writeManifest(manifest)
        }
        let reader = try TelemetryReader(files: copy)
        let analysis = SectionDetector.analyze(reader: reader, calibration: calibration)
        let (statistics, lastSample) = try SessionStatistics.compute(files: copy, manifest: manifest)
        // As the app: STOP time when the manifest has it (the last sample only for a recovered session).
        let duration = manifest.endedAt.map { $0.timeIntervalSince(manifest.clock.startedAt) } ?? lastSample
        var summary = statistics.summary(duration: duration)
        summary.batteryUsagePerHour = BatteryUsage(events: reader.events).overall
        if let peak = analysis.peakLateral { summary.peakLateralG = peak.g }
        let markers = reader.events.compactMap { event -> ExportMarker? in
            guard event.kind == .marker, let kind = MarkerKind(eventAux: event.aux) else { return nil }
            return ExportMarker(kind: kind, elapsed: event.elapsed, date: manifest.clock.date(elapsed: event.elapsed))
        }
        let metadata = ExportMetadata(title: title, markers: markers, summary: summary, sections: analysis.sections)
        return try export(kind, files: copy, metadata: metadata, into: directory)
    }
}
