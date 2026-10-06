package com.miquottty.drivescope.quality

import android.text.format.Formatter
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
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
import com.miquottty.drivescope.map.clock
import com.miquottty.drivescope.sessions.Card
import com.miquottty.drivescope.store.SessionStore
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import org.json.JSONObject
import java.util.Locale

/** Quality (PLAN §11, iOS `QualityView`): DriveKit's `QualityReport` for one session, with every event. */
@Composable
fun QualityScreen(store: SessionStore) {
    val context = LocalContext.current
    val sessions by store.sessions.collectAsState()
    var selected by remember { mutableStateOf(sessions.firstOrNull()?.id) }
    var picking by remember { mutableStateOf(false) }
    var report by remember { mutableStateOf<JSONObject?>(null) }
    LaunchedEffect(selected) {
        val id = selected ?: return@LaunchedEffect
        report = null
        report = withContext(Dispatchers.Default) {
            DriveKitBridge.configure(context.cacheDir.absolutePath)
            JSONObject(DriveKitBridge.qualityJson(store.directory(id).absolutePath))
        }
    }
    Column(Modifier.fillMaxSize().background(Theme.background).verticalScroll(rememberScrollState()).padding(20.dp), verticalArrangement = Arrangement.spacedBy(14.dp)) {
        Text(stringResource(R.string.tab_quality), color = Theme.textPrimary, fontSize = 28.sp, fontWeight = FontWeight.Bold)
        val meta = sessions.firstOrNull { it.id == selected }
        if (meta == null) {
            Text(stringResource(R.string.sessions_empty_title), color = Theme.textSecondary)
            return@Column
        }
        Box {
            Column(Modifier.fillMaxWidth().background(Theme.surface, RoundedCornerShape(16.dp)).clickable { picking = true }.padding(16.dp)) {
                Text(meta.title.ifEmpty { SessionFormat.date(meta.startedAt) } + "  ▾", color = Theme.textPrimary, fontSize = 17.sp, fontWeight = FontWeight.SemiBold)
                Text(SessionFormat.line(meta), color = Theme.textSecondary, fontSize = 13.sp, fontFamily = FontFamily.Monospace)
            }
            DropdownMenu(expanded = picking, onDismissRequest = { picking = false }) {
                for (s in sessions.take(30)) {
                    DropdownMenuItem(text = { Text(s.title.ifEmpty { SessionFormat.date(s.startedAt) } + " · " + SessionFormat.date(s.startedAt)) }, onClick = { selected = s.id; picking = false })
                }
            }
        }
        val r = report ?: return@Column
        val none = "—"
        fun num(v: Double?, digits: Int = 1) = v?.takeUnless { it.isNaN() }?.let { "%.${digits}f".format(Locale.US, it) } ?: none
        fun opt(o: JSONObject, key: String) = if (o.isNull(key) || !o.has(key)) null else o.optDouble(key)
        val location = r.getJSONObject("location")
        val motion = r.getJSONObject("motion")
        val altitude = r.getJSONObject("altitude")
        Card(stringResource(R.string.q_location)) {
            Row2(stringResource(R.string.q_samples), "%,d".format(Locale.US, location.optInt("count")))
            Row2(stringResource(R.string.q_mean_interval), num(opt(location, "meanInterval"), 2) + " s")
            Row2(stringResource(R.string.q_max_gap), num(opt(location, "maxGap")) + " s")
            Row2(stringResource(R.string.q_accuracy_p50), num(r.optDouble("accuracyP50")) + " m")
            Row2(stringResource(R.string.q_accuracy_p95), num(r.optDouble("accuracyP95")) + " m")
            Row2(stringResource(R.string.q_satellite_fix_after), opt(r, "firstSatelliteFix")?.let { num(it) + " s" } ?: none)
        }
        Card(stringResource(R.string.home_motion)) {
            Row2(stringResource(R.string.q_samples), if (motion.optInt("count") > 0) "%,d".format(Locale.US, motion.optInt("count")) else none)
            Row2(stringResource(R.string.q_effective_preset), num(opt(motion, "effectiveHz")) + " / " + num(r.optDouble("motionHz"), 0) + " Hz")
            Row2(stringResource(R.string.q_dropped), opt(r, "motionDropRate")?.let { num(it * 100) + " %" } ?: none)
        }
        Card(stringResource(R.string.q_battery)) {
            Row2(stringResource(R.string.q_overall), opt(r, "batteryOverall")?.let { num(it) + " %/h" } ?: none)
            Row2(stringResource(R.string.q_screen_on), opt(r, "batteryScreenOn")?.let { num(it) + " %/h" } ?: none)
            Row2(stringResource(R.string.q_screen_off), opt(r, "batteryScreenOff")?.let { num(it) + " %/h" } ?: none)
            if (opt(r, "batteryOverall") == null) Text(stringResource(R.string.q_battery_not_enough), color = Theme.textSecondary, fontSize = 12.sp)
        }
        Card(stringResource(R.string.q_altitude)) {
            Row2(stringResource(R.string.q_samples), "%,d".format(Locale.US, altitude.optInt("count")))
            Row2(stringResource(R.string.q_mean_interval), num(opt(altitude, "meanInterval"), 2) + " s")
        }
        Card(stringResource(R.string.q_storage)) {
            Row2(stringResource(R.string.q_on_disk), Formatter.formatShortFileSize(context, r.optLong("bytesOnDisk")))
        }
        Card(stringResource(R.string.q_thermal)) {
            Row2(stringResource(R.string.q_max_state), opt(r, "maxThermalState")?.let { EventFormat.thermal(context, it.toInt()) } ?: none)
        }
        val events = r.getJSONArray("events")
        Card(stringResource(R.string.q_events)) {
            for (i in 0 until events.length()) {
                val e = events.getJSONObject(i)
                Row(Modifier.fillMaxWidth()) {
                    Text(clock(e.optDouble("elapsed")), color = Theme.textSecondary, fontSize = 13.sp, fontFamily = FontFamily.Monospace, modifier = Modifier.padding(end = 10.dp))
                    Text(EventFormat.name(context, e.optInt("kind")), color = Theme.textPrimary, fontSize = 13.sp, modifier = Modifier.weight(1f))
                    Text(EventFormat.value(context, e), color = Theme.textSecondary, fontSize = 13.sp, fontFamily = FontFamily.Monospace)
                }
            }
        }
    }
}

@Composable
private fun Row2(label: String, value: String) {
    Row(Modifier.fillMaxWidth()) {
        Text(label, color = Theme.textSecondary, fontSize = 14.sp, modifier = Modifier.weight(1f))
        Text(value, color = Theme.textPrimary, fontSize = 14.sp, fontFamily = FontFamily.Monospace)
    }
}
