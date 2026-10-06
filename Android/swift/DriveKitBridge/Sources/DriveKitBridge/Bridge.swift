import CJNI
import DriveDomain
import DriveExport
import DriveReplay
import DriveStorage
import Foundation

// JNI entry points for com.miquottty.drivescope.bridge.DriveKitBridge. Each takes and returns Java strings; errors
// come back as "error: …" so the spike screen can show them.

private extension UnsafeMutablePointer where Pointee == JNIEnv? {
    var functions: JNINativeInterface { pointee!.pointee }

    func string(_ value: jstring?) -> String {
        guard let value, let chars = functions.GetStringUTFChars(self, value, nil) else { return "" }
        defer { functions.ReleaseStringUTFChars(self, value, chars) }
        return String(cString: chars)
    }

    func jstring(_ value: String) -> CJNI.jstring? {
        value.withCString { functions.NewStringUTF(self, $0) }
    }
}

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
