package com.miquottty.drivescope.recording

import android.annotation.SuppressLint
import android.hardware.Sensor
import android.hardware.SensorEvent
import android.hardware.SensorEventListener
import android.hardware.SensorManager
import android.location.GnssStatus
import android.location.Location
import android.location.LocationListener
import android.location.LocationManager
import android.os.Handler
import com.miquottty.drivescope.bridge.DriveKitBridge

/**
 * Reads the sensors for one run, converts every value to the iOS conventions (`Conventions`) and pushes it into
 * DriveKit's engine (`handle`). All callbacks run on `handler`'s thread.
 *
 * - motion: the raw accelerometer at 200 Hz drives the preset's grid; device-motion presets subtract the fused
 *   gravity (which itself never runs faster than ~59 Hz) for the user acceleration
 * - pressure: one record per second of the boot clock, the mean of that second (the barometer ignores a 1 Hz request
 *   and sends 9–36 Hz)
 * - location: GPS fixes; network (Wi‑Fi / cell) fixes only while the satellites are silent, without speed — what
 *   Core Location delivers before a lock
 */
class SensorPump(
    private val handle: Long,
    private val preset: CapturePreset,
    private val sensorManager: SensorManager,
    private val locationManager: LocationManager,
    private val handler: Handler,
) : SensorEventListener {
    private val grid = preset.motion.hz.takeIf { it > 0 }?.let { Conventions.Grid(it) }
    private var gravity: FloatArray? = null
    private var rotationRate = FloatArray(3)
    private var attitude = floatArrayOf(1f, 0f, 0f, 0f)
    private var magnetic = FloatArray(3)
    private var magneticAccuracy = -1
    private var firstPressure: Float? = null
    private val pressureWindow = mutableListOf<Float>()
    private var pressureSecond = -1L
    private var lastSatelliteFixNs = 0L
    private var lastGnssEvent = 0L

    /** Android only: satellites as a `gnssStatus` event every 30 s (value = top-4 C/N0, aux = used | visible << 16). */
    private val gnssCallback = object : GnssStatus.Callback() {
        override fun onSatelliteStatusChanged(status: GnssStatus) {
            val now = android.os.SystemClock.elapsedRealtime()
            if (now - lastGnssEvent < 30_000) return
            lastGnssEvent = now
            val used = (0 until status.satelliteCount).filter { status.usedInFix(it) }
            val top4 = used.map { status.getCn0DbHz(it).toDouble() }.sortedDescending().take(4)
            val aux = (used.size and 0xFFFF) or (minOf(status.satelliteCount, 0xFFFF) shl 16)
            DriveKitBridge.recordEvent(handle, EVENT_GNSS_STATUS, 3, aux, if (top4.isEmpty()) 0.0 else top4.average())
        }
    }

    private val gpsListener = LocationListener { onLocation(it) }
    private val networkListener = LocationListener { fix ->
        if (fix.elapsedRealtimeNanos - lastSatelliteFixNs >= 5_000_000_000L) {
            fix.removeSpeed()
            fix.removeBearing()
            onLocation(fix)
        }
    }

    @SuppressLint("MissingPermission") // The service starts only with fine location granted.
    fun start() {
        when (preset.motion) {
            is CapturePreset.Motion.DeviceMotion -> {
                register(Sensor.TYPE_ACCELEROMETER, 5_000)
                for (type in listOf(Sensor.TYPE_GRAVITY, Sensor.TYPE_GYROSCOPE, Sensor.TYPE_ROTATION_VECTOR, Sensor.TYPE_MAGNETIC_FIELD)) {
                    register(type, 10_000)
                }
            }
            is CapturePreset.Motion.Accelerometer -> register(Sensor.TYPE_ACCELEROMETER, 20_000)
            CapturePreset.Motion.None -> Unit
        }
        register(Sensor.TYPE_PRESSURE, 1_000_000)
        locationManager.requestLocationUpdates(LocationManager.GPS_PROVIDER, 1_000L, 0f, gpsListener, handler.looper)
        locationManager.registerGnssStatusCallback(gnssCallback, handler)
        if (locationManager.allProviders.contains(LocationManager.NETWORK_PROVIDER)) {
            locationManager.requestLocationUpdates(LocationManager.NETWORK_PROVIDER, 1_000L, 0f, networkListener, handler.looper)
        }
    }

    fun stop() {
        sensorManager.unregisterListener(this)
        locationManager.removeUpdates(gpsListener)
        locationManager.removeUpdates(networkListener)
        locationManager.unregisterGnssStatusCallback(gnssCallback)
    }

    companion object {
        /** DriveKit `EventKind.gnssStatus`. */
        const val EVENT_GNSS_STATUS = 24
    }

    private fun register(type: Int, periodUs: Int) {
        sensorManager.getDefaultSensor(type)?.let { sensorManager.registerListener(this, it, periodUs, handler) }
    }

    override fun onSensorChanged(event: SensorEvent) {
        val v = event.values
        when (event.sensor.type) {
            Sensor.TYPE_GRAVITY -> gravity = v.copyOf(3)
            Sensor.TYPE_GYROSCOPE -> rotationRate = v.copyOf(3)
            Sensor.TYPE_ROTATION_VECTOR -> attitude = Conventions.quaternion(v)
            Sensor.TYPE_MAGNETIC_FIELD -> magnetic = v.copyOf(3)
            Sensor.TYPE_ACCELEROMETER -> onAccelerometer(event.timestamp, v)
            Sensor.TYPE_PRESSURE -> onPressure(event.timestamp, v[0])
        }
    }

    override fun onAccuracyChanged(sensor: Sensor, accuracy: Int) {
        if (sensor.type == Sensor.TYPE_MAGNETIC_FIELD) magneticAccuracy = Conventions.magneticAccuracy(accuracy)
    }

    private fun onAccelerometer(timestampNs: Long, v: FloatArray) {
        val grid = grid ?: return
        val boot = timestampNs / 1e9
        when (preset.motion) {
            is CapturePreset.Motion.Accelerometer -> if (grid.take(timestampNs)) {
                DriveKitBridge.pushAccel(handle, boot, Conventions.toCoreMotion(v[0]), Conventions.toCoreMotion(v[1]), Conventions.toCoreMotion(v[2]))
            }
            is CapturePreset.Motion.DeviceMotion -> {
                val gravity = gravity ?: return // nothing to subtract until the fusion has started
                if (!grid.take(timestampNs)) return
                val values = FloatArray(16)
                for (i in 0..2) {
                    values[i] = Conventions.toCoreMotion(v[i] - gravity[i])
                    values[3 + i] = Conventions.toCoreMotion(gravity[i])
                    values[6 + i] = rotationRate[i]
                    values[13 + i] = magnetic[i]
                }
                attitude.copyInto(values, 9)
                DriveKitBridge.pushMotion(handle, boot, values, magneticAccuracy)
            }
            CapturePreset.Motion.None -> Unit
        }
    }

    /**
     * Fixed one-second windows: a window that closed on "1 s since its first sample" also took the next sample's
     * interval, so the records drifted to 1.12 s apart at the barometer's ~9 Hz.
     */
    private fun onPressure(timestampNs: Long, hPa: Float) {
        val second = timestampNs / 1_000_000_000L
        if (second != pressureSecond && pressureWindow.isNotEmpty()) {
            val mean = pressureWindow.average().toFloat()
            pressureWindow.clear()
            val first = firstPressure ?: mean.also { firstPressure = it }
            DriveKitBridge.pushAltitude(handle, pressureSecond + 0.5, SensorManager.getAltitude(first, mean), Conventions.toKPa(mean))
        }
        pressureSecond = second
        pressureWindow += hPa
    }

    private fun onLocation(fix: Location) {
        if (fix.provider == LocationManager.GPS_PROVIDER) lastSatelliteFixNs = fix.elapsedRealtimeNanos
        val msl = fix.hasMslAltitude()
        DriveKitBridge.pushLocation(
            handle,
            boot = fix.elapsedRealtimeNanos / 1e9,
            latitude = fix.latitude,
            longitude = fix.longitude,
            altitude = if (msl) fix.mslAltitudeMeters else fix.altitude,
            speed = if (fix.hasSpeed()) fix.speed else -1f,
            // Core Location reports no course when stopped.
            course = if (fix.hasBearing() && fix.speed > 0.5f) fix.bearing else -1f,
            horizontalAccuracy = if (fix.hasAccuracy()) fix.accuracy else -1f,
            verticalAccuracy = if (fix.hasVerticalAccuracy()) fix.verticalAccuracyMeters else -1f,
            speedAccuracy = if (fix.hasSpeedAccuracy()) fix.speedAccuracyMetersPerSecond else -1f,
            courseAccuracy = if (fix.hasBearingAccuracy()) fix.bearingAccuracyDegrees else -1f,
            flags = if (fix.isMock) 1 else 0, // LocationSample.Flags.simulatedBySoftware
        )
    }
}
