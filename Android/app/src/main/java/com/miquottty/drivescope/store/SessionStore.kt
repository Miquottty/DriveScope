package com.miquottty.drivescope.store

import android.content.Context
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import org.json.JSONArray
import org.json.JSONObject
import java.io.File

/**
 * What iOS keeps in SwiftData (`DriveSession`), as `session.json` next to DriveKit's `manifest.json` and streams.
 * No database: the folders are scanned at launch (personal use, hundreds of sessions at most).
 */
data class SessionMeta(
    val id: String,
    val state: State = State.RECORDING,
    val title: String = "",
    val titleIsUserEdited: Boolean = false,
    val notes: String = "",
    val preset: String = "logger",
    /** Unix seconds. */
    val startedAt: Double = 0.0,
    val endedAt: Double? = null,
    /** DriveKit `SessionSummary` JSON, as returned by `recorderStop`. */
    val summary: JSONObject = JSONObject(),
    /** [latitude, longitude] pairs (≤ 200). */
    val routePreview: List<Pair<Double, Double>> = emptyList(),
    /** `PlaceMeta` JSON objects by role ("start", "end", "via", "peakG", "maxAltitude"). */
    val places: List<JSONObject> = emptyList(),
    val sections: JSONArray = JSONArray(),
    val sectionsVersion: Int = 0,
    val peakLateralElapsed: Double? = null,
    val geocodePending: Boolean = false,
) {
    enum class State(val raw: String) { RECORDING("recording"), STOPPED("stopped"), RECOVERED("recovered") }

    fun place(role: String) = places.firstOrNull { it.optString("role") == role }

    fun toJson(): JSONObject = JSONObject().apply {
        put("id", id)
        put("state", state.raw)
        put("title", title)
        put("titleIsUserEdited", titleIsUserEdited)
        put("notes", notes)
        put("preset", preset)
        put("startedAt", startedAt)
        put("endedAt", endedAt ?: JSONObject.NULL)
        put("summary", summary)
        put("routePreview", JSONArray(routePreview.map { JSONArray(listOf(it.first, it.second)) }))
        put("places", JSONArray(places))
        put("sections", sections)
        put("sectionsVersion", sectionsVersion)
        put("peakLateralElapsed", peakLateralElapsed ?: JSONObject.NULL)
        put("geocodePending", geocodePending)
    }

    companion object {
        fun fromJson(o: JSONObject): SessionMeta {
            fun optDouble(key: String) = if (o.isNull(key)) null else o.optDouble(key).takeUnless { it.isNaN() }
            val preview = o.optJSONArray("routePreview") ?: JSONArray()
            val places = o.optJSONArray("places") ?: JSONArray()
            return SessionMeta(
                id = o.getString("id"),
                state = State.entries.firstOrNull { it.raw == o.optString("state") } ?: State.STOPPED,
                title = o.optString("title"),
                titleIsUserEdited = o.optBoolean("titleIsUserEdited"),
                notes = o.optString("notes"),
                preset = o.optString("preset", "logger"),
                startedAt = o.optDouble("startedAt", 0.0),
                endedAt = optDouble("endedAt"),
                summary = o.optJSONObject("summary") ?: JSONObject(),
                routePreview = (0 until preview.length()).map { preview.getJSONArray(it).let { p -> p.getDouble(0) to p.getDouble(1) } },
                places = (0 until places.length()).map { places.getJSONObject(it) },
                sections = o.optJSONArray("sections") ?: JSONArray(),
                sectionsVersion = o.optInt("sectionsVersion"),
                peakLateralElapsed = optDouble("peakLateralElapsed"),
                geocodePending = o.optBoolean("geocodePending"),
            )
        }
    }
}

/** The session folders under `files/Sessions` and their `session.json`; observed by the screens. */
class SessionStore(val root: File) {
    private val all = MutableStateFlow<List<SessionMeta>>(emptyList())
    /** Newest first. */
    val sessions: StateFlow<List<SessionMeta>> = all.asStateFlow()

    fun directory(id: String) = File(root, id)

    fun reload() {
        all.value = root.listFiles()
            ?.filter { File(it, "manifest.json").exists() }
            ?.mapNotNull { dir -> runCatching { read(dir) }.getOrNull() }
            ?.sortedByDescending { it.startedAt }
            .orEmpty()
    }

    fun save(meta: SessionMeta) {
        val dir = directory(meta.id)
        val tmp = File(dir, "session.json.tmp")
        tmp.writeText(meta.toJson().toString(2))
        tmp.renameTo(File(dir, "session.json"))
        all.value = (all.value.filterNot { it.id == meta.id } + meta).sortedByDescending { it.startedAt }
    }

    fun delete(id: String) {
        directory(id).deleteRecursively()
        all.value = all.value.filterNot { it.id == id }
    }

    /** `session.json` when the app wrote one; otherwise what the manifest says (a run the app never finished). */
    private fun read(dir: File): SessionMeta {
        File(dir, "session.json").takeIf { it.exists() }?.let { return SessionMeta.fromJson(JSONObject(it.readText())) }
        val manifest = JSONObject(File(dir, "manifest.json").readText())
        return SessionMeta(
            id = manifest.getString("sessionID"),
            state = SessionMeta.State.RECORDING,
            preset = manifest.optString("preset", "logger"),
            startedAt = ManifestDate.parse(manifest.getJSONObject("clock").getString("startedAt")),
        )
    }

    companion object {
        fun forContext(context: Context) = SessionStore(File(context.getExternalFilesDir(null), "Sessions"))
    }
}

/** DriveKit `ManifestDate`: ISO 8601 UTC with microseconds → unix seconds. */
object ManifestDate {
    fun parse(text: String): Double {
        val dot = text.indexOf('.')
        if (dot < 0) return java.time.Instant.parse(text).epochSecond.toDouble()
        val whole = java.time.Instant.parse(text.substring(0, dot) + "Z").epochSecond
        val fraction = text.substring(dot + 1).trimEnd('Z')
        return whole + ("0.$fraction").toDouble()
    }
}
