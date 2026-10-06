package com.miquottty.drivescope.home

import android.Manifest
import android.content.pm.PackageManager
import android.hardware.Sensor
import android.hardware.SensorManager
import android.location.LocationManager
import android.os.BatteryManager
import android.os.SystemClock
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.animation.animateColorAsState
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalLifecycleOwner
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import com.miquottty.drivescope.R
import com.miquottty.drivescope.Theme
import com.miquottty.drivescope.probe.GnssProbe
import com.miquottty.drivescope.recording.CapturePreset
import com.miquottty.drivescope.recording.RecordingService
import com.miquottty.drivescope.settings.Prefs
import com.miquottty.drivescope.store.SessionMeta
import com.miquottty.drivescope.store.SessionStore
import java.util.Locale

/** START's look before recording (#38): green READY once the Home search has satellites; START stays usable while amber. */
enum class StartReadiness { UNKNOWN, SEARCHING, READY }

/** Home / Ready (mock artboard 1). */
@Composable
fun HomeScreen(store: SessionStore, onOpenSettings: () -> Unit, onOpenSession: (SessionMeta) -> Unit, onShowAllSessions: () -> Unit) {
    val context = LocalContext.current
    val prefs = remember { Prefs(context) }
    var preset by remember { mutableStateOf(prefs.preset) }
    var hasLocation by remember { mutableStateOf(granted(context, Manifest.permission.ACCESS_FINE_LOCATION)) }
    val gnss = remember { GnssProbe(context.getSystemService(LocationManager::class.java)) }
    val satellites by gnss.snapshot.collectAsState()
    val sessions by store.sessions.collectAsState()

    // The Home search (#37 SatelliteProbe): GPS runs while Home is on screen and location is granted; never asks.
    val lifecycle = LocalLifecycleOwner.current.lifecycle
    DisposableEffect(lifecycle, hasLocation) {
        val observer = LifecycleEventObserver { _, event ->
            when (event) {
                Lifecycle.Event.ON_RESUME -> if (hasLocation) gnss.start()
                Lifecycle.Event.ON_PAUSE -> gnss.stop()
                else -> Unit
            }
        }
        lifecycle.addObserver(observer)
        if (hasLocation && lifecycle.currentState.isAtLeast(Lifecycle.State.RESUMED)) gnss.start()
        onDispose {
            lifecycle.removeObserver(observer)
            gnss.stop()
        }
    }
    // A satellite fix carries a Doppler speed (`LocationSample.isSatelliteFix`); none for 15 s → searching again.
    val fix = satellites.fix
    val readiness = when {
        !hasLocation -> StartReadiness.UNKNOWN
        fix != null && fix.hasSpeed() && (SystemClock.elapsedRealtimeNanos() - fix.elapsedRealtimeNanos) < 15_000_000_000L -> StartReadiness.READY
        else -> StartReadiness.SEARCHING
    }

    val permissions = rememberLauncherForActivityResult(ActivityResultContracts.RequestMultiplePermissions()) { result ->
        hasLocation = result[Manifest.permission.ACCESS_FINE_LOCATION] == true || granted(context, Manifest.permission.ACCESS_FINE_LOCATION)
        if (hasLocation) RecordingService.start(context, preset)
    }

    Column(
        Modifier.fillMaxSize().background(Theme.background).verticalScroll(rememberScrollState()).padding(horizontal = 20.dp),
    ) {
        Row(Modifier.fillMaxWidth().padding(top = 16.dp), verticalAlignment = Alignment.CenterVertically) {
            Text("DriveScope", color = Theme.textPrimary, fontSize = 22.sp, fontWeight = FontWeight.SemiBold, modifier = Modifier.weight(1f))
            Box(
                Modifier.size(44.dp).background(Theme.surface, CircleShape).clickable(onClick = onOpenSettings),
                contentAlignment = Alignment.Center,
            ) { Text("⚙", color = Theme.textSecondary, fontSize = 20.sp) }
        }
        SensorCard(hasLocation, satellites, readiness, preset)
        Column(Modifier.fillMaxWidth().padding(vertical = 28.dp), horizontalAlignment = Alignment.CenterHorizontally) {
            StartButton(readiness) {
                val needed = listOf(Manifest.permission.ACCESS_FINE_LOCATION, Manifest.permission.POST_NOTIFICATIONS)
                    .filterNot { granted(context, it) }
                if (needed.isEmpty()) RecordingService.start(context, preset) else permissions.launch(needed.toTypedArray())
            }
            PresetChip(preset) {
                preset = it
                prefs.preset = it
            }
            Text(
                stringResource(R.string.home_mount_hint), color = Theme.textSecondary, fontSize = 12.sp,
                textAlign = TextAlign.Center, modifier = Modifier.padding(top = 14.dp),
            )
        }
        RecentSessions(sessions.take(3), onOpenSession, onShowAllSessions)
        Spacer(Modifier.height(24.dp))
    }
}

