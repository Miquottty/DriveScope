package com.miquottty.drivescope.recording

import android.annotation.SuppressLint
import android.hardware.Sensor
import android.hardware.SensorEvent
import android.hardware.SensorEventListener
import android.hardware.SensorManager
import android.location.Location
import android.location.LocationListener
import android.location.LocationManager
import android.os.Build
import android.os.Handler
import android.os.SystemClock
import org.json.JSONObject
import java.io.File
import java.time.Instant
import java.util.TimeZone
import java.util.UUID

/** Live counters for the probe screen. */
data class RecordingStatus(
    val sessionID: String,
    val directory: String,
    val elapsed: Double,
    val locations: Int,
    val motion: Int,
    val altitudes: Int,
)

/**
 * Records one Logger-preset session (GPS 1 Hz, device motion 50 Hz, barometer) into the iOS session format
 * (DriveKit `Samples.swift`, `SessionManifest.swift`), converted to the iOS conventions so DriveKit reads it unchanged:
 *
 * - one clock: every stream is stamped on `elapsedRealtime` (seconds since boot, sleep included), the manifest's
 *   `startUptime` is the same clock, and a fix's unix time is derived from it so GPS lines up with motion exactly
 * - acceleration and gravity in g with Core Motion's sign (Android reports the reaction force: ×(−1/9.80665))
 * - pressure in kPa, relative altitude from the first pressure reading
 * - altitude above mean sea level when Android provides it (Android 14+), else the WGS84 ellipsoid height
 *
 * All callbacks run on `handler`'s thread, which is also the only writer.
 */
