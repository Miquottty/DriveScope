package com.miquottty.drivescope.settings

import android.content.Context
import com.miquottty.drivescope.recording.CapturePreset

/** The app's few settings (iOS `@AppStorage`). */
class Prefs(context: Context) {
    private val prefs = context.getSharedPreferences("settings", Context.MODE_PRIVATE)

    var preset: CapturePreset
        get() = CapturePreset.fromRaw(prefs.getString("capturePreset", null))
        set(value) = prefs.edit().putString("capturePreset", value.raw).apply()

    /** Sound + haptic on the first satellite fix of a run (#37). */
    var satelliteChime: Boolean
        get() = prefs.getBoolean("satelliteChime", true)
        set(value) = prefs.edit().putBoolean("satelliteChime", value).apply()

    /** Debug: watchdog thresholds ÷10. */
    var fastWatchdog: Boolean
        get() = prefs.getBoolean("debugFastWatchdog", false)
        set(value) = prefs.edit().putBoolean("debugFastWatchdog", value).apply()
}
