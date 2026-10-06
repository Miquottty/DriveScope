package com.miquottty.drivescope.home

import com.miquottty.drivescope.store.SessionMeta
import java.time.Instant
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import java.time.format.FormatStyle
import java.util.Locale

/** Session list lines (iOS `SessionFormat`): "Oct 6 · 34:49 · 12.9 km · max 102". */
object SessionFormat {
    fun date(unix: Double, locale: Locale = Locale.getDefault()): String =
        DateTimeFormatter.ofLocalizedDate(FormatStyle.MEDIUM).withLocale(locale)
            .format(Instant.ofEpochMilli((unix * 1000).toLong()).atZone(ZoneId.systemDefault()))

    fun duration(seconds: Double): String {
        val s = maxOf(0, seconds.toInt())
        return if (s >= 3600) "%d:%02d:%02d".format(Locale.US, s / 3600, s % 3600 / 60, s % 60) else "%02d:%02d".format(Locale.US, s / 60, s % 60)
    }

    fun line(session: SessionMeta): String {
        val summary = session.summary
        val parts = mutableListOf(date(session.startedAt))
        if (summary.has("duration")) parts += duration(summary.optDouble("duration"))
        if (summary.has("distance")) parts += "%.1f km".format(Locale.US, summary.optDouble("distance") / 1000)
        if (summary.has("maxSpeed")) parts += "max %.0f".format(Locale.US, summary.optDouble("maxSpeed") * 3.6)
        if (session.state == SessionMeta.State.RECORDING) parts += "REC"
        return parts.joinToString(" · ")
    }
}
