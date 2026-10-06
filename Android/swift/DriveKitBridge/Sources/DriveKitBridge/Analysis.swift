import CJNI
import DriveDomain
import DriveReplay
import DriveStorage
import Foundation

// After STOP, what iOS's `SessionFinalizer` does with SwiftData and MapKit, split so Kotlin can geocode in between:
// analyze (mount + sections + peak G) → placeCandidates → Android's Geocoder → sessionTitle.

private struct AnalysisResult: Encodable {
    var calibration: MountCalibration?
    var sections: [DriveSection]
    var sectionsVersion: Int
    var peakLateralG: Double?
    var peakLateralElapsed: Double?
}

private func encode<T: Encodable>(_ value: T) -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    return (try? encoder.encode(value)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
}

/// `analyze(sessionDir)` → JSON. The whole-recording mount (`MountSolver`, kept over the live one as on iOS) is written
/// into the manifest; sections and the peak lateral g come back for `session.json`.
@_cdecl("Java_com_miquottty_drivescope_bridge_DriveKitBridge_analyze")
public func analyze(env: UnsafeMutablePointer<JNIEnv?>, type: jclass?, session: jstring?) -> jstring? {
    let files = SessionFiles(directory: URL(filePath: env.string(session), directoryHint: .isDirectory))
    guard var manifest = try? files.readManifest(), let reader = try? TelemetryReader(files: files) else {
        return env.jstring("{}")
    }
    let live = manifest.calibration
    let solved = MountSolver.solve(reader: reader)
    // As SessionFinalizer.choose: the whole-recording solution wins unless a manual rotation is more confident.
    let chosen = solved.map { s in live?.method == .manual && s.confidence < 0.5 ? live! : s } ?? live
    if chosen != manifest.calibration {
        manifest.calibration = chosen
        try? files.writeManifest(manifest)
    }
    let result = SectionDetector.analyze(reader: reader, calibration: chosen)
    return env.jstring(encode(AnalysisResult(
        calibration: chosen, sections: result.sections, sectionsVersion: SectionDetector.version,
        peakLateralG: result.peakLateral?.g, peakLateralElapsed: result.peakLateral?.time
    )))
}

private struct CandidateJSON: Encodable {
    var latitude: Double
    var longitude: Double
    var role: String
}

/// `placeCandidates(sessionDir, peakLateralElapsed or NaN)` → [{latitude, longitude, role}] to geocode (`PlacePicker`).
@_cdecl("Java_com_miquottty_drivescope_bridge_DriveKitBridge_placeCandidates")
public func placeCandidates(
    env: UnsafeMutablePointer<JNIEnv?>, type: jclass?, session: jstring?, peakLateralElapsed: jdouble
) -> jstring? {
    let files = SessionFiles(directory: URL(filePath: env.string(session), directoryHint: .isDirectory))
    guard let manifest = try? files.readManifest() else { return env.jstring("[]") }
    let candidates = PlacePicker.candidates(
        locations: (try? files.locations()) ?? [], clock: manifest.clock,
        peakLateralElapsed: peakLateralElapsed.isNaN ? nil : peakLateralElapsed
    )
    return env.jstring(encode(candidates.map { CandidateJSON(latitude: $0.latitude, longitude: $0.longitude, role: $0.role.rawValue) }))
}

/// `sessionTitle(startPlaceJson, endPlaceJson, loopWord)` → "足利市 → 太田市", "前橋市 · ループ", or "" (`SessionTitle`).
/// The places are `PlaceMeta` JSON ("" when missing).
@_cdecl("Java_com_miquottty_drivescope_bridge_DriveKitBridge_sessionTitle")
public func sessionTitle(
    env: UnsafeMutablePointer<JNIEnv?>, type: jclass?, start: jstring?, end: jstring?, loopWord: jstring?
) -> jstring? {
    func place(_ text: String) -> PlaceMeta? {
        text.isEmpty ? nil : try? JSONDecoder().decode(PlaceMeta.self, from: Data(text.utf8))
    }
    let title = SessionTitle.make(start: place(env.string(start)), end: place(env.string(end)), loopWord: env.string(loopWord))
    return env.jstring(title ?? "")
}
