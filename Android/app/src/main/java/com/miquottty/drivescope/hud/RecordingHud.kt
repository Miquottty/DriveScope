package com.miquottty.drivescope.hud

import android.view.HapticFeedbackConstants
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.RowScope
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeDrawingPadding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalView
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.TextUnit
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.miquottty.drivescope.R
import com.miquottty.drivescope.Theme
import com.miquottty.drivescope.audio.SyncBeeper
import com.miquottty.drivescope.bridge.Snapshot
import com.miquottty.drivescope.recording.RecorderState
import com.miquottty.drivescope.recording.RecordingService
import com.miquottty.drivescope.settings.Prefs
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.util.Locale

/** Recording HUD (mock artboards 2 / 8): portrait or two columns in landscape, black, readable from the mount. */
@Composable
fun RecordingHud(state: RecorderState) {
    val context = LocalContext.current
    val view = LocalView.current
    val scope = rememberCoroutineScope()
    val beeper = remember { SyncBeeper() }
    val s = state.snapshot
    val saving = state.phase == RecorderState.Phase.STOPPING

    // The HUD is glanced at on a mount for hours; the screen stays on while it shows.
    DisposableEffect(Unit) {
        view.keepScreenOn = true
        onDispose { view.keepScreenOn = false }
    }
    // First satellite fix of the run: chime + haptic (#37), until then the fixes are Wi‑Fi ones without speed.
    var chimedFor by remember { mutableStateOf<String?>(null) }
    LaunchedEffect(s.satelliteFixAfter, state.sessionID) {
        if (s.satelliteFixAfter != null && chimedFor != state.sessionID && Prefs(context).satelliteChime) {
            chimedFor = state.sessionID
            view.performHapticFeedback(HapticFeedbackConstants.CONFIRM)
            withContext(Dispatchers.IO) { beeper.playChime() }
        }
    }

    val actions = HudActions(
        onMark = { RecordingService.mark(context, RecordingService.MARK_MARK) },
        onHighlight = { RecordingService.mark(context, RecordingService.MARK_HIGHLIGHT) },
        onSync = {
            scope.launch {
                val beep = withContext(Dispatchers.IO) { beeper.playSync() }
                RecordingService.sync(context, beep.onsetBoot, beep.latency, beep.route)
            }
        },
        onStop = { RecordingService.stop(context) },
    )
    BoxWithConstraints(Modifier.fillMaxSize().background(Theme.hudBackground).safeDrawingPadding()) {
        if (maxWidth > maxHeight) {
            Landscape(s, state, saving, actions, maxWidth, maxHeight)
        } else {
            Portrait(s, state, saving, actions, maxWidth)
        }
    }
}

private class HudActions(val onMark: () -> Unit, val onHighlight: () -> Unit, val onSync: () -> Unit, val onStop: () -> Unit)

@Composable
private fun Portrait(s: Snapshot, state: RecorderState, saving: Boolean, actions: HudActions, width: Dp) {
    val speedSize = minOf(180f, (width.value - 100) / 1.8f).sp
    Column(Modifier.fillMaxSize().padding(horizontal = 20.dp, vertical = 4.dp), horizontalAlignment = Alignment.CenterHorizontally) {
        Header(s, state)
        Row(Modifier.padding(top = 18.dp), verticalAlignment = Alignment.Bottom) {
            SpeedText(s, speedSize)
            Text("km/h", color = Theme.textSecondary, fontSize = 22.sp, modifier = Modifier.padding(start = 10.dp, bottom = 18.dp))
        }
        Caption("GPS SPEED")
        MetricRow(s, Modifier.padding(top = 22.dp))
        Row(Modifier.fillMaxWidth().padding(top = 18.dp)) {
            GValue("LATERAL", s.lateralG, Theme.accent, Modifier.weight(1f))
            GValue("LONG", s.longitudinalG, Theme.textPrimary, Modifier.weight(1f))
        }
        GMeter(s.lateralG, s.longitudinalG, Modifier.fillMaxWidth().weight(1f).padding(top = 8.dp))
        CalibrationControl(s, saving)
        Row(Modifier.fillMaxWidth().padding(top = 12.dp), horizontalArrangement = Arrangement.spacedBy(12.dp)) {
            ActionButton("⚑", "MARK", !saving, Modifier.weight(1f), actions.onMark)
            ActionButton("★", "HIGHLIGHT", !saving, Modifier.weight(1f), actions.onHighlight)
            ActionButton("⚡", "SYNC", !saving, Modifier.weight(1f), actions.onSync)
        }
        Text(
            stringResource(R.string.hud_caption), color = Theme.textTertiary, fontSize = 11.sp, maxLines = 1,
            textAlign = TextAlign.Center, modifier = Modifier.padding(top = 6.dp),
        )
        StopButton(saving, Modifier.fillMaxWidth().height(68.dp).padding(top = 0.dp), actions.onStop)
        Spacer(Modifier.height(12.dp))
    }
}

