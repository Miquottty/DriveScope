package com.miquottty.drivescope.recording

/** DriveKit's `CapturePreset` (raw values are written in the manifest — keep them). PLAN §2.2.1. */
enum class CapturePreset(val raw: String, val label: String, val motion: Motion) {
    GPS_ONLY("gpsOnly", "GPS Only", Motion.None),
    ECO("eco", "Eco", Motion.Accelerometer(10.0)),
    VLOG("vlog", "Vlog", Motion.DeviceMotion(25.0)),
    LOGGER("logger", "Logger", Motion.DeviceMotion(50.0)),
    LAB("lab", "Lab", Motion.DeviceMotion(100.0));

    sealed interface Motion {
        val hz: Double

        data object None : Motion {
            override val hz = 0.0
        }

        data class Accelerometer(override val hz: Double) : Motion
        data class DeviceMotion(override val hz: Double) : Motion
    }

    companion object {
        val DEFAULT = LOGGER
        fun fromRaw(raw: String?) = entries.firstOrNull { it.raw == raw } ?: DEFAULT
    }
}
