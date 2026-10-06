package com.miquottty.drivescope.map

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Slider
import androidx.compose.material3.SliderDefaults
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableDoubleStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.runtime.withFrameNanos
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.miquottty.drivescope.R
import com.miquottty.drivescope.Theme
import com.miquottty.drivescope.bridge.DriveKitBridge
import com.miquottty.drivescope.hud.GMeter
import com.miquottty.drivescope.sessions.sectionName
import com.miquottty.drivescope.store.SessionMeta
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import org.maplibre.android.camera.CameraPosition
import org.maplibre.android.camera.CameraUpdateFactory
import org.maplibre.android.geometry.LatLng
import org.maplibre.android.maps.MapLibreMap
import org.maplibre.android.maps.Style
import org.maplibre.android.style.sources.GeoJsonSource
import org.maplibre.geojson.Feature
import org.maplibre.geojson.LineString
import org.maplibre.geojson.Point
import java.io.File
import java.util.Locale
import kotlin.math.abs

/** Timeline Replay (mock artboard 5): map with the played route and the car, the telemetry at the playhead, controls. */
@Composable
fun ReplayScreen(sessionDir: File, meta: SessionMeta?, onBack: () -> Unit) {
    val context = LocalContext.current
    var replay by remember { mutableStateOf<Replay?>(null) }
    var style by remember { mutableStateOf(MapStyle.DARK) }
    var map by remember { mutableStateOf<MapLibreMap?>(null) }
    var loadedStyle by remember { mutableStateOf<Style?>(null) }
    var t by remember { mutableDoubleStateOf(0.0) }
    var playing by remember { mutableStateOf(false) }
    var rate by remember { mutableDoubleStateOf(1.0) }
    var follow by remember { mutableStateOf(true) }
    var threeD by remember { mutableStateOf(false) }

    LaunchedEffect(sessionDir) {
        replay = withContext(Dispatchers.Default) {
            DriveKitBridge.configure(context.cacheDir.absolutePath)
            Replay.load(sessionDir.absolutePath)
        }
    }
    LaunchedEffect(map, style, replay) {
        val m = map ?: return@LaunchedEffect
        val r = replay ?: return@LaunchedEffect
        loadedStyle = null
        m.load(style) { s ->
            addRouteLayers(s, r, withCar = true)
            loadedStyle = s
            if (!follow) m.fit(r)
        }
    }
    LaunchedEffect(playing, rate) {
        if (!playing) return@LaunchedEffect
        var last = 0L
        while (playing) {
            withFrameNanos { now ->
                if (last != 0L) t = (t + (now - last) / 1e9 * rate).coerceAtMost(replay?.duration ?: 0.0)
                last = now
            }
            if (t >= (replay?.duration ?: 0.0)) playing = false
        }
    }
    var lastPlayed by remember { mutableDoubleStateOf(-1.0) }
    LaunchedEffect(t, loadedStyle, follow, threeD) {
        val s = loadedStyle ?: return@LaunchedEffect
        val r = replay?.takeIf { it.count >= 2 } ?: return@LaunchedEffect
        val f = r.sample(t)
        s.getSourceAs<GeoJsonSource>("car")?.setGeoJson(Feature.fromGeometry(Point.fromLngLat(f[2], f[1])).apply { addNumberProperty("course", f[4]) })
        // The played line follows at ~5 Hz of playback (a 20k-point line every frame would be wasteful).
        if (abs(t - lastPlayed) > 0.2 * maxOf(rate, 1.0) || t == 0.0) {
            lastPlayed = t
            val end = (t * Replay.HZ).toInt().coerceIn(1, r.count - 1)
            val played = r.routeIndices.filter { it <= end }.map { r.point(it) }
            if (played.size >= 2) s.getSourceAs<GeoJsonSource>("played")?.setGeoJson(LineString.fromLngLats(played + r.point(end)))
        }
        if (follow) {
            map?.moveCamera(
                CameraUpdateFactory.newCameraPosition(
                    CameraPosition.Builder().target(LatLng(f[1], f[2]))
                        .zoom(if (threeD) 16.5 else 15.5).bearing(if (threeD) f[4] else 0.0).tilt(if (threeD) 60.0 else 0.0).build(),
                ),
            )
        }
    }

    Column(Modifier.fillMaxSize().background(Theme.background)) {
        Box(Modifier.weight(1f).fillMaxWidth()) {
            MapLibreView { map = it }
            Row(Modifier.fillMaxWidth().padding(12.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                Chip("‹", false, onBack)
                Text(meta?.title.orEmpty(), color = Theme.textPrimary, fontSize = 15.sp, fontWeight = FontWeight.SemiBold, maxLines = 1, modifier = Modifier.weight(1f))
                Chip("FOLLOW", follow) { follow = !follow; if (!follow) replay?.let { r -> map?.fit(r) } }
                Chip("3D", threeD) { threeD = !threeD }
                Chip(style.label, false) { style = if (style == MapStyle.DARK) MapStyle.GSI else MapStyle.DARK }
            }
        }
        val r = replay
        if (r == null || r.count < 2) {
            Text(
                if (r == null) "…" else stringResource(R.string.no_route_recorded),
                color = Theme.textSecondary, modifier = Modifier.padding(20.dp),
            )
            return@Column
        }
        val f = r.sample(t)
        Column(Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 10.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Column(Modifier.weight(1f)) {
                    Row(verticalAlignment = Alignment.Bottom) {
                        Text("%.0f".format(Locale.US, f[3] * 3.6), color = Theme.textPrimary, fontSize = 44.sp, fontFamily = FontFamily.Monospace)
                        Text("km/h", color = Theme.textSecondary, fontSize = 14.sp, modifier = Modifier.padding(start = 6.dp, bottom = 8.dp))
                    }
                    Text(
                        "ALT %.0f m · LAT G %+.2f".format(Locale.US, f[5], f[6]),
                        color = Theme.textSecondary, fontSize = 13.sp, fontFamily = FontFamily.Monospace,
                    )
                    Text("${clock(t)} / ${clock(r.duration)}", color = Theme.textPrimary, fontSize = 13.sp, fontFamily = FontFamily.Monospace)
                }
                GMeter(f[6], f[8], Modifier.size(96.dp))
            }
            SpeedSparkline(r, t, meta) { t = it }
            Slider(
                value = t.toFloat(), valueRange = 0f..r.duration.toFloat(), onValueChange = { t = it.toDouble() },
                colors = SliderDefaults.colors(thumbColor = Theme.accent, activeTrackColor = Theme.accent),
            )
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                Chip(if (playing) "PAUSE" else "PLAY", playing) { if (t >= r.duration) t = 0.0; playing = !playing }
                for (x in listOf(1.0, 4.0, 16.0)) Chip("${x.toInt()}×", rate == x) { rate = x }
            }
            JumpChips(r, meta) { t = it }
        }
    }
}

