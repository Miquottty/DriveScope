package com.miquottty.drivescope.sessions

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.OutlinedTextFieldDefaults
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.miquottty.drivescope.R
import com.miquottty.drivescope.Theme
import com.miquottty.drivescope.bridge.DriveKitBridge
import com.miquottty.drivescope.home.SessionFormat
import com.miquottty.drivescope.map.MapLibreView
import com.miquottty.drivescope.map.MapStyle
import com.miquottty.drivescope.map.Replay
import com.miquottty.drivescope.map.addRouteLayers
import com.miquottty.drivescope.map.clock
import com.miquottty.drivescope.map.fit
import com.miquottty.drivescope.map.load
import com.miquottty.drivescope.store.SessionMeta
import com.miquottty.drivescope.store.SessionStore
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.withContext
import org.json.JSONObject
import org.maplibre.android.maps.MapLibreMap
import java.time.Instant
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import java.util.Locale

/** Session Detail (mock artboard 4): route map, six metrics, log quality, places, notes, sections, Replay / Export. */
@Composable
fun SessionDetailScreen(store: SessionStore, id: String, onBack: () -> Unit, onReplay: () -> Unit) {
    val context = LocalContext.current
    val sessions by store.sessions.collectAsState()
    val meta = sessions.firstOrNull { it.id == id } ?: return
    val dir = store.directory(id)
    var replay by remember { mutableStateOf<Replay?>(null) }
    var map by remember { mutableStateOf<MapLibreMap?>(null) }
    var renaming by remember { mutableStateOf(false) }
    var deleting by remember { mutableStateOf(false) }
    var exporting by remember { mutableStateOf(false) }

    LaunchedEffect(id) {
        replay = withContext(Dispatchers.Default) {
            DriveKitBridge.configure(context.cacheDir.absolutePath)
            Replay.load(dir.absolutePath)
        }
    }
    LaunchedEffect(map, replay) {
        val m = map ?: return@LaunchedEffect
        val r = replay ?: return@LaunchedEffect
        m.load(MapStyle.DARK) { s ->
            addRouteLayers(s, r, withCar = false)
            m.fit(r, padding = 60)
        }
    }

    Column(Modifier.fillMaxSize().background(Theme.background).verticalScroll(rememberScrollState())) {
        Box(Modifier.fillMaxWidth().height(320.dp)) {
            if ((replay?.routeIndices?.size ?: 0) >= 2) MapLibreView(textureMode = true) { map = it } else NoRoute()
            Row(Modifier.fillMaxWidth().padding(12.dp), horizontalArrangement = Arrangement.SpaceBetween) {
                Round("‹", onBack)
                Round("🗑") { deleting = true }
            }
        }
        Column(Modifier.padding(20.dp), verticalArrangement = Arrangement.spacedBy(14.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text(
                    meta.title.ifEmpty { SessionFormat.date(meta.startedAt) }, color = Theme.textPrimary, fontSize = 26.sp,
                    fontWeight = FontWeight.Bold, modifier = Modifier.weight(1f, fill = false),
                )
                Text("  ✎", color = Theme.textSecondary, fontSize = 20.sp, modifier = Modifier.clickable { renaming = true })
            }
            Text(dateRange(meta), color = Theme.textSecondary, fontSize = 14.sp)
            MetricGrid(meta)
            LogQuality(meta)
            Places(meta)
            Notes(meta) { notes -> store.update(id) { it.copy(notes = notes) } }
            SectionsCard(meta)
            Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                BigButton("▶  " + stringResource(R.string.replay), filled = true, modifier = Modifier.weight(1f), onClick = onReplay)
                BigButton("⇪  " + stringResource(R.string.export), filled = false, modifier = Modifier.weight(1f)) { exporting = true }
            }
        }
    }
    if (renaming) RenameDialog(meta, onDismiss = { renaming = false }) { title ->
        // Empty → back to the automatic name (iOS "Leave empty to use the automatic name").
        store.update(id) { it.copy(title = title.ifEmpty { it.autoTitle }, titleIsUserEdited = title.isNotEmpty()) }
        renaming = false
    }
    if (deleting) AlertDialog(
        onDismissRequest = { deleting = false },
        title = { Text(stringResource(R.string.delete_title)) },
        text = { Text(stringResource(R.string.delete_body)) },
        confirmButton = { TextButton(onClick = { deleting = false; store.delete(id); onBack() }) { Text(stringResource(R.string.delete), color = Theme.rec) } },
        dismissButton = { TextButton(onClick = { deleting = false }) { Text(stringResource(R.string.cancel)) } },
        containerColor = Theme.surface,
    )
    if (exporting) ExportSheet(meta, dir, onDismiss = { exporting = false })
}