@Composable
private fun Landscape(s: Snapshot, state: RecorderState, saving: Boolean, actions: HudActions, width: Dp, height: Dp) {
    val column = (width.value - 40 - 36) / 4
    val speedSize = minOf(200f, (2 * column + 12) / 1.8f, (height.value - 180) / 0.8f).sp
    Column(Modifier.fillMaxSize().padding(horizontal = 20.dp, vertical = 4.dp)) {
        Header(s, state)
        MetricRow(s, Modifier.padding(top = 8.dp))
        Row(Modifier.fillMaxWidth().weight(1f), horizontalArrangement = Arrangement.spacedBy(12.dp)) {
            Column(Modifier.weight(1f).fillMaxHeight(), horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.Center) {
                Row(verticalAlignment = Alignment.Bottom) {
                    SpeedText(s, speedSize)
                    Text("km/h", color = Theme.textSecondary, fontSize = 20.sp, modifier = Modifier.padding(start = 8.dp, bottom = 14.dp))
                }
                Caption("GPS SPEED")
            }
            Row(Modifier.weight(1f).fillMaxHeight(), verticalAlignment = Alignment.CenterVertically) {
                Column(Modifier.width(150.dp)) {
                    GValue("LATERAL", s.lateralG, Theme.accent, Modifier, 30.sp)
                    GValue("LONG", s.longitudinalG, Theme.textPrimary, Modifier.padding(top = 8.dp), 30.sp)
                }
                Column(Modifier.weight(1f).fillMaxHeight(), horizontalAlignment = Alignment.CenterHorizontally) {
                    GMeter(s.lateralG, s.longitudinalG, Modifier.weight(1f).fillMaxWidth().padding(8.dp))
                    CalibrationControl(s, saving)
                }
            }
        }
        Row(Modifier.fillMaxWidth().height(56.dp), horizontalArrangement = Arrangement.spacedBy(12.dp)) {
            ActionButton("⚑", "MARK", !saving, Modifier.weight(1f), actions.onMark)
            ActionButton("★", "HIGHLIGHT", !saving, Modifier.weight(1f), actions.onHighlight)
            ActionButton("⚡", "SYNC", !saving, Modifier.weight(1f), actions.onSync)
            StopButton(saving, Modifier.weight(1f).fillMaxHeight(), actions.onStop)
        }
        Spacer(Modifier.height(8.dp))
    }
}

/** "CAL · 90°" once the mount is calibrated (manual rotation when auto picked the wrong axis, PLAN §7-4); "GPS EST." before. */
@Composable
private fun CalibrationControl(s: Snapshot, saving: Boolean) {
    val context = LocalContext.current
    if (s.isCalibrated) {
        Text(
            "⟳ CAL · 90°", color = Theme.textSecondary, fontSize = 11.sp, fontFamily = FontFamily.Monospace,
            modifier = Modifier.border(1.dp, Theme.divider, RoundedCornerShape(12.dp))
                .pointerInput(saving) { detectTapGestures { if (!saving) RecordingService.rotateMount(context) } }
                .padding(horizontal = 8.dp, vertical = 4.dp),
        )
    } else {
        Caption("GPS EST.")
    }
}

