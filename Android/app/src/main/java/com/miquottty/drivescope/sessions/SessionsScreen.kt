package com.miquottty.drivescope.sessions

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.pluralStringResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.miquottty.drivescope.R
import com.miquottty.drivescope.Theme
import com.miquottty.drivescope.home.SessionRow
import com.miquottty.drivescope.store.SessionMeta
import com.miquottty.drivescope.store.SessionStore
import org.json.JSONObject
import java.time.Instant
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import java.util.Locale

/** Sessions (mock artboard 3): grouped by month, the newest month first (#36). */
@Composable
fun SessionsScreen(store: SessionStore, onOpen: (SessionMeta) -> Unit) {
    val sessions by store.sessions.collectAsState()
    if (sessions.isEmpty()) {
        Column(Modifier.fillMaxSize().padding(40.dp), horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.Center) {
            Text(stringResource(R.string.sessions_empty_title), color = Theme.textPrimary, fontSize = 17.sp, fontWeight = FontWeight.SemiBold)
            Text(stringResource(R.string.sessions_empty_body), color = Theme.textSecondary, fontSize = 14.sp, textAlign = TextAlign.Center, modifier = Modifier.padding(top = 6.dp))
        }
        return
    }
    var deletingAll by remember { mutableStateOf(false) }
    val months = sessions.groupBy { month(it.startedAt) }
    LazyColumn(Modifier.fillMaxSize().background(Theme.background).padding(horizontal = 20.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
        item {
            Row(Modifier.fillMaxWidth().padding(top = 16.dp), verticalAlignment = Alignment.CenterVertically) {
                Text(stringResource(R.string.tab_sessions), color = Theme.textPrimary, fontSize = 28.sp, fontWeight = FontWeight.Bold, modifier = Modifier.weight(1f))
                Text(
                    stringResource(R.string.delete_all), color = Theme.textSecondary, fontSize = 13.sp,
                    modifier = Modifier.background(Theme.surface, RoundedCornerShape(10.dp)).clickable { deletingAll = true }.padding(horizontal = 12.dp, vertical = 8.dp),
                )
            }
        }
        for ((title, inMonth) in months) {
            item { Text(title, color = Theme.textSecondary, fontSize = 13.sp, fontWeight = FontWeight.Medium, modifier = Modifier.padding(top = 12.dp)) }
            items(inMonth, key = { it.id }) { session -> SessionRow(session) { onOpen(session) } }
        }
        item { Text("", modifier = Modifier.padding(bottom = 24.dp)) }
    }
    // The HUD replaces this screen during a run, so nothing listed here is being recorded.
    if (deletingAll) AlertDialog(
        onDismissRequest = { deletingAll = false },
        title = { Text(pluralStringResource(R.plurals.delete_all_title, sessions.size, sessions.size)) },
        text = { Text(stringResource(R.string.delete_all_body)) },
        confirmButton = {
            TextButton(onClick = { deletingAll = false; sessions.forEach { store.delete(it.id) } }) {
                Text(stringResource(R.string.delete_all), color = Theme.rec)
            }
        },
        dismissButton = { TextButton(onClick = { deletingAll = false }) { Text(stringResource(R.string.cancel)) } },
        containerColor = Theme.surface,
    )
}

private fun month(unix: Double): String =
    DateTimeFormatter.ofPattern(if (Locale.getDefault().language == "ja") "yyyy年M月" else "MMMM yyyy", Locale.getDefault())
        .format(Instant.ofEpochMilli((unix * 1000).toLong()).atZone(ZoneId.systemDefault()))

/** "Left corner", "Stop", "Climb"… (iOS `SessionSectionsCard`). */
@Composable
fun sectionName(section: JSONObject): String = when (section.optString("kind")) {
    "corner" -> stringResource(if (section.optString("direction") == "right") R.string.section_right_corner else R.string.section_left_corner)
    "stop" -> stringResource(R.string.section_stop)
    "climb" -> stringResource(R.string.section_climb)
    "descent" -> stringResource(R.string.section_descent)
    else -> section.optString("kind")
}