private fun granted(context: android.content.Context, permission: String) =
    context.checkSelfPermission(permission) == PackageManager.PERMISSION_GRANTED

@Composable
private fun SensorCard(hasLocation: Boolean, s: com.miquottty.drivescope.probe.GnssSnapshot, readiness: StartReadiness, preset: CapturePreset) {
    val context = LocalContext.current
    val sensors = remember { context.getSystemService(SensorManager::class.java) }
    val battery = remember { context.getSystemService(BatteryManager::class.java) }
    Column(
        Modifier.fillMaxWidth().padding(top = 22.dp).background(Theme.surface, RoundedCornerShape(16.dp)).padding(16.dp),
        verticalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        Text(stringResource(R.string.home_sensor_status).uppercase(), color = Theme.textSecondary, fontSize = 12.sp, letterSpacing = 1.sp)
        Row {
            val gps = when {
                !hasLocation -> Triple(stringResource(R.string.home_gps_not_asked), Theme.textPrimary, stringResource(R.string.home_asked_on_start))
                readiness == StartReadiness.READY -> {
                    val a = s.fix?.accuracy?.toDouble() ?: 0.0
                    Triple("±%.1f m".format(Locale.US, a), if (a <= 10) Theme.good else Theme.textPrimary, "${s.used}/${s.visible} · %.0f dB".format(Locale.US, s.top4Cn0 ?: 0.0))
                }
                else -> Triple(stringResource(R.string.home_searching_satellites), Theme.accent, "${s.used}/${s.visible}")
            }
            StatusCell("GPS", gps.first, gps.second, gps.third, Modifier.weight(1f))
            val motion = preset.motion
            StatusCell(
                stringResource(R.string.home_motion), if (motion.hz > 0) "%.0f Hz".format(Locale.US, motion.hz) else stringResource(R.string.off),
                if (motion.hz > 0) Theme.good else Theme.textPrimary, null, Modifier.weight(1f),
            )
        }
        Row {
            val baro = sensors.getDefaultSensor(Sensor.TYPE_PRESSURE) != null
            StatusCell(
                stringResource(R.string.home_barometer), stringResource(if (baro) R.string.available else R.string.unavailable),
                if (baro) Theme.good else Theme.textPrimary, null, Modifier.weight(1f),
            )
            val level = battery.getIntProperty(BatteryManager.BATTERY_PROPERTY_CAPACITY)
            StatusCell(
                stringResource(R.string.home_power), if (level in 0..100) "$level%" else "—", Theme.textPrimary,
                if (battery.isCharging) stringResource(R.string.charging) else null, Modifier.weight(1f),
            )
        }
    }
}

@Composable
private fun StatusCell(label: String, value: String, tint: Color, detail: String?, modifier: Modifier) {
    Column(modifier, verticalArrangement = Arrangement.spacedBy(3.dp)) {
        Text(label.uppercase(), color = Theme.textSecondary, fontSize = 11.sp)
        Row(verticalAlignment = Alignment.Bottom) {
            Text(value, color = tint, fontSize = 18.sp, fontFamily = FontFamily.Monospace, fontWeight = FontWeight.Medium)
            if (detail != null) Text(detail, color = Theme.textSecondary, fontSize = 11.sp, modifier = Modifier.padding(start = 6.dp, bottom = 2.dp))
        }
    }
}

/** The START circle: amber, green with "READY · satellites locked" once the Home search has satellites (#38). */
@Composable
private fun StartButton(readiness: StartReadiness, onStart: () -> Unit) {
    val fill by animateColorAsState(if (readiness == StartReadiness.READY) Theme.good else Theme.accent, label = "start")
    val caption = when (readiness) {
        StartReadiness.UNKNOWN -> stringResource(R.string.start_record_drive)
        StartReadiness.SEARCHING -> stringResource(R.string.start_searching)
        StartReadiness.READY -> stringResource(R.string.start_ready)
    }
    Box(Modifier.size(208.dp).background(fill.copy(alpha = 0.08f), CircleShape), contentAlignment = Alignment.Center) {
        Column(
            Modifier.size(188.dp).background(fill, CircleShape).clickable(onClick = onStart),
            horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.Center,
        ) {
            Text("START", color = Theme.background, fontSize = 30.sp, fontWeight = FontWeight.SemiBold, letterSpacing = 2.sp)
            Text(caption, color = Theme.background.copy(alpha = 0.7f), fontSize = 12.sp, fontWeight = FontWeight.Medium)
        }
    }
}