/** Unplugged and below 20 %: a hint for the next session; the preset never changes mid-run (PLAN §2.2.1). */
@Composable
private fun LowBatteryBanner() {
    val context = LocalContext.current
    val battery = remember { context.getSystemService(android.os.BatteryManager::class.java) }
    var low by remember { mutableStateOf(false) }
    LaunchedEffect(Unit) {
        while (true) {
            val level = battery.getIntProperty(android.os.BatteryManager.BATTERY_PROPERTY_CAPACITY)
            low = !battery.isCharging && level in 0 until 20
            delay(60_000)
        }
    }
    if (low) {
        Text(
            stringResource(R.string.hud_low_battery), color = Theme.accent, fontSize = 12.sp, fontWeight = FontWeight.Medium,
            modifier = Modifier.padding(top = 4.dp).background(Theme.surface, RoundedCornerShape(12.dp)).padding(horizontal = 10.dp, vertical = 4.dp),
        )
    }
}

@Composable
private fun Header(s: Snapshot, state: RecorderState) {
    Row(Modifier.fillMaxWidth().padding(top = 8.dp), verticalAlignment = Alignment.CenterVertically) {
        Box(Modifier.size(12.dp).background(Theme.rec, CircleShape))
        Text("REC", color = Theme.rec, fontSize = 18.sp, fontWeight = FontWeight.SemiBold, letterSpacing = 1.sp, modifier = Modifier.padding(start = 8.dp))
        Text(
            HudFormat.clock(s.elapsed), color = Theme.textPrimary, fontSize = 30.sp, fontFamily = FontFamily.Monospace,
            modifier = Modifier.padding(start = 14.dp).weight(1f),
        )
        GpsBadge(s)
    }
    LowBatteryBanner()
    if (state.lastError != null) Text(state.lastError, color = Theme.rec, fontSize = 12.sp)
}

/** ACQUIRING (amber) until the first satellite fix, ±m by accuracy, GPS SEARCHING (red) — iOS `HUDGPSBadge`. */
@Composable
private fun GpsBadge(s: Snapshot) {
    val (text, color) = when (s.gpsStatus) {
        Snapshot.GpsStatus.ACQUIRING -> "ACQUIRING" to Theme.accent
        Snapshot.GpsStatus.SEARCHING -> "GPS SEARCHING" to Theme.rec
        Snapshot.GpsStatus.GOOD -> {
            val a = s.horizontalAccuracy
            when {
                a == null || a <= 0 -> "ACQUIRING" to Theme.accent
                a <= 10 -> "±%.0f m".format(Locale.US, a) to Theme.good
                a <= 30 -> "±%.0f m".format(Locale.US, a) to Theme.accent
                else -> "±%.0f m".format(Locale.US, a) to Theme.rec
            }
        }
    }
    Text(
        "◎ $text", color = color, fontSize = 13.sp, fontFamily = FontFamily.Monospace,
        modifier = Modifier.background(Theme.surface, RoundedCornerShape(8.dp)).padding(horizontal = 9.dp, vertical = 5.dp),
    )
}

@Composable
private fun SpeedText(s: Snapshot, size: TextUnit) {
    Text(
        s.speed?.let { "%.0f".format(Locale.US, maxOf(0.0, it) * 3.6) } ?: "--",
        color = Theme.textPrimary, fontSize = size, fontFamily = FontFamily.Monospace, fontWeight = FontWeight.Medium,
        letterSpacing = (-0.04).em(size),
    )
}

private fun Double.em(size: TextUnit) = (this * size.value).sp

@Composable
private fun Caption(text: String) {
    Text(text, color = Theme.textSecondary, fontSize = 12.sp, letterSpacing = 1.5.sp)
}

@Composable
private fun MetricRow(s: Snapshot, modifier: Modifier) {
    Row(
        modifier.fillMaxWidth().border(width = 1.dp, color = Theme.divider, shape = RoundedCornerShape(0.dp)).padding(vertical = 10.dp),
        horizontalArrangement = Arrangement.SpaceBetween,
    ) {
        Metric("ALT", s.altitude?.let { "%.0f".format(Locale.US, it) } ?: "--", "m")
        Metric("COURSE", s.course?.let { "%.0f".format(Locale.US, it) } ?: "--", "° ${s.course?.let(HudFormat::cardinal).orEmpty()}")
        Metric("DIST", "%.1f".format(Locale.US, s.distance / 1000), "km")
    }
}

