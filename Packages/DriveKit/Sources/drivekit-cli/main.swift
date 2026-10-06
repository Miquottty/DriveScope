import DriveDomain
import DriveExport
import DriveReplay
import DriveStorage
import Foundation

// drivekit-cli — reads a session folder (manifest.json + *.bin) the way the app does, so a recording pulled from
// a device (the Android spike's Pixel, or an iPhone) can be checked and exported on the Mac.
//
//   swift run drivekit-cli quality <session-dir>
//   swift run drivekit-cli export json|gpx|csv|csv10 <session-dir> [--title <t>] [--out <dir>]
//
// Export is `SessionExporter.exportDerivingMetadata` (what the app keeps in SwiftData, derived from the files).

enum CLIError: Error, CustomStringConvertible {
    case usage
    case notASession(String)

    var description: String {
        switch self {
        case .usage:
            "usage: drivekit-cli quality <session-dir>\n       drivekit-cli export json|gpx|csv|csv10 <session-dir> [--title <t>] [--out <dir>]"
        case .notASession(let path): "not a session folder (no manifest.json): \(path)"
        }
    }
}

func sessionFiles(_ path: String) throws -> SessionFiles {
    let url = URL(filePath: path, directoryHint: .isDirectory).standardizedFileURL
    let files = SessionFiles(directory: url)
    guard FileManager.default.fileExists(atPath: files.manifestURL.path) else { throw CLIError.notASession(path) }
    return files
}

func option(_ name: String, in arguments: [String]) -> String? {
    arguments.firstIndex(of: name).flatMap { arguments.indices.contains($0 + 1) ? arguments[$0 + 1] : nil }
}

func fixed(_ value: Double, _ digits: Int = 2) -> String { String(format: "%.\(digits)f", value) }

func quality(_ files: SessionFiles) throws {
    let manifest = try files.readManifest()
    let report = try QualityReport.make(files: files)
    let (statistics, duration) = try SessionStatistics.compute(files: files, manifest: manifest)
    let summary = statistics.summary(duration: duration)
    print("session      \(manifest.sessionID)  \(manifest.deviceModel) \(manifest.osVersion)  app \(manifest.appVersion)")
    print("preset       \(manifest.preset.rawValue)  started \(manifest.clock.startedAt)  tz \(manifest.timeZoneID)")
    print("duration     \(fixed(duration, 1)) s   distance \(fixed(summary.distance / 1000, 3)) km   max \(fixed(summary.maxSpeed * 3.6, 1)) km/h")
    print("location     \(report.location.count) fixes  mean \(report.location.meanInterval.map { fixed($0) } ?? "—") s  max gap \(report.location.maxGap.map { fixed($0, 1) } ?? "—") s")
    print("accuracy     P50 \(fixed(report.accuracyP50, 1)) m  P95 \(fixed(report.accuracyP95, 1)) m  satellite fix after \(report.firstSatelliteFix.map { fixed($0, 1) + " s" } ?? "never")")
    print("motion       \(report.motion.count) samples  \(report.motion.effectiveHz.map { fixed($0, 2) } ?? "—") Hz (preset \(fixed(manifest.preset.motion.hz, 0)))  dropped \(report.motionDropRate.map { fixed($0 * 100, 3) + " %" } ?? "—")")
    print("altitude     \(report.altitude.count) samples  mean \(report.altitude.meanInterval.map { fixed($0) } ?? "—") s  gain \(fixed(summary.elevationGain, 1)) m")
    print("events       \(report.events.count)  " + Dictionary(grouping: report.events, by: \.kind).map { "\($0.key)×\($0.value.count)" }.sorted().joined(separator: " "))
    print("calibration  \(manifest.calibration.map { "\($0.method.rawValue) confidence \(fixed($0.confidence))" } ?? "none")")
}

func export(_ kindName: String, _ files: SessionFiles, title: String, out: URL) throws -> URL {
    let kind: ExportKind = switch kindName {
    case "json": .json
    case "gpx": .gpx
    case "csv": .csv30
    case "csv10": .csv10
    default: throw CLIError.usage
    }
    return try SessionExporter.exportDerivingMetadata(
        kind, files: files, title: title, workDirectory: FileManager.default.temporaryDirectory, into: out
    )
}

let arguments = Array(CommandLine.arguments.dropFirst())
do {
    switch (arguments.first, arguments.count) {
    case ("quality", 2...):
        try quality(sessionFiles(arguments[1]))
    case ("export", 3...):
        let files = try sessionFiles(arguments[2])
        let title = option("--title", in: arguments) ?? files.directory.lastPathComponent
        let out = URL(filePath: option("--out", in: arguments) ?? FileManager.default.currentDirectoryPath, directoryHint: .isDirectory)
        print(try export(arguments[1], files, title: title, out: out).path)
    default:
        throw CLIError.usage
    }
} catch {
    FileHandle.standardError.write(Data("\(error)\n".utf8))
    exit(1)
}
