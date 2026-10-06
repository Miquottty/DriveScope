import CJNI
import DriveDomain
import DriveExport
import DriveReplay
import DriveStorage
import Foundation

// Review screens: exports with the app's metadata, the Quality report, and recomputing a session from its files.

private func encodeJSON<T: Encodable>(_ value: T) -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    return (try? encoder.encode(value)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
}

/// `exportFile(kind ("json", "gpx", "csv30", "csv10"), sessionDir, title, notes, placesJson, workDir, outDir)` → the
/// written file's path or "error: …". `placesJson` is a `PlaceMeta` array (session.json's places).
@_cdecl("Java_com_miquottty_drivescope_bridge_DriveKitBridge_exportFile")
public func exportFile(
    env: UnsafeMutablePointer<JNIEnv?>, type: jclass?, kind: jstring?, session: jstring?, title: jstring?, notes: jstring?,
    places: jstring?, work: jstring?, out: jstring?
) -> jstring? {
    let exportKind: ExportKind? = switch env.string(kind) {
    case "json": .json
    case "gpx": .gpx
    case "csv30": .csv30
    case "csv10": .csv10
    default: nil
    }
    guard let exportKind else { return env.jstring("error: unknown export kind") }
    let placeList = (try? JSONDecoder().decode([PlaceMeta].self, from: Data(env.string(places).utf8))) ?? []
    let result: String
    do {
        result = try SessionExporter.exportDerivingMetadata(
            exportKind,
            files: SessionFiles(directory: URL(filePath: env.string(session), directoryHint: .isDirectory)),
            title: env.string(title), notes: env.string(notes), places: placeList,
            workDirectory: URL(filePath: env.string(work), directoryHint: .isDirectory),
            into: URL(filePath: env.string(out), directoryHint: .isDirectory)
        ).path
    } catch {
        result = "error: \(error)"
    }
    return env.jstring(result)
}

private struct StreamJSON: Encodable {
    var count: Int
    var meanInterval: Double?
    var maxGap: Double?
    var effectiveHz: Double?

    init(_ s: QualityReport.Stream) {
        count = s.count
        meanInterval = s.meanInterval
        maxGap = s.maxGap
        effectiveHz = s.effectiveHz
    }
}

private struct EventJSON: Encodable {
    var kind: Int
    var source: Int
    var aux: UInt32
    var elapsed: Double
    var value: Double
}

private struct QualityJSON: Encodable {
    var preset: String
    var motionHz: Double
    var location: StreamJSON
    var motion: StreamJSON
    var altitude: StreamJSON
    var accuracyP50: Double
    var accuracyP95: Double
    var firstSatelliteFix: Double?
    var motionDropRate: Double?
    var batteryOverall: Double?
    var batteryScreenOn: Double?
    var batteryScreenOff: Double?
    var maxThermalState: Int?
    var bytesOnDisk: Int
    var events: [EventJSON]
}

/// `qualityJson(sessionDir)` → the Quality screen's `QualityReport` with every event.
@_cdecl("Java_com_miquottty_drivescope_bridge_DriveKitBridge_qualityJson")
public func qualityJson(env: UnsafeMutablePointer<JNIEnv?>, type: jclass?, session: jstring?) -> jstring? {
    let files = SessionFiles(directory: URL(filePath: env.string(session), directoryHint: .isDirectory))
    guard let r = try? QualityReport.make(files: files) else { return env.jstring("{}") }
    return env.jstring(encodeJSON(QualityJSON(
        preset: r.preset.rawValue, motionHz: r.preset.motion.hz,
        location: StreamJSON(r.location), motion: StreamJSON(r.motion), altitude: StreamJSON(r.altitude),
        accuracyP50: r.accuracyP50, accuracyP95: r.accuracyP95, firstSatelliteFix: r.firstSatelliteFix,
        motionDropRate: r.motionDropRate, batteryOverall: r.battery.overall, batteryScreenOn: r.battery.screenOn,
        batteryScreenOff: r.battery.screenOff, maxThermalState: r.maxThermalState, bytesOnDisk: r.bytesOnDisk,
        events: r.events.map {
            EventJSON(kind: Int($0.kind.rawValue), source: Int($0.source.rawValue), aux: $0.aux, elapsed: $0.elapsed, value: $0.value)
        }
    )))
}

private struct RecomputeJSON: Encodable {
    var summary: SessionSummary
    var routePreview: [RoutePoint]
    /// Seconds of the last sample (the session's length when it never got an `endedAt`).
    var lastSample: Double
}

/// `recompute(sessionDir)` → {summary, routePreview, lastSample}: a session's statistics from its files alone (recovery,
/// as iOS `RecordingController.recompute`).
@_cdecl("Java_com_miquottty_drivescope_bridge_DriveKitBridge_recompute")
public func recompute(env: UnsafeMutablePointer<JNIEnv?>, type: jclass?, session: jstring?) -> jstring? {
    let files = SessionFiles(directory: URL(filePath: env.string(session), directoryHint: .isDirectory))
    guard let manifest = try? files.readManifest(),
          let (statistics, lastSample) = try? SessionStatistics.compute(files: files, manifest: manifest)
    else { return env.jstring("{}") }
    let duration = manifest.endedAt.map { $0.timeIntervalSince(manifest.clock.startedAt) } ?? lastSample
    var summary = statistics.summary(duration: duration)
    summary.batteryUsagePerHour = BatteryUsage(events: (try? files.events()) ?? []).overall
    return env.jstring(encodeJSON(RecomputeJSON(
        summary: summary, routePreview: RoutePreview.make(from: (try? files.locations()) ?? []), lastSample: lastSample
    )))
}