@Composable
private fun RowScope.Metric(label: String, value: String, unit: String) {
    Row(verticalAlignment = Alignment.Bottom, modifier = Modifier.padding(horizontal = 4.dp)) {
        Text(label, color = Theme.textSecondary, fontSize = 11.sp, letterSpacing = 1.sp, modifier = Modifier.padding(end = 6.dp, bottom = 4.dp))
        Text(value, color = Theme.textPrimary, fontSize = 26.sp, fontFamily = FontFamily.Monospace)
        Text(unit, color = Theme.textSecondary, fontSize = 13.sp, modifier = Modifier.padding(start = 3.dp, bottom = 3.dp))
    }
}

@Composable
private fun GValue(label: String, g: Double, color: Color, modifier: Modifier, size: TextUnit = 40.sp) {
    Column(modifier, horizontalAlignment = Alignment.CenterHorizontally) {
        Text(label, color = Theme.textSecondary, fontSize = 12.sp, letterSpacing = 1.5.sp)
        Row(verticalAlignment = Alignment.Bottom) {
            Text("%+.2f".format(Locale.US, g), color = color, fontSize = size, fontFamily = FontFamily.Monospace, maxLines = 1, softWrap = false)
            Text("G", color = Theme.textSecondary, fontSize = 16.sp, modifier = Modifier.padding(start = 4.dp, bottom = 6.dp))
        }
    }
}

/** MARK / HIGHLIGHT / SYNC: icon over the title, an amber check for a moment after the press (iOS `HUDActionButton`). */
@Composable
private fun ActionButton(icon: String, title: String, enabled: Boolean, modifier: Modifier, onClick: () -> Unit) {
    var confirmed by remember { mutableStateOf(false) }
    LaunchedEffect(confirmed) {
        if (confirmed) {
            delay(900)
            confirmed = false
        }
    }
    val view = LocalView.current
    Column(
        modifier
            .height(64.dp)
            .border(1.dp, if (confirmed) Theme.accent else Theme.divider, RoundedCornerShape(14.dp))
            .background(Theme.background, RoundedCornerShape(14.dp))
            .pointerInput(enabled) {
                detectTapGestures {
                    if (!enabled) return@detectTapGestures
                    view.performHapticFeedback(HapticFeedbackConstants.CONFIRM)
                    confirmed = true
                    onClick()
                }
            },
        horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.Center,
    ) {
        Text(if (confirmed) "✓" else icon, color = if (confirmed) Theme.accent else Theme.textPrimary, fontSize = 20.sp)
        Text(title, color = if (enabled) Theme.textPrimary else Theme.textTertiary, fontSize = 15.sp, fontWeight = FontWeight.SemiBold, letterSpacing = 1.sp, maxLines = 1)
    }
}

/** STOP needs a long press (iOS: full width, hold), so a bump can't end the recording. */
@Composable
private fun StopButton(saving: Boolean, modifier: Modifier, onStop: () -> Unit) {
    val view = LocalView.current
    Box(
        modifier
            .padding(top = 8.dp)
            .background(Theme.rec, RoundedCornerShape(16.dp))
            .pointerInput(saving) {
                detectTapGestures(onLongPress = {
                    if (!saving) {
                        view.performHapticFeedback(HapticFeedbackConstants.LONG_PRESS)
                        onStop()
                    }
                })
            },
        contentAlignment = Alignment.Center,
    ) {
        Column(horizontalAlignment = Alignment.CenterHorizontally) {
            Text(if (saving) "SAVING…" else "■  STOP", color = Theme.textPrimary, fontSize = 18.sp, fontWeight = FontWeight.SemiBold, letterSpacing = 2.sp)
            if (!saving) Text(stringResource(R.string.hud_hold_to_stop), color = Theme.textPrimary.copy(alpha = 0.7f), fontSize = 11.sp)
        }
    }
}

object HudFormat {
    fun clock(seconds: Double): String {
        val s = maxOf(0, seconds.toInt())
        return "%02d:%02d:%02d".format(Locale.US, s / 3600, s % 3600 / 60, s % 60)
    }

    fun cardinal(course: Double): String = listOf("N", "NE", "E", "SE", "S", "SW", "W", "NW")[(((course % 360) + 360 + 22.5) / 45).toInt() % 8]
}
