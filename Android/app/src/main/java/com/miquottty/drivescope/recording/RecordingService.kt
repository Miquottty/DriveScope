package com.miquottty.drivescope.recording

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.hardware.SensorManager
import android.location.LocationManager
import android.os.Handler
import android.os.HandlerThread
import android.os.IBinder
import android.os.PowerManager
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import java.io.File

/**
 * Keeps a recording alive with the screen off: a location-type foreground service (its ongoing notification is
 * Android's counterpart of the Live Activity) plus a partial wake lock, since non-wake-up sensors stop delivering
 * once the CPU suspends.
 */
class RecordingService : Service() {
    private var thread: HandlerThread? = null
    private var recorder: SessionRecorder? = null
    private var wakeLock: PowerManager.WakeLock? = null
    private var ticker: Runnable? = null

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == ACTION_STOP) {
            stopSelf()
            return START_NOT_STICKY
        }
        if (recorder != null) return START_NOT_STICKY
        startForeground(NOTIFICATION_ID, notification(), ServiceInfo.FOREGROUND_SERVICE_TYPE_LOCATION)
        wakeLock = getSystemService(PowerManager::class.java)
            .newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "DriveScope:recording")
            .apply { acquire(4 * 60 * 60 * 1000L) }
        val thread = HandlerThread("recorder").also { it.start() }
        this.thread = thread
        val handler = Handler(thread.looper)
        handler.post {
            val recorder = SessionRecorder(
                File(getExternalFilesDir(null), "Sessions"),
                getSystemService(SensorManager::class.java),
                getSystemService(LocationManager::class.java),
                handler,
            )
            recorder.start()
            this.recorder = recorder
            val tick = object : Runnable {
                override fun run() {
                    state.value = recorder.status()
                    handler.postDelayed(this, 500)
                }
            }
            ticker = tick
            handler.post(tick)
        }
        return START_NOT_STICKY
    }

    override fun onDestroy() {
        val thread = thread
        val recorder = recorder
        if (thread != null) {
            val handler = Handler(thread.looper)
            ticker?.let { handler.removeCallbacks(it) }
            handler.post {
                recorder?.stop()
                state.value = null
                thread.quitSafely()
            }
        }
        wakeLock?.takeIf { it.isHeld }?.release()
        super.onDestroy()
    }

    private fun notification(): Notification {
        val manager = getSystemService(NotificationManager::class.java)
        manager.createNotificationChannel(NotificationChannel(CHANNEL, "Recording", NotificationManager.IMPORTANCE_LOW))
        return Notification.Builder(this, CHANNEL)
            .setSmallIcon(android.R.drawable.ic_menu_mylocation)
            .setContentTitle("REC · DriveScope")
            .setContentText("Recording GPS, motion and pressure")
            .setOngoing(true)
            .build()
    }

    companion object {
        private const val CHANNEL = "recording"
        private const val NOTIFICATION_ID = 1
        private const val ACTION_STOP = "stop"

        private val state = MutableStateFlow<RecordingStatus?>(null)
        /** Non-null while recording. */
        val status: StateFlow<RecordingStatus?> = state.asStateFlow()

        fun start(context: Context) {
            context.startForegroundService(Intent(context, RecordingService::class.java))
        }

        fun stop(context: Context) {
            context.startService(Intent(context, RecordingService::class.java).setAction(ACTION_STOP))
        }
    }
}
