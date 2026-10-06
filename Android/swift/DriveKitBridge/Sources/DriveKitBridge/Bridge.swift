import CJNI
import DriveDomain
import DriveExport
import DriveReplay
import DriveStorage
import Foundation

// JNI entry points for com.miquottty.drivescope.bridge.DriveKitBridge. Each takes and returns Java strings; errors
// come back as "error: …" so the spike screen can show them.

/// `exportJson(sessionDir, title, workDir, outDir)` → the written file's path.
@_cdecl("Java_com_miquottty_drivescope_bridge_DriveKitBridge_exportJson")
public func exportJson(
    env: UnsafeMutablePointer<JNIEnv?>, type: jclass?, session: jstring?, title: jstring?, work: jstring?, out: jstring?
) -> jstring? {
    let result: String
    do {
        let url = try SessionExporter.exportDerivingMetadata(
            .json,
            files: SessionFiles(directory: URL(filePath: env.string(session), directoryHint: .isDirectory)),
            title: env.string(title),
            workDirectory: URL(filePath: env.string(work), directoryHint: .isDirectory),
            into: URL(filePath: env.string(out), directoryHint: .isDirectory)
        )
        result = url.path
    } catch {
        result = "error: \(error)"
    }
    return env.jstring(result)
}

/// `quality(sessionDir)` → a few lines of the Quality screen's figures, computed by DriveKit on the phone.
@_cdecl("Java_com_miquottty_drivescope_bridge_DriveKitBridge_quality")
public func quality(env: UnsafeMutablePointer<JNIEnv?>, type: jclass?, session: jstring?) -> jstring? {
    let result: String
    do {
        let files = SessionFiles(directory: URL(filePath: env.string(session), directoryHint: .isDirectory))
        let manifest = try files.readManifest()
        let report = try QualityReport.make(files: files)
        let (statistics, duration) = try SessionStatistics.compute(files: files, manifest: manifest)
        let summary = statistics.summary(duration: duration)
        func fixed(_ v: Double, _ d: Int = 2) -> String { String(format: "%.\(d)f", v) }
        result = """
        duration \(fixed(duration, 1)) s · distance \(fixed(summary.distance / 1000, 3)) km
        location \(report.location.count) · P50 \(fixed(report.accuracyP50, 1)) m · satellite fix \(report.firstSatelliteFix.map { fixed($0, 1) + " s" } ?? "never")
        motion \(report.motion.count) · \(report.motion.effectiveHz.map { fixed($0) } ?? "—") Hz · dropped \(report.motionDropRate.map { fixed($0 * 100, 3) + " %" } ?? "—")
        altitude \(report.altitude.count) · gain \(fixed(summary.elevationGain, 1)) m
        """
    } catch {
        result = "error: \(error)"
    }
    return env.jstring(result)
}

/// Fields per frame in `replayFrames`.
private let frameStride = 9

/// `replayFrames(sessionDir, hz)` → [t, lat, lon, speed m/s, course °, altitude m, lateral g, GPS accuracy m, longitudinal g] × frames, from the same
/// interpolator and smoothing as the iOS Replay screen (`ReplayTimeline.options`), with the solved mount.
@_cdecl("Java_com_miquottty_drivescope_bridge_DriveKitBridge_replayFrames")
public func replayFrames(env: UnsafeMutablePointer<JNIEnv?>, type: jclass?, session: jstring?, hz: jdouble) -> jdoubleArray? {
    guard let reader = try? TelemetryReader(files: SessionFiles(directory: URL(filePath: env.string(session), directoryHint: .isDirectory))),
          reader.duration > 0, hz > 0
    else { return env.doubleArray([]) }
    let calibration = MountSolver.solve(reader: reader) ?? reader.manifest.calibration
    let interpolator = TelemetryInterpolator(
        reader: reader, calibration: calibration, options: .init(speedWindow: 1, gWindow: 0.2)
    )
    let count = Int(reader.duration * hz) + 1
    var values: [Double] = []
    values.reserveCapacity(count * frameStride)
    for i in 0..<count {
        let f = interpolator.frame(at: Double(i) / hz)
        values += [f.time, f.latitude, f.longitude, f.speed, f.course, f.altitude, f.lateralG, f.gpsAccuracy, f.longitudinalG]
    }
    return env.doubleArray(values)
}

/// `markers(sessionDir)` → [elapsed, kind (0 MARK, 1 SYNC, 2 HIGHLIGHT)] × markers, from events.bin.
@_cdecl("Java_com_miquottty_drivescope_bridge_DriveKitBridge_markers")
public func markers(env: UnsafeMutablePointer<JNIEnv?>, type: jclass?, session: jstring?) -> jdoubleArray? {
    let files = SessionFiles(directory: URL(filePath: env.string(session), directoryHint: .isDirectory))
    let events = (try? files.events()) ?? []
    return env.doubleArray(events.filter { $0.kind == .marker }.flatMap { [$0.elapsed, Double($0.aux)] })
}
