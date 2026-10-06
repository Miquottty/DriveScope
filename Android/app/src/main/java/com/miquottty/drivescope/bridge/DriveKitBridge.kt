package com.miquottty.drivescope.bridge

/**
 * DriveKit (Swift) on the phone, through JNI — Android/swift/DriveKitBridge, built by Android/swift/build-bridge.sh.
 * The recording engine, the analysis, the replay frames and the exports are the iOS code (docs/ANDROID_PLAN.md).
 */
object DriveKitBridge {
    init {
        System.loadLibrary("c++_shared")
        System.loadLibrary("DriveKitBridge")
    }

    /**
     * Foundation writes `.atomic` files through the temporary directory, which Android leaves unset (→ /tmp, not
     * writable). Call once with the app's cache directory before anything else.
     */
    fun configure(cacheDir: String) {
        android.system.Os.setenv("TMPDIR", cacheDir, true)
    }

    // Recording: one run per handle (0 = failed to start). Every push is already in the iOS conventions.

    external fun recorderStart(
        root: String, preset: String, appVersion: String, deviceModel: String, osVersion: String, timeZoneID: String,
        hasGyroscope: Boolean, hasBarometer: Boolean, fastWatchdog: Boolean,
    ): Long

    /** Continues an unfinished session in its own files (0 = can't: another boot, or > 30 min when `automatic`). */
    external fun recorderResume(sessionDir: String, automatic: Boolean, hasGyroscope: Boolean, hasBarometer: Boolean, fastWatchdog: Boolean): Long

    external fun recorderSessionID(handle: Long): String

    external fun pushLocation(
        handle: Long, boot: Double, latitude: Double, longitude: Double, altitude: Double, speed: Float, course: Float,
        horizontalAccuracy: Float, verticalAccuracy: Float, speedAccuracy: Float, courseAccuracy: Float, flags: Int,
    )

    /** `values`: userAcceleration xyz (g), gravity xyz (g), rotationRate xyz, attitude wxyz, magneticField xyz. */
    external fun pushMotion(handle: Long, boot: Double, values: FloatArray, magneticAccuracy: Int)

    external fun pushAccel(handle: Long, boot: Double, x: Float, y: Float, z: Float)

    external fun pushAltitude(handle: Long, boot: Double, relativeAltitude: Float, kPa: Float)

    /** See `Snapshot` for the fields. */
    external fun snapshot(handle: Long): DoubleArray

    /** [kind, stream, stage, seconds] × actions since the last call (see Recorder.swift). */
    external fun drainWatchdog(handle: Long): DoubleArray

    /** `kind` = marker aux (0 MARK, 1 SYNC, 2 HIGHLIGHT), `source` = EventSource (0 phone, 1 notification, 3 system). */
    external fun mark(handle: Long, kind: Int, source: Int, pressedAt: Double): Double

    /** `onsetBoot` = the beep's first pip at the output on the elapsedRealtime clock (NaN = no beep). */
    external fun sync(handle: Long, onsetBoot: Double, latency: Double, route: Int, pressedAt: Double): Double

    external fun recordEvent(handle: Long, kind: Int, source: Int, aux: Int, value: Double)

    external fun rotateMount(handle: Long)

    external fun flush(handle: Long)

    /** Stops and releases the run: {sessionID, endedAt, summary, routePreview} as JSON. */
    external fun recorderStop(handle: Long): String

    // After STOP.

    /** {calibration, sections, sectionsVersion, peakLateralG, peakLateralElapsed}; writes the solved mount to the manifest. */
    external fun analyze(sessionDir: String): String

    /** [{latitude, longitude, role}] to geocode. */
    external fun placeCandidates(sessionDir: String, peakLateralElapsed: Double): String

    /** iOS's automatic title from two `PlaceMeta` JSON objects ("" when missing). */
    external fun sessionTitle(startPlace: String, endPlace: String, loopWord: String): String

    // Review.

    /** The app's JSON export of `sessionDir` into `outDir`; returns the file path or "error: …". */
    external fun exportJson(sessionDir: String, title: String, workDir: String, outDir: String): String

    /** `kind` "json" / "gpx" / "csv30" / "csv10" with the session's title, notes and `PlaceMeta` array; path or "error: …". */
    external fun exportFile(kind: String, sessionDir: String, title: String, notes: String, placesJson: String, workDir: String, outDir: String): String

    /** The Quality screen's `QualityReport` (streams, accuracy, satellite fix, battery, thermal, every event) as JSON. */
    external fun qualityJson(sessionDir: String): String

    /** {summary, routePreview, lastSample} from the files alone (recovery). */
    external fun recompute(sessionDir: String): String

    /** A few Quality-screen figures for `sessionDir`, computed by DriveKit. */
    external fun quality(sessionDir: String): String

    /** [t, lat, lon, speed m/s, course °, altitude m, lateral g, GPS accuracy m, longitudinal g] × frames at `hz` — the iOS Replay interpolation. */
    external fun replayFrames(sessionDir: String, hz: Double): DoubleArray

    /** [elapsed, kind (0 MARK, 1 SYNC, 2 HIGHLIGHT)] × markers. */
    external fun markers(sessionDir: String): DoubleArray

    const val FRAME_STRIDE = 9
}

/** `DriveKitBridge.snapshot`, decoded (Recorder.swift `SnapshotField`). */
data class Snapshot(
    val elapsed: Double = 0.0,
    val speed: Double? = null,
    val altitude: Double? = null,
    val course: Double? = null,
    val distance: Double = 0.0,
    val horizontalAccuracy: Double? = null,
    val gpsStatus: GpsStatus = GpsStatus.ACQUIRING,
    val lateralG: Double = 0.0,
    val longitudinalG: Double = 0.0,
    val locationCount: Int = 0,
    val motionCount: Int = 0,
    val isCalibrated: Boolean = false,
    val satelliteFixAfter: Double? = null,
    val latitude: Double? = null,
    val longitude: Double? = null,
) {
    enum class GpsStatus { ACQUIRING, GOOD, SEARCHING }

    companion object {
        fun decode(v: DoubleArray): Snapshot {
            if (v.size < 15) return Snapshot()
            fun opt(i: Int) = v[i].takeUnless { it.isNaN() }
            return Snapshot(
                elapsed = v[0], speed = opt(1), altitude = opt(2), course = opt(3), distance = v[4],
                horizontalAccuracy = opt(5), gpsStatus = GpsStatus.entries[v[6].toInt().coerceIn(0, 2)],
                lateralG = v[7], longitudinalG = v[8], locationCount = v[9].toInt(), motionCount = v[10].toInt(),
                isCalibrated = v[11] != 0.0, satelliteFixAfter = opt(12), latitude = opt(13), longitude = opt(14),
            )
        }
    }
}
