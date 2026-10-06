package com.miquottty.drivescope.recording

import android.app.Service
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.ServiceInfo
import android.hardware.SensorManager
import android.location.LocationManager
import android.os.BatteryManager
import android.os.Build
import android.os.Handler
import android.os.HandlerThread
import android.os.IBinder
import android.os.PowerManager
import android.os.SystemClock
import com.miquottty.drivescope.bridge.DriveKitBridge
import com.miquottty.drivescope.bridge.Snapshot
import com.miquottty.drivescope.settings.Prefs
import com.miquottty.drivescope.store.SessionStore
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import java.util.TimeZone

/** What the screens observe (iOS `RecordingController.phase` + `LiveTelemetry`). */
data class RecorderState(
    val phase: Phase = Phase.IDLE,
    val preset: CapturePreset = CapturePreset.DEFAULT,
    val sessionID: String? = null,
    /** Wall time of START (ms), for the notification's chronometer. */
    val startedAtMillis: Long = 0,
    val snapshot: Snapshot = Snapshot(),
    val lastError: String? = null,
) {
    enum class Phase { IDLE, RECORDING, STOPPING }
}

/**
 * One recording at a time, kept alive with the screen off: a location-type foreground service (its notification is
 * Android's Live Activity) and a partial wake lock — non-wake-up sensors stop once the CPU suspends.
 * DriveKit's engine does the recording (`DriveKitBridge`); this service feeds it (`SensorPump`) and reports the
 * device's state as events, as iOS's `DeviceEventMonitor` / `BatteryMonitor` do.
 */
