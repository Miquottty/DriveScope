package com.miquottty.drivescope.sessions

import android.content.Context
import android.content.Intent
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.core.content.FileProvider
import com.miquottty.drivescope.R
import com.miquottty.drivescope.Theme
import com.miquottty.drivescope.bridge.DriveKitBridge
import com.miquottty.drivescope.map.clock
import com.miquottty.drivescope.store.SessionMeta
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import org.json.JSONArray
import java.io.File

/**
 * Export (iOS `ExportView`): DriveKit's JSON / GPX / CSV with the session's title, notes and places, handed to Android's
 * share sheet — the same files the Vlog pipeline reads from the iPhone.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun ExportSheet(meta: SessionMeta, dir: File, onDismiss: () -> Unit) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    var busy by remember { mutableStateOf<String?>(null) }
    var failure by remember { mutableStateOf<String?>(null) }
    var sync by remember { mutableStateOf<Double?>(null) }
    LaunchedEffect(dir) {
        sync = withContext(Dispatchers.Default) {
            val m = DriveKitBridge.markers(dir.absolutePath)
            (m.indices step 2).filter { m[it + 1].toInt() == 1 }.minOfOrNull { m[it] }
        }
    }
    ModalBottomSheet(onDismissRequest = onDismiss, containerColor = Theme.background) {
        Column(Modifier.padding(horizontal = 20.dp).padding(bottom = 32.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
            Text(stringResource(R.string.export), color = Theme.textPrimary, fontSize = 22.sp, fontWeight = FontWeight.Bold)
            Text(
                sync?.let { stringResource(R.string.export_sync_at, clock(it)) } ?: stringResource(R.string.export_no_sync),
                color = if (sync != null) Theme.good else Theme.textSecondary, fontSize = 13.sp,
            )
            for ((kind, title, detail) in listOf(
                Triple("json", "JSON", R.string.export_json_detail),
                Triple("gpx", "GPX", R.string.export_gpx_detail),
                Triple("csv30", "CSV · 30 fps", R.string.export_csv30_detail),
                Triple("csv10", "CSV · 10 Hz", R.string.export_csv10_detail),
            )) {
                Row(
                    Modifier.fillMaxWidth().background(Theme.surface, RoundedCornerShape(14.dp))
                        .clickable(enabled = busy == null) {
                            busy = kind
                            scope.launch {
                                val path = withContext(Dispatchers.IO) { export(context, meta, dir, kind) }
                                busy = null
                                if (path.startsWith("error")) failure = path else share(context, File(path))
                            }
                        }
                        .padding(16.dp),
                ) {
                    Column(Modifier.weight(1f)) {
                        Text(title, color = Theme.textPrimary, fontSize = 16.sp, fontWeight = FontWeight.SemiBold)
                        Text(stringResource(detail), color = Theme.textSecondary, fontSize = 13.sp)
                    }
                    Text(if (busy == kind) "…" else "⇪", color = Theme.accent, fontSize = 20.sp)
                }
            }
            failure?.let { Text(stringResource(R.string.export_failed) + "\n" + it, color = Theme.rec, fontSize = 13.sp) }
        }
    }
}

private fun export(context: Context, meta: SessionMeta, dir: File, kind: String): String {
    DriveKitBridge.configure(context.cacheDir.absolutePath)
    val out = File(context.cacheDir, "exports").apply { deleteRecursively(); mkdirs() }
    return DriveKitBridge.exportFile(
        kind, dir.absolutePath, meta.title, meta.notes, JSONArray(meta.places).toString(),
        File(context.cacheDir, "export-work").absolutePath, out.absolutePath,
    )
}

private fun share(context: Context, file: File) {
    val uri = FileProvider.getUriForFile(context, "${context.packageName}.files", file)
    val type = when (file.extension) {
        "json" -> "application/json"
        "gpx" -> "application/gpx+xml"
        else -> "text/csv"
    }
    val send = Intent(Intent.ACTION_SEND).setType(type).putExtra(Intent.EXTRA_STREAM, uri).addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
    context.startActivity(Intent.createChooser(send, file.name))
}