class SessionRecorder(
    private val root: File,
    private val sensorManager: SensorManager,
    private val locationManager: LocationManager,
    private val handler: Handler,
) : SensorEventListener {
    private val sessionID = UUID.randomUUID().toString().uppercase()
    private val directory = File(root, sessionID)
    private val startedAtUnix = System.currentTimeMillis() / 1000.0
    private val startUptime = SystemClock.elapsedRealtimeNanos() / 1e9

    private lateinit var location: StreamWriter
    private lateinit var motion: StreamWriter
    private lateinit var altitude: StreamWriter
    private lateinit var events: StreamWriter
    private var manifest = JSONObject()

    // Latest values of the sensors folded into each 50 Hz motion record (driven by the linear accelerometer).
    private var gravity: FloatArray? = null
    private var rotationRate = FloatArray(3)
    private var rotationVector = FloatArray(4)
    private var magnetic = FloatArray(3)
    private var magneticAccuracy = -1
    private var nextMotionDue = 0L
    private var firstPressure: Float? = null
    /** Pressure readings of the current second (the barometer ignores the 1 Hz request and sends ~36 Hz). */
    private val pressureWindow = mutableListOf<Float>()
    private var pressureWindowStart = 0L
    private var lastSatelliteFixNs = 0L
    private var lastFlush = SystemClock.elapsedRealtime()

    private val locationListener = LocationListener { fix -> onLocation(fix) }
    private val networkListener = LocationListener { fix -> onNetworkLocation(fix) }

    fun status() = RecordingStatus(
        sessionID, directory.absolutePath, SystemClock.elapsedRealtimeNanos() / 1e9 - startUptime,
        location.count, motion.count, altitude.count,
    )

    @SuppressLint("MissingPermission") // The service starts only with fine location granted.
    fun start() {
        directory.mkdirs()
        location = StreamWriter(File(directory, "location.bin"), "LOCN", 72, startedAtUnix)
        motion = StreamWriter(File(directory, "motion.bin"), "DMOT", 76, startedAtUnix)
        altitude = StreamWriter(File(directory, "altitude.bin"), "ALTI", 16, startedAtUnix)
        events = StreamWriter(File(directory, "events.bin"), "EVNT", 24, startedAtUnix)
        manifest = makeManifest()
        writeManifest()

        // The raw accelerometer at 200 Hz drives a 20 ms grid: a 50 Hz request comes out at ~59 Hz on the Pixel 7, and
        // the fused sensors (gravity, linear acceleration) never run faster than that.
        sensorManager.getDefaultSensor(Sensor.TYPE_ACCELEROMETER)?.let { sensorManager.registerListener(this, it, 5_000, handler) }
        for (type in listOf(Sensor.TYPE_GRAVITY, Sensor.TYPE_GYROSCOPE, Sensor.TYPE_ROTATION_VECTOR, Sensor.TYPE_MAGNETIC_FIELD)) {
            sensorManager.getDefaultSensor(type)?.let { sensorManager.registerListener(this, it, 10_000, handler) }
        }
        sensorManager.getDefaultSensor(Sensor.TYPE_PRESSURE)?.let { sensorManager.registerListener(this, it, 1_000_000, handler) }
        locationManager.requestLocationUpdates(LocationManager.GPS_PROVIDER, 1_000L, 0f, locationListener, handler.looper)
        locationManager.requestLocationUpdates(LocationManager.NETWORK_PROVIDER, 1_000L, 0f, networkListener, handler.looper)
    }

    fun stop() {
        sensorManager.unregisterListener(this)
        locationManager.removeUpdates(locationListener)
        locationManager.removeUpdates(networkListener)
        for (stream in listOf(location, motion, altitude, events)) stream.close()
        manifest.put("endedAt", manifestDate(System.currentTimeMillis() / 1000.0))
        writeManifest()
    }

    override fun onSensorChanged(event: SensorEvent) {
        val v = event.values
        when (event.sensor.type) {
            Sensor.TYPE_GRAVITY -> gravity = v.copyOf(3)
            Sensor.TYPE_GYROSCOPE -> rotationRate = v.copyOf(3)
            Sensor.TYPE_ROTATION_VECTOR -> rotationVector = quaternion(v)
            Sensor.TYPE_MAGNETIC_FIELD -> magnetic = v.copyOf(3)
            Sensor.TYPE_ACCELEROMETER -> {
                val gravity = gravity ?: return // nothing to subtract until the fusion has started
                if (nextMotionDue == 0L) nextMotionDue = event.timestamp
                // A 20 ms grid with a little slack for delivery jitter; after a stall the grid restarts.
                if (event.timestamp >= nextMotionDue - MOTION_SLACK_NS) {
                    appendMotion(event.timestamp, FloatArray(3) { v[it] - gravity[it] }, gravity)
                    nextMotionDue += MOTION_PERIOD_NS
                    if (event.timestamp >= nextMotionDue) nextMotionDue = event.timestamp + MOTION_PERIOD_NS
                }
            }
            Sensor.TYPE_PRESSURE -> addPressure(event.timestamp, v[0])
        }
        flushIfDue()
    }

    override fun onAccuracyChanged(sensor: Sensor, accuracy: Int) {
        // SENSOR_STATUS_* 0…3 → CMMagneticFieldCalibrationAccuracy −1…2.
        if (sensor.type == Sensor.TYPE_MAGNETIC_FIELD) magneticAccuracy = accuracy - 1
    }

    private fun appendMotion(timestampNs: Long, linear: FloatArray, gravity: FloatArray) = motion.append { b ->
        b.putDouble(timestampNs / 1e9)
        for (i in 0..2) b.putFloat(-linear[i] / G)
        for (i in 0..2) b.putFloat(-gravity[i] / G)
        for (i in 0..2) b.putFloat(rotationRate[i])
        // w, x, y, z — Android's world frame is east-north-up, not Core Motion's arbitrary-x reference.
        b.putFloat(rotationVector[3]); b.putFloat(rotationVector[0]); b.putFloat(rotationVector[1]); b.putFloat(rotationVector[2])
        for (i in 0..2) b.putFloat(magnetic[i])
        b.putInt(magneticAccuracy)
    }

    /** One altitude record per second, the mean of that second's readings — CMAltimeter's cadence. */
    private fun addPressure(timestampNs: Long, hPa: Float) {
        if (pressureWindow.isEmpty()) pressureWindowStart = timestampNs
        pressureWindow += hPa
        if (timestampNs - pressureWindowStart < 1_000_000_000L) return
        val mean = pressureWindow.average().toFloat()
        val mid = pressureWindowStart + (timestampNs - pressureWindowStart) / 2
        pressureWindow.clear()
        val first = firstPressure ?: mean.also { firstPressure = it }
        altitude.append { b ->
            b.putDouble(mid / 1e9)
            b.putFloat(SensorManager.getAltitude(first, mean))
            b.putFloat(mean / 10f)
        }
    }

    /** Wi‑Fi / cell fixes only while the satellites are silent — what Core Location delivers before a lock. */
    private fun onNetworkLocation(fix: Location) {
        if (fix.elapsedRealtimeNanos - lastSatelliteFixNs < 5_000_000_000L) return
        fix.removeSpeed(); fix.removeBearing()
        onLocation(fix)
    }

    private fun onLocation(fix: Location) {
        if (fix.provider == LocationManager.GPS_PROVIDER) lastSatelliteFixNs = fix.elapsedRealtimeNanos
        val uptime = fix.elapsedRealtimeNanos / 1e9
        // As TelemetryEngine: a fix from before the run is not part of this drive.
        if (uptime < startUptime - 2) return
        location.append { b ->
            b.putDouble(startedAtUnix + (uptime - startUptime))
            b.putDouble(fix.latitude)
            b.putDouble(fix.longitude)
            b.putDouble(if (Build.VERSION.SDK_INT >= 34 && fix.hasMslAltitude()) fix.mslAltitudeMeters else fix.altitude)
            b.putDouble(SystemClock.elapsedRealtimeNanos() / 1e9)
            b.putFloat(if (fix.hasSpeed()) fix.speed else -1f)
            b.putFloat(if (fix.hasBearing() && fix.speed > 0.5f) fix.bearing else -1f)
            b.putFloat(if (fix.hasAccuracy()) fix.accuracy else -1f)
            b.putFloat(if (fix.hasVerticalAccuracy()) fix.verticalAccuracyMeters else -1f)
            b.putFloat(if (fix.hasSpeedAccuracy()) fix.speedAccuracyMetersPerSecond else -1f)
            b.putFloat(if (fix.hasBearingAccuracy()) fix.bearingAccuracyDegrees else -1f)
            b.putInt(if (fix.isMock) 1 else 0) // LocationSample.Flags.simulatedBySoftware
            b.putInt(0)
        }
        if (manifest.isNull("altitudeBaseline") && fix.hasVerticalAccuracy() && fix.verticalAccuracyMeters in 0f..20f) {
            manifest.put("altitudeBaseline", if (Build.VERSION.SDK_INT >= 34 && fix.hasMslAltitude()) fix.mslAltitudeMeters else fix.altitude)
            writeManifest()
        }
        flushIfDue()
    }

    private fun flushIfDue() {
        val now = SystemClock.elapsedRealtime()
        if (now - lastFlush < 5_000) return
        lastFlush = now
        for (stream in listOf(location, motion, altitude, events)) stream.flush()
    }

    private fun makeManifest() = JSONObject().apply {
        put("schemaVersion", 1)
        put("sessionID", sessionID)
        put("clock", JSONObject().put("startedAt", manifestDate(startedAtUnix)).put("startUptime", startUptime))
        put("timeZoneID", TimeZone.getDefault().id)
        put("preset", "logger")
        put("streams", JSONObject().put("location", 72).put("motion", 76).put("altitude", 16).put("events", 24))
        put("appVersion", "android-spike")
        put("deviceModel", Build.MODEL)
        put("osVersion", "Android ${Build.VERSION.RELEASE}")
        put("altitudeBaseline", JSONObject.NULL)
        // Ignored by DriveKit's decoder; tells a reader where the conventions above were applied.
        put("platform", "android")
    }

    private fun writeManifest() {
        val tmp = File(directory, "manifest.json.tmp")
        tmp.writeText(manifest.toString(2))
        tmp.renameTo(File(directory, "manifest.json"))
    }

    companion object {
        const val G = 9.80665f
        const val MOTION_PERIOD_NS = 20_000_000L
        const val MOTION_SLACK_NS = 4_000_000L

        /** DriveKit `ManifestDate`: ISO 8601 UTC with microseconds. */
        fun manifestDate(unix: Double): String {
            val whole = Math.floor(unix).toLong()
            var micros = Math.round((unix - whole) * 1_000_000)
            var seconds = whole
            if (micros == 1_000_000L) { seconds += 1; micros = 0 }
            return Instant.ofEpochSecond(seconds).toString().removeSuffix("Z") + "." + micros.toString().padStart(6, '0') + "Z"
        }

        /** Rotation vector (x, y, z[, w]) → unit quaternion (x, y, z, w). */
        private fun quaternion(v: FloatArray): FloatArray {
            val w = if (v.size >= 4) v[3] else Math.sqrt(maxOf(0.0, 1.0 - v[0] * v[0] - v[1] * v[1] - v[2] * v[2].toDouble())).toFloat()
            return floatArrayOf(v[0], v[1], v[2], w)
        }
    }
}
