package com.miquottty.drivescope.probe

import android.content.Context
import android.os.SystemClock
import android.util.Log
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeDrawingPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.miquottty.drivescope.Theme
import com.miquottty.drivescope.recording.RecordingService
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.util.Locale

/** S0 spike screen 1: satellites, the raw fix, every motion sensor, and the orientation check. */
@Composable
fun ProbeScreen(gnss: GnssProbe, motion: MotionProbe) {
    val satellites by gnss.snapshot.collectAsState()
    val readings by motion.readings.collectAsState()
    Column(
        Modifier
            .fillMaxSize()
            .background(Theme.background)
            .safeDrawingPadding()
            .verticalScroll(rememberScrollState())
            .padding(16.dp),
        verticalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        Text("DriveScope · sensor probe", color = Theme.textPrimary, fontSize = 22.sp, fontWeight = FontWeight.SemiBold)
        RecordingCard()
        SatelliteCard(satellites)
        FixCard(satellites)
        MotionCard(motion, readings)
        OrientationCheck(motion)
    }
}

@Composable
private fun Card(title: String, content: @Composable () -> Unit) {
    Column(
        Modifier
            .fillMaxWidth()
            .background(Theme.surface, RoundedCornerShape(16.dp))
            .padding(16.dp),
        verticalArrangement = Arrangement.spacedBy(6.dp),
    ) {
        Text(title.uppercase(), color = Theme.textSecondary, fontSize = 12.sp, letterSpacing = 1.sp)
        content()
    }
}

@Composable
private fun Row(label: String, value: String, tint: Color = Theme.textPrimary) {
    Row(Modifier.fillMaxWidth()) {
        Text(label, color = Theme.textSecondary, fontSize = 13.sp, modifier = Modifier.width(132.dp))
        Text(value, color = tint, fontSize = 13.sp, fontFamily = FontFamily.Monospace)
    }
}

private fun f(value: Double?, digits: Int = 1) = value?.let { String.format(Locale.US, "%.${digits}f", it) } ?: "—"

/** S0 spike screen 2: a Logger-preset recording into the iOS session format (pulled with adb, read by drivekit-cli). */
@Composable
private fun RecordingCard() {
    val context = LocalContext.current
    val status by RecordingService.status.collectAsState()
    Card("Recording · Logger") {
        val s = status
        if (s == null) {
            Row("state", "idle")
        } else {
            Row("state", "REC ${f(s.elapsed, 0)} s", Theme.rec)
            Row("samples", "loc ${s.locations} · mot ${s.motion} · alt ${s.altitudes}")
            Row("session", s.sessionID.take(8))
        }
        Button(
            colors = ButtonDefaults.buttonColors(
                containerColor = if (s == null) Theme.accent else Theme.rec, contentColor = Theme.background,
            ),
            onClick = { if (s == null) RecordingService.start(context) else RecordingService.stop(context) },
        ) { Text(if (s == null) "START" else "STOP") }
    }
}

@Composable
private fun SatelliteCard(s: GnssSnapshot) {
    Card("Satellites") {
        val locked = s.used >= 4
        Row("used / visible", "${s.used} / ${s.visible}", if (locked) Theme.good else Theme.accent)
        Row("top-4 C/N0", "${f(s.top4Cn0)} dB-Hz")
        Row("by constellation", s.usedByConstellation.entries.joinToString { "${it.key} ${it.value}" }.ifEmpty { "—" })
        Row("on L5 / E5a", "${s.usedOnL5}")
        Row("first fix", s.firstFixSeconds?.let { "${f(it)} s" } ?: "waiting · ${f(s.secondsSinceStart, 0)} s")
    }
}

@Composable
private fun FixCard(s: GnssSnapshot) {
    val fix = s.fix
    Card("GPS provider fix") {
        Row("fixes", "${s.fixCount}")
        Row("lat, lon", fix?.let { "${f(it.latitude, 6)}, ${f(it.longitude, 6)}" } ?: "—")
        Row("h accuracy", fix?.let { "± ${f(it.accuracy.toDouble())} m" } ?: "—")
        Row("speed", fix?.takeIf { it.hasSpeed() }?.let { "${f(it.speed * 3.6)} km/h ± ${f(it.speedAccuracyMetersPerSecond.toDouble())} m/s" } ?: "—")
        Row("bearing", fix?.takeIf { it.hasBearing() }?.let { "${f(it.bearing.toDouble())}°" } ?: "—")
        Row("altitude", fix?.takeIf { it.hasAltitude() }?.let { "${f(it.altitude)} m ± ${f(it.verticalAccuracyMeters.toDouble())}" } ?: "—")
        Row("fix age", fix?.let { "${f((SystemClock.elapsedRealtimeNanos() - it.elapsedRealtimeNanos) / 1e9)} s" } ?: "—")
    }
}

@Composable
private fun MotionCard(motion: MotionProbe, readings: Map<MotionProbe.Kind, SensorReading>) {
    Card("Motion · 50 Hz requested") {
        for (kind in MotionProbe.Kind.entries) {
            val r = readings[kind]
            val values = r?.values?.take(4)?.joinToString(" ") { String.format(Locale.US, "%+.3f", it) }
            Row(kind.label, if (kind in motion.available) values ?: "…" else "not available")
            if (r != null) Row("", "${f(r.hz)} Hz · clock lag ${f(r.clockLagMs)} ms", Theme.textTertiary)
        }
    }
}

/** Three poses, 5 s each: the means pin the axis and sign mapping to Core Motion (written to a JSON file too). */
@Composable
private fun OrientationCheck(motion: MotionProbe) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    var status by remember { mutableStateOf("Not run") }
    var running by remember { mutableStateOf(false) }
    Card("Orientation check") {
        Text(status, color = Theme.textPrimary, fontSize = 13.sp)
        Spacer(Modifier.width(1.dp))
        Button(
            enabled = !running,
            colors = ButtonDefaults.buttonColors(containerColor = Theme.accent, contentColor = Theme.background),
            onClick = {
                running = true
                scope.launch {
                    val results = JSONArray()
                    for (pose in POSES) {
                        for (n in 3 downTo 1) {
                            status = "${pose.second} … $n"
                            delay(1_000)
                        }
                        status = "${pose.second} · measuring 5 s"
                        motion.beginCapture()
                        delay(5_000)
                        val means = motion.endCapture()
                        results.put(JSONObject().apply {
                            put("pose", pose.first)
                            for ((kind, mean) in means) put(kind.name, JSONArray(mean.map { it.toDouble() }))
                        })
                    }
                    val file = save(context, results)
                    status = "Done · ${file.name}"
                    running = false
                }
            },
        ) { Text("Run (flat → upright → right side down)") }
    }
}

private val POSES = listOf(
    "flat-face-up" to "Lay flat, screen up",
    "upright-portrait" to "Hold upright, screen facing you",
    "right-side-down" to "Landscape, right edge down",
)

private fun save(context: Context, results: JSONArray): File {
    val dir = context.getExternalFilesDir(null) ?: context.filesDir
    val file = File(dir, "orientation-${System.currentTimeMillis()}.json")
    file.writeText(results.toString(2))
    Log.i("DriveScopeProbe", "orientation check → ${file.absolutePath}\n$results")
    return file
}