@Composable
private fun NoRoute() {
    Box(Modifier.fillMaxSize().background(Theme.surface), contentAlignment = Alignment.Center) {
        Text(stringResource(R.string.no_route_recorded), color = Theme.textSecondary, fontSize = 14.sp)
    }
}

@Composable
private fun Round(label: String, onClick: () -> Unit) {
    Box(Modifier.background(Theme.surface.copy(alpha = 0.85f), RoundedCornerShape(22.dp)).clickable(onClick = onClick).padding(horizontal = 16.dp, vertical = 10.dp)) {
        Text(label, color = Theme.textPrimary, fontSize = 18.sp)
    }
}

private fun dateRange(meta: SessionMeta): String {
    val zone = ZoneId.systemDefault()
    val day = DateTimeFormatter.ofPattern(if (Locale.getDefault().language == "ja") "M月d日(E)" else "EEE, MMM d", Locale.getDefault())
    val time = DateTimeFormatter.ofPattern("HH:mm")
    val start = Instant.ofEpochMilli((meta.startedAt * 1000).toLong()).atZone(zone)
    val end = meta.endedAt?.let { Instant.ofEpochMilli((it * 1000).toLong()).atZone(zone) }
    return "${day.format(start)} · ${time.format(start)}" + (end?.let { " – ${time.format(it)}" } ?: "")
}

@Composable
private fun MetricGrid(meta: SessionMeta) {
    val s = meta.summary
    val tiles = listOf(
        Triple(stringResource(R.string.metric_time), SessionFormat.duration(s.optDouble("duration", 0.0)), ""),
        Triple(stringResource(R.string.metric_distance), "%.1f".format(Locale.US, s.optDouble("distance", 0.0) / 1000), "km"),
        Triple(stringResource(R.string.metric_max), "%.0f".format(Locale.US, s.optDouble("maxSpeed", 0.0) * 3.6), "km/h"),
        Triple(stringResource(R.string.metric_avg), "%.0f".format(Locale.US, s.optDouble("avgSpeed", 0.0) * 3.6), "km/h"),
        Triple(stringResource(R.string.metric_gain), "+%.0f".format(Locale.US, s.optDouble("elevationGain", 0.0)), "m"),
        Triple(stringResource(R.string.metric_peak_g), "%.2f".format(Locale.US, s.optDouble("peakLateralG", 0.0)), ""),
    )
    Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
        for (row in tiles.chunked(3)) {
            Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                for ((i, tile) in row.withIndex()) {
                    Column(Modifier.weight(1f).background(Theme.surface, RoundedCornerShape(14.dp)).padding(12.dp)) {
                        Text(tile.first, color = Theme.textSecondary, fontSize = 12.sp)
                        Row(verticalAlignment = Alignment.Bottom) {
                            Text(tile.second, color = if (tile === tiles.last()) Theme.accent else Theme.textPrimary, fontSize = 24.sp, fontFamily = FontFamily.Monospace)
                            if (tile.third.isNotEmpty()) Text(tile.third, color = Theme.textSecondary, fontSize = 12.sp, modifier = Modifier.padding(start = 3.dp, bottom = 3.dp))
                        }
                    }
                }
            }
        }
    }
}

@Composable
private fun LogQuality(meta: SessionMeta) {
    val s = meta.summary
    Card(stringResource(R.string.log_quality)) {
        val lines = listOf(
            "GPS P50 %.1f m · P95 %.1f m".format(Locale.US, s.optDouble("gpsAccuracyP50", 0.0), s.optDouble("gpsAccuracyP95", 0.0)),
            "GAP MAX %.1f s".format(Locale.US, s.optDouble("maxLocationGap", 0.0)),
            "LOC %,d · MOT %,d · DROP %.1f %%".format(Locale.US, s.optInt("locationSampleCount"), s.optInt("motionSampleCount"), s.optDouble("motionDropRate", 0.0) * 100),
        )
        for (line in lines) Text(line, color = Theme.textPrimary, fontSize = 14.sp, fontFamily = FontFamily.Monospace)
    }
}

@Composable
private fun Places(meta: SessionMeta) {
    if (meta.places.isEmpty()) return
    Card(stringResource(R.string.places)) {
        for (place in meta.places) {
            val role = when (place.optString("role")) {
                "start" -> stringResource(R.string.place_start)
                "end" -> stringResource(R.string.place_end)
                "peakG" -> stringResource(R.string.metric_peak_g)
                else -> stringResource(R.string.place_via)
            }
            Row {
                Text(role, color = Theme.textSecondary, fontSize = 13.sp, modifier = Modifier.padding(end = 10.dp))
                Text(placeName(place), color = Theme.textPrimary, fontSize = 14.sp)
            }
        }
    }
}

