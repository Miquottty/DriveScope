package com.miquottty.drivescope

import android.hardware.SensorManager
import android.location.LocationManager
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.BackHandler
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Text
import androidx.compose.ui.Alignment
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
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
import com.miquottty.drivescope.home.RecoveryDialog
import com.miquottty.drivescope.quality.QualityScreen
import com.miquottty.drivescope.store.SessionMeta
import com.miquottty.drivescope.hud.RecordingHud
import com.miquottty.drivescope.map.ReplayScreen
import com.miquottty.drivescope.sessions.SessionDetailScreen
import com.miquottty.drivescope.sessions.SessionsScreen
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
    data object Tabs : Route
    data object Settings : Route
    data object Probe : Route
    data class Detail(val id: String) : Route
    data class Replay(val dir: File, val id: String?) : Route
}

private enum class Tab(val icon: String, val label: Int) {
    RECORD("◉", R.string.tab_record),
    SESSIONS("☰", R.string.tab_sessions),
    QUALITY("∿", R.string.tab_quality),
}

@Composable
private fun AppRoot(store: SessionStore) {
    val recorder by RecordingService.recorder.collectAsState()
    var route by remember { mutableStateOf<Route>(Route.Tabs) }
    var tab by remember { mutableStateOf(Tab.RECORD) }
    // The HUD takes over the screen while a run is on (iOS shows it full screen too).
    if (recorder.phase != RecorderState.Phase.IDLE) {
        RecordingHud(recorder)
        return
    }
    BackHandler(enabled = route != Route.Tabs) {
        route = when (val r = route) {
            is Route.Replay -> r.id?.let { Route.Detail(it) } ?: Route.Probe
            Route.Probe -> Route.Settings
            else -> Route.Tabs
        }
    }
    Box(Modifier.fillMaxSize().background(Theme.background).safeDrawingPadding()) {
        when (val r = route) {
            Route.Tabs -> Column(Modifier.fillMaxSize()) {
                Box(Modifier.weight(1f)) {
                    when (tab) {
                        Tab.RECORD -> HomeScreen(
                            store, onOpenSettings = { route = Route.Settings },
                            onOpenSession = { route = Route.Detail(it.id) },
                            onShowAllSessions = { tab = Tab.SESSIONS },
                        )
                        Tab.SESSIONS -> SessionsScreen(store) { route = Route.Detail(it.id) }
                        Tab.QUALITY -> QualityScreen(store)
                    }
                }
                TabBar(tab) { tab = it }
                // A run the app never finished (process killed, reboot) — offered once per launch, as iOS's sheet.
                val sessions by store.sessions.collectAsState()
                var handled by remember { mutableStateOf(setOf<String>()) }
                sessions.firstOrNull { it.state == SessionMeta.State.RECORDING && it.id !in handled }?.let { unfinished ->
                    RecoveryDialog(store, unfinished) { handled = handled + unfinished.id }
                }
            }
            Route.Settings -> SettingsScreen(onBack = { route = Route.Tabs }, onOpenProbe = { route = Route.Probe })
            Route.Probe -> DeveloperProbe(onOpenMap = { route = Route.Replay(it, null) }, onBack = { route = Route.Settings })
            is Route.Detail -> SessionDetailScreen(
                store, r.id, onBack = { route = Route.Tabs },
                onReplay = { route = Route.Replay(store.directory(r.id), r.id) },
            )
            is Route.Replay -> ReplayScreen(r.dir, r.id?.let(store::meta)) {
                route = r.id?.let { Route.Detail(it) } ?: Route.Probe
            }
        }
    }
}

/** The bottom tab bar (iOS's Record / Sessions tabs), a floating pill like the mock. */
@Composable
private fun TabBar(selected: Tab, onSelect: (Tab) -> Unit) {
    Row(
        Modifier.fillMaxWidth().padding(horizontal = 48.dp, vertical = 10.dp)
            .background(Theme.surface, RoundedCornerShape(32.dp)).padding(6.dp),
    ) {
        for (tab in Tab.entries) {
            val active = tab == selected
            Column(
                Modifier.weight(1f).background(if (active) Theme.background else Theme.surface, RoundedCornerShape(26.dp))
                    .clickable { onSelect(tab) }.padding(vertical = 8.dp),
                horizontalAlignment = Alignment.CenterHorizontally,
            ) {
                Text(tab.icon, color = if (active) Theme.accent else Theme.textSecondary, fontSize = 20.sp)
                Text(stringResource(tab.label), color = if (active) Theme.accent else Theme.textSecondary, fontSize = 12.sp, fontWeight = FontWeight.Medium)
            }
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
