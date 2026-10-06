package com.miquottty.drivescope.quality

import android.content.Context
import com.miquottty.drivescope.R
import org.json.JSONObject
import java.util.Locale

/** Names and payloads of `events.bin` records (iOS `EventFormat`; DriveKit `EventKind` raw values). */
object EventFormat {
    private val names = mapOf(
        1 to R.string.event_gps_lost, 2 to R.string.event_gps_resumed, 3 to R.string.event_motion_stalled,
        4 to R.string.event_motion_resumed, 5 to R.string.event_background, 6 to R.string.event_foreground,
        7 to R.string.event_watchdog, 8 to R.string.event_resumed_from_notification, 9 to R.string.event_calibration,
        10 to R.string.event_thermal, 11 to R.string.event_low_power, 12 to R.string.event_carplay_connected,
        13 to R.string.event_carplay_disconnected, 14 to R.string.event_screen_on, 15 to R.string.event_screen_off,
        16 to R.string.event_battery, 17 to R.string.event_battery_low, 18 to R.string.event_marker,
        19 to R.string.event_session_resumed, 20 to R.string.event_auto_resumed, 21 to R.string.event_mount_changed,
        22 to R.string.event_sync_beep, 23 to R.string.event_satellite_acquired, 24 to R.string.event_satellites,
    )

    fun name(context: Context, kind: Int): String = context.getString(names[kind] ?: R.string.event_unknown)

    fun value(context: Context, e: JSONObject): String {
        val aux = e.optLong("aux")
        val value = e.optDouble("value")
        return when (e.optInt("kind")) {
            1, 2, 3, 4, 19, 20, 23 -> "%.1f s".format(Locale.US, value)
            7 -> (if (aux == 0L) "GPS" else context.getString(R.string.home_motion)) + " · %.1f s".format(Locale.US, value)
            16 -> listOfNotNull(
                if (value >= 0) "${Math.round(value * 100)}%" else "—",
                when (aux.toInt()) { 1 -> context.getString(R.string.battery_unplugged); 2 -> context.getString(R.string.charging); 3 -> context.getString(R.string.battery_full); else -> null },
            ).joinToString(" · ")
            18 -> listOf("MARK", "SYNC", "HIGHLIGHT").getOrElse(aux.toInt()) { "aux $aux" } + " · " + source(context, e.optInt("source"))
            22 -> when (aux.toInt()) { 0 -> context.getString(R.string.route_speaker); 1 -> context.getString(R.string.route_wireless); else -> context.getString(R.string.route_other) } +
                " · +${Math.round(value * 1000)} ms"
            10 -> thermal(context, aux.toInt())
            11 -> context.getString(if (value == 0.0) R.string.off else R.string.on)
            24 -> "${aux and 0xFFFF}/${aux shr 16} · %.0f dB-Hz".format(Locale.US, value)
            else -> ""
        }
    }

    fun thermal(context: Context, state: Int) = context.getString(
        when (state) { 0 -> R.string.thermal_nominal; 1 -> R.string.thermal_fair; 2 -> R.string.thermal_serious; else -> R.string.thermal_critical },
    )

    private fun source(context: Context, source: Int) = context.getString(
        when (source) { 0 -> R.string.source_phone; 1 -> R.string.source_notification; 2 -> R.string.source_watch; else -> R.string.source_system },
    )
}