class RecordingService : Service() {
    private var thread: HandlerThread? = null
    private var handler: Handler? = null
    private var handle = 0L
    private var pump: SensorPump? = null
    private var wakeLock: PowerManager.WakeLock? = null
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private lateinit var notifications: RecordingNotification
    private var lastNotification = 0L
    private var lastBattery = 0L

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        notifications = RecordingNotification(this)
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_START -> start(CapturePreset.fromRaw(intent.getStringExtra(EXTRA_PRESET)))
            ACTION_STOP -> post { stopRecording() }
            ACTION_MARK -> post { mark(intent.getIntExtra(EXTRA_KIND, 0), intent.getIntExtra(EXTRA_SOURCE, SOURCE_PHONE)) }
            ACTION_SYNC -> post {
                DriveKitBridge.sync(
                    handle, intent.getDoubleExtra(EXTRA_ONSET, Double.NaN), intent.getDoubleExtra(EXTRA_LATENCY, 0.0),
                    intent.getIntExtra(EXTRA_ROUTE, 2), intent.getDoubleExtra(EXTRA_PRESSED_AT, 0.0),
                )
            }
            ACTION_EVENT -> post {
                DriveKitBridge.recordEvent(
                    handle, intent.getIntExtra(EXTRA_KIND, 0), intent.getIntExtra(EXTRA_SOURCE, SOURCE_SYSTEM),
                    intent.getIntExtra(EXTRA_AUX, 0), intent.getDoubleExtra(EXTRA_VALUE, 0.0),
                )
            }
            ACTION_ROTATE -> post { DriveKitBridge.rotateMount(handle) }
        }
        return START_NOT_STICKY
    }

    private fun post(block: () -> Unit) {
        handler?.post { if (handle != 0L) block() }
    }

    private fun start(preset: CapturePreset) {
        if (handle != 0L || thread != null) return
        val startedAt = System.currentTimeMillis()
        startForeground(RecordingNotification.ID, notifications.build(RecorderState(preset = preset, startedAtMillis = startedAt)), ServiceInfo.FOREGROUND_SERVICE_TYPE_LOCATION)
        wakeLock = getSystemService(PowerManager::class.java)
            .newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "DriveScope:recording")
            .apply { acquire(12 * 60 * 60 * 1000L) }
        val thread = HandlerThread("recorder").also { it.start() }
        val handler = Handler(thread.looper)
        this.thread = thread
        this.handler = handler
        handler.post {
            DriveKitBridge.configure(cacheDir.absolutePath)
            val sensors = getSystemService(SensorManager::class.java)
            val locations = getSystemService(LocationManager::class.java)
            handle = DriveKitBridge.recorderStart(
                SessionStore.forContext(this).root.absolutePath, preset.raw, appVersion(), Build.MODEL,
                "Android ${Build.VERSION.RELEASE}", TimeZone.getDefault().id,
                hasGyroscope = sensors.getDefaultSensor(android.hardware.Sensor.TYPE_GYROSCOPE) != null,
                hasBarometer = sensors.getDefaultSensor(android.hardware.Sensor.TYPE_PRESSURE) != null,
                fastWatchdog = Prefs(this).fastWatchdog,
            )
            if (handle == 0L) {
                state.update { it.copy(phase = RecorderState.Phase.IDLE, lastError = "DriveKit could not start the session") }
                finish()
                return@post
            }
            val sessionID = DriveKitBridge.recorderSessionID(handle)
            pump = SensorPump(handle, preset, sensors, locations, handler).also { it.start() }
            state.value = RecorderState(RecorderState.Phase.RECORDING, preset, sessionID, startedAt)
            recordDeviceState()
            registerDeviceEvents()
            handler.post(tick)
        }
    }

    /** 10 Hz: HUD snapshot; 2 s: notification; 1 s: watchdog; 5 min: battery (PLAN §9.4). */
    private val tick = object : Runnable {
        override fun run() {
            if (handle == 0L) return
            val snapshot = Snapshot.decode(DriveKitBridge.snapshot(handle))
            state.update { it.copy(snapshot = snapshot) }
            val now = SystemClock.elapsedRealtime()
            if (now - lastNotification >= 2_000) {
                lastNotification = now
                notifications.update(state.value)
                // Escalations are notified in A-S3; until then they only go to events.bin (the engine writes them).
                DriveKitBridge.drainWatchdog(handle)
            }
            if (now - lastBattery >= 5 * 60_000) {
                lastBattery = now
                recordBattery()
            }
            handler?.postDelayed(this, 100)
        }
    }

    private fun mark(kind: Int, source: Int) {
        DriveKitBridge.mark(handle, kind, source, 0.0)
    }

    private fun stopRecording() {
        if (handle == 0L) return
        val preset = state.value.preset
        state.update { it.copy(phase = RecorderState.Phase.STOPPING) }
        handler?.removeCallbacks(tick)
        pump?.stop()
        pump = null
        unregisterDeviceEvents()
        val result = org.json.JSONObject(DriveKitBridge.recorderStop(handle))
        handle = 0L
        val id = result.optString("sessionID")
        val store = SessionStore.forContext(this)
        scope.launch {
            SessionFinisher(this@RecordingService, store).finish(id, preset, result)
            state.value = RecorderState(lastError = null)
            finish()
        }
    }

    private fun finish() {
        handler?.post {
            thread?.quitSafely()
            thread = null
            handler = null
        }
        wakeLock?.takeIf { it.isHeld }?.release()
        stopForeground(STOP_FOREGROUND_REMOVE)
        stopSelf()
    }

    // MARK: Device events (EventKind raw values, DriveKit Session.swift)

    private val deviceReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context, intent: Intent) {
            when (intent.action) {
                Intent.ACTION_SCREEN_ON -> post { DriveKitBridge.recordEvent(handle, EVENT_SCREEN_ON, SOURCE_SYSTEM, 0, 0.0) }
                Intent.ACTION_SCREEN_OFF -> post { DriveKitBridge.recordEvent(handle, EVENT_SCREEN_OFF, SOURCE_SYSTEM, 0, 0.0) }
                PowerManager.ACTION_POWER_SAVE_MODE_CHANGED -> post { recordLowPower() }
            }
        }
    }

    private val thermalListener = PowerManager.OnThermalStatusChangedListener { status ->
        post { DriveKitBridge.recordEvent(handle, EVENT_THERMAL, SOURCE_SYSTEM, thermalState(status), 0.0) }
    }

    private fun registerDeviceEvents() {
        registerReceiver(deviceReceiver, IntentFilter().apply {
            addAction(Intent.ACTION_SCREEN_ON)
            addAction(Intent.ACTION_SCREEN_OFF)
            addAction(PowerManager.ACTION_POWER_SAVE_MODE_CHANGED)
        })
        getSystemService(PowerManager::class.java).addThermalStatusListener(mainExecutor, thermalListener)
    }

    private fun unregisterDeviceEvents() {
        runCatching { unregisterReceiver(deviceReceiver) }
        getSystemService(PowerManager::class.java).removeThermalStatusListener(thermalListener)
    }

    /** At START, as iOS: Low Power Mode and battery (the thermal listener reports the current state when it registers). */
    private fun recordDeviceState() {
        recordLowPower()
        lastBattery = SystemClock.elapsedRealtime()
        recordBattery()
    }

    private fun recordLowPower() {
        val on = getSystemService(PowerManager::class.java).isPowerSaveMode
        DriveKitBridge.recordEvent(handle, EVENT_LOW_POWER, SOURCE_SYSTEM, 0, if (on) 1.0 else 0.0)
    }

    /** value = level 0…1, aux = `UIDevice.BatteryState` (1 unplugged, 2 charging, 3 full). */
    private fun recordBattery() {
        val battery = registerReceiver(null, IntentFilter(Intent.ACTION_BATTERY_CHANGED)) ?: return
        val level = battery.getIntExtra(BatteryManager.EXTRA_LEVEL, -1)
        val scale = battery.getIntExtra(BatteryManager.EXTRA_SCALE, 100)
        val state = when (battery.getIntExtra(BatteryManager.EXTRA_STATUS, -1)) {
            BatteryManager.BATTERY_STATUS_CHARGING -> 2
            BatteryManager.BATTERY_STATUS_FULL -> 3
            BatteryManager.BATTERY_STATUS_DISCHARGING, BatteryManager.BATTERY_STATUS_NOT_CHARGING -> 1
            else -> 0
        }
        DriveKitBridge.recordEvent(handle, EVENT_BATTERY, SOURCE_SYSTEM, state, if (level >= 0) level.toDouble() / scale else -1.0)
    }

    private fun appVersion() = packageManager.getPackageInfo(packageName, 0).versionName ?: "android"

    override fun onDestroy() {
        // Killed mid-run (rare: the service is foreground): close the streams so the session stays readable.
        if (handle != 0L) {
            pump?.stop()
            runCatching { DriveKitBridge.recorderStop(handle) }
            handle = 0L
        }
        super.onDestroy()
    }

    companion object {
        private const val ACTION_START = "start"
        private const val ACTION_STOP = "stop"
        const val ACTION_MARK = "mark"
        private const val ACTION_SYNC = "sync"
        private const val ACTION_EVENT = "event"
        private const val ACTION_ROTATE = "rotate"
        private const val EXTRA_PRESET = "preset"
        const val EXTRA_KIND = "kind"
        const val EXTRA_SOURCE = "source"
        private const val EXTRA_AUX = "aux"
        private const val EXTRA_VALUE = "value"
        private const val EXTRA_ONSET = "onset"
        private const val EXTRA_LATENCY = "latency"
        private const val EXTRA_ROUTE = "route"
        private const val EXTRA_PRESSED_AT = "pressedAt"

        const val SOURCE_PHONE = 0
        /** EventSource.liveActivity: the notification is Android's Live Activity. */
        const val SOURCE_NOTIFICATION = 1
        const val SOURCE_SYSTEM = 3

        const val MARK_MARK = 0
        const val MARK_SYNC = 1
        const val MARK_HIGHLIGHT = 2

        const val EVENT_BACKGROUND = 5
        const val EVENT_FOREGROUND = 6
        private const val EVENT_THERMAL = 10
        private const val EVENT_LOW_POWER = 11
        private const val EVENT_SCREEN_ON = 14
        private const val EVENT_SCREEN_OFF = 15
        private const val EVENT_BATTERY = 16

        private val state = MutableStateFlow(RecorderState())
        val recorder: StateFlow<RecorderState> = state.asStateFlow()

        fun start(context: Context, preset: CapturePreset) {
            if (state.value.phase != RecorderState.Phase.IDLE) return
            state.value = RecorderState(RecorderState.Phase.RECORDING, preset)
            context.startForegroundService(Intent(context, RecordingService::class.java).setAction(ACTION_START).putExtra(EXTRA_PRESET, preset.raw))
        }

        fun stop(context: Context) = send(context, Intent(context, RecordingService::class.java).setAction(ACTION_STOP))

        fun mark(context: Context, kind: Int) =
            send(context, Intent(context, RecordingService::class.java).setAction(ACTION_MARK).putExtra(EXTRA_KIND, kind))

        /** SYNC with its beep (`onsetBoot` NaN when audio failed: the marker falls back to now). */
        fun sync(context: Context, onsetBoot: Double, latency: Double, route: Int) = send(
            context,
            Intent(context, RecordingService::class.java).setAction(ACTION_SYNC).putExtra(EXTRA_ONSET, onsetBoot)
                .putExtra(EXTRA_LATENCY, latency).putExtra(EXTRA_ROUTE, route).putExtra(EXTRA_PRESSED_AT, 0.0),
        )

        fun event(context: Context, kind: Int, aux: Int = 0, value: Double = 0.0, source: Int = SOURCE_SYSTEM) = send(
            context,
            Intent(context, RecordingService::class.java).setAction(ACTION_EVENT).putExtra(EXTRA_KIND, kind)
                .putExtra(EXTRA_AUX, aux).putExtra(EXTRA_VALUE, value).putExtra(EXTRA_SOURCE, source),
        )

        fun rotateMount(context: Context) = send(context, Intent(context, RecordingService::class.java).setAction(ACTION_ROTATE))

        private fun send(context: Context, intent: Intent) {
            if (state.value.phase == RecorderState.Phase.RECORDING) context.startService(intent)
        }

        /** `PowerManager.THERMAL_STATUS_*` → `ProcessInfo.ThermalState` (0 nominal … 3 critical). */
        fun thermalState(status: Int): Int = when (status) {
            PowerManager.THERMAL_STATUS_NONE, PowerManager.THERMAL_STATUS_LIGHT -> 0
            PowerManager.THERMAL_STATUS_MODERATE -> 1
            PowerManager.THERMAL_STATUS_SEVERE -> 2
            else -> 3
        }
    }
}
