package com.miquottty.drivescope

import android.hardware.SensorManager
import android.location.LocationManager
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.BackHandler
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.safeDrawingPadding
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import com.miquottty.drivescope.bridge.DriveKitBridge
import com.miquottty.drivescope.home.HomeScreen
import com.miquottty.drivescope.hud.RecordingHud
import com.miquottty.drivescope.map.MapScreen
import com.miquottty.drivescope.probe.GnssProbe
import com.miquottty.drivescope.probe.MotionProbe
import com.miquottty.drivescope.probe.ProbeScreen
import com.miquottty.drivescope.recording.RecorderState
import com.miquottty.drivescope.recording.RecordingService
import com.miquottty.drivescope.settings.SettingsScreen
import com.miquottty.drivescope.store.SessionStore
import java.io.File

class MainActivity : ComponentActivity() {
    private lateinit var store: SessionStore

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        DriveKitBridge.configure(cacheDir.absolutePath)
        store = SessionStore.forContext(this)
        store.reload()
        setContent { DriveScopeTheme { AppRoot(store) } }
    }

    // iOS records appWillEnterForeground / appDidEnterBackground during a run (PLAN §9.4).
    override fun onStart() {
        super.onStart()
        RecordingService.event(this, RecordingService.EVENT_FOREGROUND)
    }

    override fun onStop() {
        RecordingService.event(this, RecordingService.EVENT_BACKGROUND)
        super.onStop()
    }
}

private sealed interface Route {
    data object Home : Route
    data object Settings : Route
    data object Probe : Route
    data class Map(val session: File) : Route
}

@Composable
private fun AppRoot(store: SessionStore) {
    val recorder by RecordingService.recorder.collectAsState()
    var route by remember { mutableStateOf<Route>(Route.Home) }
    // The HUD takes over the screen while a run is on (iOS shows it full screen too).
    if (recorder.phase != RecorderState.Phase.IDLE) {
        RecordingHud(recorder)
        return
    }
    BackHandler(enabled = route != Route.Home) {
        route = if (route is Route.Map) Route.Probe else Route.Home
    }
    Box(Modifier.fillMaxSize().background(Theme.background).safeDrawingPadding()) {
        when (val r = route) {
            Route.Home -> HomeScreen(
                store, onOpenSettings = { route = Route.Settings },
                onOpenSession = { route = Route.Map(store.directory(it.id)) },
            )
            Route.Settings -> SettingsScreen(onBack = { route = Route.Home }, onOpenProbe = { route = Route.Probe })
            Route.Probe -> DeveloperProbe(onOpenMap = { route = Route.Map(it) }, onBack = { route = Route.Settings })
            is Route.Map -> MapScreen(r.session, onBack = { route = Route.Home })
        }
    }
}

/** The S0 spike's sensor probe, kept as a developer screen; its sensors run only while it shows. */
@Composable
private fun DeveloperProbe(onOpenMap: (File) -> Unit, onBack: () -> Unit) {
    val context = androidx.compose.ui.platform.LocalContext.current
    val gnss = remember { GnssProbe(context.getSystemService(LocationManager::class.java)) }
    val motion = remember { MotionProbe(context.getSystemService(SensorManager::class.java)) }
    DisposableEffect(Unit) {
        motion.start()
        runCatching { gnss.start() }
        onDispose {
            motion.stop()
            gnss.stop()
        }
    }
    ProbeScreen(gnss, motion, onOpenMap, onBack)
}
