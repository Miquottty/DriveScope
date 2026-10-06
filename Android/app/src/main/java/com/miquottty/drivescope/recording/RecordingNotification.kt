package com.miquottty.drivescope.recording

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import com.miquottty.drivescope.MainActivity
import com.miquottty.drivescope.R
import com.miquottty.drivescope.bridge.Snapshot
import java.util.Locale

/**
 * The ongoing notification — Android's counterpart of the Lock Screen Live Activity (PLAN §10): REC with a running
 * clock, speed, distance and GPS, and MARK / STOP buttons. Updated every 2 s, like the Live Activity.
 */
class RecordingNotification(private val context: Context) {
    private val manager = context.getSystemService(NotificationManager::class.java)

    init {
        manager.createNotificationChannel(
            NotificationChannel(CHANNEL, context.getString(R.string.notification_channel_recording), NotificationManager.IMPORTANCE_LOW),
        )
        manager.createNotificationChannel(
            NotificationChannel(ALERTS, context.getString(R.string.notification_channel_alerts), NotificationManager.IMPORTANCE_HIGH),
        )
    }

    /** Watchdog stage "notified" (2 min without GPS / motion), as iOS's local notification (PLAN §9.3). */
    fun alert(stream: Int, silenceSeconds: Double) {
        val minutes = maxOf(1, (silenceSeconds / 60).toInt())
        val (title, body) = if (stream == 0) {
            context.getString(R.string.alert_gps_title) to context.getString(R.string.alert_gps_body, minutes)
        } else {
            context.getString(R.string.alert_motion_title) to context.getString(R.string.alert_motion_body, minutes)
        }
        val open = PendingIntent.getActivity(context, 3, Intent(context, MainActivity::class.java), PendingIntent.FLAG_IMMUTABLE)
        manager.notify(
            ALERT_ID + stream,
            Notification.Builder(context, ALERTS).setSmallIcon(android.R.drawable.stat_notify_error)
                .setContentTitle(title).setContentText(body).setContentIntent(open).setAutoCancel(true).build(),
        )
    }

    fun cancelAlert(stream: Int) = manager.cancel(ALERT_ID + stream)

    fun build(state: RecorderState): Notification {
        val s = state.snapshot
        val speed = s.speed?.let { "%.0f km/h".format(Locale.US, maxOf(0.0, it) * 3.6) } ?: "— km/h"
        val distance = "%.1f km".format(Locale.US, s.distance / 1000)
        val gps = when (s.gpsStatus) {
            Snapshot.GpsStatus.GOOD -> s.horizontalAccuracy?.let { "GPS ±%.0f m".format(Locale.US, it) } ?: "GPS"
            Snapshot.GpsStatus.ACQUIRING -> "ACQUIRING"
            Snapshot.GpsStatus.SEARCHING -> "GPS SEARCHING"
        }
        val open = PendingIntent.getActivity(
            context, 0, Intent(context, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP),
            PendingIntent.FLAG_IMMUTABLE,
        )
        return Notification.Builder(context, CHANNEL)
            .setSmallIcon(android.R.drawable.ic_menu_mylocation)
            .setContentTitle(if (s.gpsStatus == Snapshot.GpsStatus.SEARCHING) "GPS SEARCHING" else "REC · ${state.preset.label}")
            .setContentText("$speed · $distance · $gps")
            .setWhen(state.startedAtMillis.takeIf { it > 0 } ?: System.currentTimeMillis())
            .setUsesChronometer(true)
            .setShowWhen(true)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setContentIntent(open)
            .setColor(context.getColor(R.color.accent))
            .addAction(action("MARK", RecordingService.ACTION_MARK, RecordingService.MARK_MARK, 1))
            .addAction(action("STOP", ACTION_STOP_FROM_NOTIFICATION, 0, 2))
            .build()
    }

    fun update(state: RecorderState) {
        if (state.phase == RecorderState.Phase.RECORDING) manager.notify(ID, build(state))
    }

    private fun action(title: String, action: String, kind: Int, code: Int): Notification.Action {
        val intent = Intent(context, RecordingService::class.java).setAction(action)
            .putExtra(RecordingService.EXTRA_KIND, kind)
            .putExtra(RecordingService.EXTRA_SOURCE, RecordingService.SOURCE_NOTIFICATION)
        val pending = PendingIntent.getService(context, code, intent, PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
        return Notification.Action.Builder(null, title, pending).build()
    }

    companion object {
        const val ID = 1
        private const val ALERT_ID = 10
        private const val CHANNEL = "recording"
        private const val ALERTS = "alerts"
        const val ACTION_STOP_FROM_NOTIFICATION = "stop"
    }
}
