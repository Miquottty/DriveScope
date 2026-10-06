package com.miquottty.drivescope.settings

import android.app.LocaleManager
import android.os.LocaleList
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Switch
import androidx.compose.material3.SwitchDefaults
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.miquottty.drivescope.R
import com.miquottty.drivescope.Theme

/** Settings: language, satellite chime, developer screens (iOS `SettingsView`). */
@Composable
fun SettingsScreen(onBack: () -> Unit, onOpenProbe: () -> Unit) {
    val context = LocalContext.current
    val prefs = remember { Prefs(context) }
    val locales = remember { context.getSystemService(LocaleManager::class.java) }
    var language by remember { mutableStateOf(locales.applicationLocales.toLanguageTags()) }
    var chime by remember { mutableStateOf(prefs.satelliteChime) }
    var fastWatchdog by remember { mutableStateOf(prefs.fastWatchdog) }

    Column(Modifier.fillMaxSize().background(Theme.background).verticalScroll(rememberScrollState()).padding(20.dp), verticalArrangement = Arrangement.spacedBy(16.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text("‹", color = Theme.accent, fontSize = 28.sp, modifier = Modifier.clickable(onClick = onBack).padding(end = 12.dp))
            Text(stringResource(R.string.settings_title), color = Theme.textPrimary, fontSize = 22.sp, fontWeight = FontWeight.SemiBold)
        }
        Section(stringResource(R.string.settings_language)) {
            // Per-app language (Android 13+), as the iOS app's own switch.
            for ((tag, label) in listOf("" to stringResource(R.string.settings_language_system), "ja" to "日本語", "en" to "English")) {
                Row(
                    Modifier.fillMaxWidth().clickable {
                        language = tag
                        locales.applicationLocales = if (tag.isEmpty()) LocaleList.getEmptyLocaleList() else LocaleList.forLanguageTags(tag)
                    }.padding(vertical = 8.dp),
                ) {
                    Text(label, color = Theme.textPrimary, fontSize = 15.sp, modifier = Modifier.weight(1f))
                    if (language == tag) Text("✓", color = Theme.accent, fontSize = 15.sp)
                }
            }
        }
        Section(stringResource(R.string.settings_recording)) {
            Toggle(stringResource(R.string.settings_satellite_chime), chime) { chime = it; prefs.satelliteChime = it }
            Text(stringResource(R.string.settings_satellite_chime_footer), color = Theme.textSecondary, fontSize = 12.sp)
        }
        Section(stringResource(R.string.settings_debug)) {
            Toggle(stringResource(R.string.settings_fast_watchdog), fastWatchdog) { fastWatchdog = it; prefs.fastWatchdog = it }
            Text(
                stringResource(R.string.settings_sensor_probe), color = Theme.accent, fontSize = 15.sp,
                modifier = Modifier.fillMaxWidth().clickable(onClick = onOpenProbe).padding(vertical = 8.dp),
            )
        }
    }
}

@Composable
private fun Section(title: String, content: @Composable () -> Unit) {
    Column(Modifier.fillMaxWidth().background(Theme.surface, RoundedCornerShape(16.dp)).padding(16.dp), verticalArrangement = Arrangement.spacedBy(4.dp)) {
        Text(title.uppercase(), color = Theme.textSecondary, fontSize = 12.sp, letterSpacing = 1.sp)
        content()
    }
}

@Composable
private fun Toggle(label: String, checked: Boolean, onChange: (Boolean) -> Unit) {
    Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
        Text(label, color = Theme.textPrimary, fontSize = 15.sp, modifier = Modifier.weight(1f))
        Switch(checked, onChange, colors = SwitchDefaults.colors(checkedTrackColor = Theme.accent))
    }
}
