package com.miquottty.drivescope.recording

/**
 * Android → the iOS sample conventions DriveKit stores (docs/ANDROID_SPIKE.md, measured on the Pixel 7).
 * Same axes on both (x right, y top, z out of the screen); Android reports the reaction force in m/s², Core Motion
 * the acceleration in g, so every axis is ×(−1 / g).
 */
object Conventions {
    const val G = 9.80665f

    /** m/s² (Android) → g with Core Motion's sign. */
    fun toCoreMotion(androidMs2: Float): Float = -androidMs2 / G

    /** hPa → kPa (CMAltitudeData.pressure). */
    fun toKPa(hPa: Float): Float = hPa / 10f

    /** `SENSOR_STATUS_*` 0…3 → `CMMagneticFieldCalibrationAccuracy` −1…2. */
    fun magneticAccuracy(androidStatus: Int): Int = (androidStatus - 1).coerceIn(-1, 2)

    /** Rotation vector (x, y, z[, w]) → quaternion (w, x, y, z). Android's world frame is east-north-up. */
    fun quaternion(v: FloatArray): FloatArray {
        val w = if (v.size >= 4) v[3] else Math.sqrt(maxOf(0.0, 1.0 - v[0] * v[0] - v[1] * v[1] - (v[2] * v[2]).toDouble())).toFloat()
        return floatArrayOf(w, v[0], v[1], v[2])
    }

    /**
     * A fixed-period grid over a faster sensor: Android rounds requests (a 50 Hz request arrives at ~59 Hz), so
     * samples are taken from a 200 Hz stream on the preset's period, with slack for delivery jitter.
     */
    class Grid(hz: Double) {
        private val period = (1e9 / hz).toLong()
        private val slack = period / 5
        private var next = 0L

        /** True when the event at `timestampNs` is the grid's next sample. */
        fun take(timestampNs: Long): Boolean {
            if (next == 0L) next = timestampNs
            if (timestampNs < next - slack) return false
            next += period
            // After a stall the grid restarts instead of bursting to catch up.
            if (timestampNs >= next) next = timestampNs + period
            return true
        }
    }
}