private fun placeName(place: JSONObject): String =
    listOf("administrativeArea", "locality", "subLocality", "name").mapNotNull { place.optString(it).takeIf { v -> v.isNotEmpty() } }
        .distinct().joinToString(" ").ifEmpty { "%.5f, %.5f".format(Locale.US, place.optDouble("latitude"), place.optDouble("longitude")) }

@Composable
private fun Notes(meta: SessionMeta, onSave: (String) -> Unit) {
    var text by remember(meta.id) { mutableStateOf(meta.notes) }
    // Saved shortly after typing stops, as the iOS editor does on change.
    LaunchedEffect(text) {
        if (text == meta.notes) return@LaunchedEffect
        delay(600)
        onSave(text)
    }
    Card(stringResource(R.string.notes)) {
        OutlinedTextField(
            value = text, onValueChange = { text = it }, modifier = Modifier.fillMaxWidth(),
            placeholder = { Text(stringResource(R.string.add_notes), color = Theme.textTertiary) },
            colors = OutlinedTextFieldDefaults.colors(focusedTextColor = Theme.textPrimary, unfocusedTextColor = Theme.textPrimary, focusedBorderColor = Theme.accent, unfocusedBorderColor = Theme.divider),
        )
    }
}

@Composable
private fun SectionsCard(meta: SessionMeta) {
    val sections = (0 until meta.sections.length()).map { meta.sections.getJSONObject(it) }
    if (sections.isEmpty()) return
    Card(stringResource(R.string.sections)) {
        val corners = sections.count { it.optString("kind") == "corner" }
        val stops = sections.count { it.optString("kind") == "stop" }
        Text("${stringResource(R.string.corners)} $corners · ${stringResource(R.string.stops)} $stops", color = Theme.textSecondary, fontSize = 13.sp)
        for (section in sections.take(30)) {
            Row {
                Text(clock(section.optDouble("start")), color = Theme.textSecondary, fontSize = 13.sp, fontFamily = FontFamily.Monospace, modifier = Modifier.padding(end = 10.dp))
                Text(sectionName(section), color = Theme.textPrimary, fontSize = 14.sp, modifier = Modifier.weight(1f))
                val g = section.optDouble("peakLateralG")
                if (!g.isNaN() && !section.isNull("peakLateralG")) Text("%.2f G".format(Locale.US, g), color = Theme.accent, fontSize = 13.sp, fontFamily = FontFamily.Monospace)
            }
        }
    }
}

@Composable
fun Card(title: String, content: @Composable () -> Unit) {
    Column(Modifier.fillMaxWidth().background(Theme.surface, RoundedCornerShape(16.dp)).padding(16.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
        Text(title.uppercase(), color = Theme.textSecondary, fontSize = 12.sp, letterSpacing = 1.sp)
        content()
    }
}

@Composable
private fun BigButton(label: String, filled: Boolean, modifier: Modifier, onClick: () -> Unit) {
    Box(
        modifier.height(56.dp)
            .background(if (filled) Theme.accent else Theme.background, RoundedCornerShape(14.dp))
            .border(1.dp, if (filled) Theme.accent else Theme.divider, RoundedCornerShape(14.dp))
            .clickable(onClick = onClick),
        contentAlignment = Alignment.Center,
    ) { Text(label, color = if (filled) Theme.background else Theme.textPrimary, fontSize = 17.sp, fontWeight = FontWeight.SemiBold) }
}

@Composable
private fun RenameDialog(meta: SessionMeta, onDismiss: () -> Unit, onSave: (String) -> Unit) {
    var text by remember { mutableStateOf(if (meta.titleIsUserEdited) meta.title else "") }
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text(stringResource(R.string.rename)) },
        text = {
            Column {
                OutlinedTextField(value = text, onValueChange = { text = it }, placeholder = { Text(meta.title) }, singleLine = true)
                Text(stringResource(R.string.rename_hint), color = Theme.textSecondary, fontSize = 12.sp, modifier = Modifier.padding(top = 6.dp))
            }
        },
        confirmButton = { TextButton(onClick = { onSave(text.trim()) }) { Text(stringResource(R.string.save)) } },
        dismissButton = { TextButton(onClick = onDismiss) { Text(stringResource(R.string.cancel)) } },
        containerColor = Theme.surface,
    )
}