/** Speed over the whole drive with marker ticks (iOS Replay's sparkline); a tap seeks there. */
@Composable
private fun SpeedSparkline(r: Replay, t: Double, meta: SessionMeta?, onSeek: (Double) -> Unit) {
    val maxSpeed = remember(r) { (0 until r.count step 5).maxOfOrNull { r.at(it, 3) }?.coerceAtLeast(1.0) ?: 1.0 }
    Canvas(
        Modifier.fillMaxWidth().height(48.dp).background(Theme.surface, RoundedCornerShape(8.dp))
            .pointerInput(r) { detectTapGestures { onSeek(it.x / size.width * r.duration) } },
    ) {
        val path = Path()
        val step = maxOf(1, r.count / 400)
        for (i in 0 until r.count step step) {
            val x = (r.at(i, 0) / r.duration * size.width).toFloat()
            val y = (size.height - r.at(i, 3) / maxSpeed * (size.height - 6)).toFloat()
            if (i == 0) path.moveTo(x, y) else path.lineTo(x, y)
        }
        drawPath(path, Theme.textSecondary, style = Stroke(1.5f * density))
        for ((elapsed, kind) in r.markerList) {
            val x = (elapsed / r.duration * size.width).toFloat()
            drawLine(markerColor(kind), Offset(x, 0f), Offset(x, size.height), 1.5f * density)
        }
        val x = (t / r.duration * size.width).toFloat()
        drawLine(Theme.accent, Offset(x, 0f), Offset(x, size.height), 2f * density)
    }
}

/** Markers and sections as chips that jump the playhead (iOS "Jumps to this marker / section"). */
@Composable
private fun JumpChips(r: Replay, meta: SessionMeta?, onSeek: (Double) -> Unit) {
    val sections = remember(meta) {
        val array = meta?.sections ?: return@remember emptyList()
        (0 until array.length()).map { array.getJSONObject(it) }
    }
    if (r.markerList.isEmpty() && sections.isEmpty()) return
    Row(Modifier.horizontalScroll(rememberScrollState()), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        for ((elapsed, kind) in r.markerList) {
            Text(
                "${listOf("MARK", "SYNC", "HIGHLIGHT").getOrElse(kind) { "MARK" }} ${clock(elapsed)}",
                color = markerColor(kind), fontSize = 12.sp, fontFamily = FontFamily.Monospace,
                modifier = Modifier.background(Theme.surface, RoundedCornerShape(8.dp)).clickable { onSeek(elapsed) }.padding(horizontal = 8.dp, vertical = 6.dp),
            )
        }
        for (section in sections) {
            Text(
                "${sectionName(section)} ${clock(section.optDouble("start"))}",
                color = Theme.textPrimary, fontSize = 12.sp,
                modifier = Modifier.background(Theme.surface, RoundedCornerShape(8.dp)).clickable { onSeek(section.optDouble("start")) }.padding(horizontal = 8.dp, vertical = 6.dp),
            )
        }
    }
}

private fun markerColor(kind: Int): Color = when (kind) {
    1 -> Theme.good
    2 -> Theme.accent
    else -> Theme.textPrimary
}

@Composable
fun Chip(label: String, selected: Boolean, onClick: () -> Unit) {
    Text(
        label, fontSize = 13.sp, fontWeight = FontWeight.Medium,
        color = if (selected) Theme.background else Theme.textPrimary,
        modifier = Modifier.background(if (selected) Theme.accent else Theme.surface, RoundedCornerShape(10.dp))
            .clickable(onClick = onClick).padding(horizontal = 12.dp, vertical = 8.dp),
    )
}

fun clock(seconds: Double): String {
    val s = maxOf(0, seconds.toInt())
    return if (s >= 3600) "%d:%02d:%02d".format(Locale.US, s / 3600, s % 3600 / 60, s % 60) else "%d:%02d".format(Locale.US, s / 60, s % 60)
}