@Composable
private fun PresetChip(preset: CapturePreset, onSelect: (CapturePreset) -> Unit) {
    var open by remember { mutableStateOf(false) }
    Box(Modifier.padding(top = 18.dp)) {
        Text(
            presetSummary(preset), color = Theme.textTertiary, fontSize = 12.sp, fontFamily = FontFamily.Monospace,
            modifier = Modifier.background(Theme.surface, RoundedCornerShape(12.dp)).clickable { open = true }.padding(horizontal = 10.dp, vertical = 4.dp),
        )
        DropdownMenu(expanded = open, onDismissRequest = { open = false }) {
            for (option in CapturePreset.entries) {
                DropdownMenuItem(text = { Text(presetSummary(option)) }, onClick = { onSelect(option); open = false })
            }
        }
    }
}

fun presetSummary(preset: CapturePreset) = when (val m = preset.motion) {
    CapturePreset.Motion.None -> "${preset.label} · GPS 1 Hz"
    is CapturePreset.Motion.Accelerometer -> "${preset.label} · ACC %.0f Hz".format(Locale.US, m.hz)
    is CapturePreset.Motion.DeviceMotion -> "${preset.label} · %.0f Hz".format(Locale.US, m.hz)
}

@Composable
private fun RecentSessions(sessions: List<SessionMeta>, onOpen: (SessionMeta) -> Unit, onShowAll: () -> Unit) {
    if (sessions.isEmpty()) return
    Row(verticalAlignment = Alignment.CenterVertically) {
        Text(stringResource(R.string.home_recent).uppercase(), color = Theme.textSecondary, fontSize = 12.sp, letterSpacing = 1.sp, modifier = Modifier.weight(1f))
        Text(stringResource(R.string.all_sessions), color = Theme.accent, fontSize = 13.sp, fontWeight = FontWeight.Medium, modifier = Modifier.clickable(onClick = onShowAll))
    }
    Column(Modifier.padding(top = 10.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
        for (session in sessions) SessionRow(session) { onOpen(session) }
    }
}

@Composable
fun SessionRow(session: SessionMeta, onClick: () -> Unit) {
    Row(
        Modifier.fillMaxWidth().background(Theme.surface, RoundedCornerShape(12.dp)).clickable(onClick = onClick).padding(horizontal = 14.dp, vertical = 12.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        RouteThumbnail(session.routePreview, dashed = session.state == SessionMeta.State.RECOVERED)
        Column(Modifier.padding(start = 12.dp).weight(1f)) {
            Text(session.title.ifEmpty { SessionFormat.date(session.startedAt) }, color = Theme.textPrimary, fontSize = 14.sp, fontWeight = FontWeight.Medium, maxLines = 1)
            Text(SessionFormat.line(session), color = Theme.textSecondary, fontSize = 12.sp, fontFamily = FontFamily.Monospace, maxLines = 1)
        }
    }
}

/** A session's downsampled route as a line (no map tiles), as iOS `RouteThumbnail`. */
@Composable
fun RouteThumbnail(points: List<Pair<Double, Double>>, dashed: Boolean = false, modifier: Modifier = Modifier.size(56.dp, 44.dp)) {
    // Fewer than two usable fixes (indoors: only Wi‑Fi positions) would leave an empty square that looks broken.
    if (points.size < 2) {
        Box(modifier.background(Theme.background, RoundedCornerShape(8.dp)), contentAlignment = Alignment.Center) {
            Text(stringResource(R.string.thumbnail_no_gps), color = Theme.textTertiary, fontSize = 10.sp, textAlign = TextAlign.Center)
        }
        return
    }
    Canvas(modifier.background(Theme.background, RoundedCornerShape(8.dp))) {
        val lats = points.map { it.first }
        val lons = points.map { it.second }
        val midLat = Math.toRadians((lats.min() + lats.max()) / 2)
        val w = (lons.max() - lons.min()) * Math.cos(midLat)
        val h = lats.max() - lats.min()
        val inset = 7 * density
        val scale = minOf((size.width - 2 * inset) / maxOf(w, 1e-9), (size.height - 2 * inset) / maxOf(h, 1e-9))
        fun at(p: Pair<Double, Double>) = Offset(
            (size.width / 2 + ((p.second - (lons.min() + lons.max()) / 2) * Math.cos(midLat)) * scale).toFloat(),
            (size.height / 2 - (p.first - (lats.min() + lats.max()) / 2) * scale).toFloat(),
        )
        val path = Path().apply {
            at(points.first()).let { moveTo(it.x, it.y) }
            for (p in points.drop(1)) at(p).let { lineTo(it.x, it.y) }
        }
        drawPath(
            path, Theme.accent,
            style = Stroke(width = 2.2f * density, pathEffect = if (dashed) androidx.compose.ui.graphics.PathEffect.dashPathEffect(floatArrayOf(6f, 6f)) else null),
        )
        drawCircle(Theme.textSecondary, radius = 2.5f * density, center = at(points.first()))
    }
}
