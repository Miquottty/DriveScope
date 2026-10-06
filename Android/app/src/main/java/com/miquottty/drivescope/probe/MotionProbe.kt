package com.miquottty.drivescope.probe

import android.hardware.Sensor
import android.hardware.SensorEvent
import android.hardware.SensorEventListener
import android.hardware.SensorManager
import android.os.SystemClock
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow

/** One sensor's latest reading and its measured delivery rate. */
data class SensorReading(
    val values: FloatArray,
    val hz: Double,
    /** elapsedRealtimeNanos() − event.timestamp at delivery, ms: ~0 when events use the elapsedRealtime clock. */
    val clockLagMs: Double,
)

/**
 * Raw Android motion sensors at the iOS Logger rate (50 Hz), to pin down how they map onto the iOS sample
 * conventions (units, signs, clock) before anything is recorded in the shared `.bin` format.
 */
class MotionProbe(private val sensorManager: SensorManager) : SensorEventListener {
    enum class Kind(val type: Int, val label: String) {
        ACCELEROMETER(Sensor.TYPE_ACCELEROMETER, "ACC m/s²"),
        GRAVITY(Sensor.TYPE_GRAVITY, "GRAVITY m/s²"),
        LINEAR(Sensor.TYPE_LINEAR_ACCELERATION, "LINEAR m/s²"),
        GYROSCOPE(Sensor.TYPE_GYROSCOPE, "GYRO rad/s"),
        ROTATION(Sensor.TYPE_ROTATION_VECTOR, "ROT VEC"),
        MAGNETIC(Sensor.TYPE_MAGNETIC_FIELD, "MAG µT"),
        PRESSURE(Sensor.TYPE_PRESSURE, "PRESSURE hPa"),
    }

    private val state = MutableStateFlow<Map<Kind, SensorReading>>(emptyMap())
    val readings: StateFlow<Map<Kind, SensorReading>> = state.asStateFlow()

    private val windows = mutableMapOf<Kind, ArrayDeque<Long>>()
    /** Raw events of every kind while the orientation check is sampling, keyed by kind. */
    private var capture: MutableMap<Kind, MutableList<FloatArray>>? = null

    val available: List<Kind> get() = Kind.entries.filter { sensorManager.getDefaultSensor(it.type) != null }

    fun start() {
        for (kind in available) {
            // 20 000 µs = 50 Hz, the iOS Logger preset. The barometer delivers at its own pace.
            sensorManager.registerListener(this, sensorManager.getDefaultSensor(kind.type), 20_000)
        }
    }

    fun stop() {
        sensorManager.unregisterListener(this)
    }

    fun beginCapture() {
        capture = mutableMapOf()
    }

    /** Means of everything captured since `beginCapture`. */
    fun endCapture(): Map<Kind, FloatArray> {
        val captured = capture ?: return emptyMap()
        capture = null
        return captured.mapValues { (_, rows) ->
            FloatArray(rows.first().size) { i -> rows.sumOf { it[i].toDouble() }.toFloat() / rows.size }
        }
    }

    override fun onSensorChanged(event: SensorEvent) {
        val kind = Kind.entries.firstOrNull { it.type == event.sensor.type } ?: return
        val now = SystemClock.elapsedRealtimeNanos()
        val window = windows.getOrPut(kind) { ArrayDeque() }
        window.addLast(event.timestamp)
        while (window.isNotEmpty() && event.timestamp - window.first() > 1_000_000_000L) window.removeFirst()
        val hz = if (window.size > 1) (window.size - 1) / ((window.last() - window.first()) / 1e9) else 0.0
        capture?.getOrPut(kind) { mutableListOf() }?.add(event.values.copyOf())
        state.value = state.value + (kind to SensorReading(event.values.copyOf(), hz, (now - event.timestamp) / 1e6))
    }

    override fun onAccuracyChanged(sensor: Sensor, accuracy: Int) = Unit
}
