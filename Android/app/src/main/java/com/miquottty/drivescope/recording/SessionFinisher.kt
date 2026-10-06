package com.miquottty.drivescope.recording

import android.content.Context
import android.location.Address
import android.location.Geocoder
import com.miquottty.drivescope.R
import com.miquottty.drivescope.bridge.DriveKitBridge
import com.miquottty.drivescope.store.SessionMeta
import com.miquottty.drivescope.store.SessionStore
import kotlinx.coroutines.suspendCancellableCoroutine
import org.json.JSONArray
import org.json.JSONObject
import java.util.Locale
import kotlin.coroutines.resume

/**
 * After STOP, iOS's `RecordingController.stop` + `SessionFinalizer`: summary and route from DriveKit, the mount and
 * sections (`analyze`), then places — DriveKit picks the points, Android's Geocoder names them — and the automatic title.
 */
class SessionFinisher(private val context: Context, private val store: SessionStore) {
    suspend fun finish(id: String, preset: CapturePreset, stop: JSONObject) {
        if (id.isEmpty()) return
        val dir = store.directory(id)
        val preview = stop.optJSONArray("routePreview") ?: JSONArray()
        var meta = SessionMeta(
            id = id,
            state = SessionMeta.State.STOPPED,
            preset = preset.raw,
            startedAt = startedAt(dir),
            endedAt = stop.optDouble("endedAt").takeUnless { it.isNaN() },
            summary = stop.optJSONObject("summary") ?: JSONObject(),
            routePreview = (0 until preview.length()).map { preview.getJSONObject(it).let { p -> p.getDouble("latitude") to p.getDouble("longitude") } },
            geocodePending = true,
        )
        store.save(meta)

        val analysis = JSONObject(DriveKitBridge.analyze(dir.absolutePath))
        val peakElapsed = analysis.optDouble("peakLateralElapsed").takeUnless { analysis.isNull("peakLateralElapsed") || it.isNaN() }
        if (!analysis.isNull("peakLateralG") && analysis.has("peakLateralG")) meta.summary.put("peakLateralG", analysis.getDouble("peakLateralG"))
        meta = meta.copy(
            sections = analysis.optJSONArray("sections") ?: JSONArray(),
            sectionsVersion = analysis.optInt("sectionsVersion"),
            peakLateralElapsed = peakElapsed,
        )
        store.save(meta)

        val places = geocode(dir.absolutePath, peakElapsed)
        val title = DriveKitBridge.sessionTitle(
            places.firstOrNull { it.optString("role") == "start" }?.toString().orEmpty(),
            places.firstOrNull { it.optString("role") == "end" }?.toString().orEmpty(),
            context.getString(R.string.title_loop),
        )
        store.save(meta.copy(
            places = places,
            title = if (meta.titleIsUserEdited) meta.title else title,
            autoTitle = title,
            geocodePending = places.any { !it.has("locality") && !it.has("administrativeArea") },
        ))
    }

    /** DriveKit's candidates (start, end, peak G, via) named by Android's Geocoder as `PlaceMeta` JSON. */
    private suspend fun geocode(sessionDir: String, peakLateralElapsed: Double?): List<JSONObject> {
        val candidates = JSONArray(DriveKitBridge.placeCandidates(sessionDir, peakLateralElapsed ?: Double.NaN))
        val geocoder = Geocoder(context, context.resources.configuration.locales[0] ?: Locale.getDefault())
        return (0 until candidates.length()).map { i ->
            val c = candidates.getJSONObject(i)
            val lat = c.getDouble("latitude")
            val lon = c.getDouble("longitude")
            val place = JSONObject().put("latitude", lat).put("longitude", lon).put("role", c.getString("role"))
            lookup(geocoder, lat, lon)?.let { a -> fill(place, a) }
            place
        }
    }

    /** iOS `PlaceMeta` fields from an Android `Address` (Japan: locality = 市 / 区, adminArea = 都道府県). */
    private fun fill(place: JSONObject, a: Address) {
        a.featureName?.takeIf { it != a.subThoroughfare && it.any(Char::isLetter) }?.let { place.put("name", it) }
        (a.locality ?: a.subAdminArea)?.let { place.put("locality", it) }
        a.subLocality?.let { place.put("subLocality", it) }
        a.adminArea?.let { place.put("administrativeArea", it) }
        a.getAddressLine(0)?.let { place.put("fullAddress", it) }
    }

    private suspend fun lookup(geocoder: Geocoder, lat: Double, lon: Double): Address? = suspendCancellableCoroutine { cont ->
        geocoder.getFromLocation(lat, lon, 1, object : Geocoder.GeocodeListener {
            override fun onGeocode(addresses: MutableList<Address>) = cont.resume(addresses.firstOrNull())
            override fun onError(errorMessage: String?) = cont.resume(null)
        })
    }

    private fun startedAt(dir: java.io.File): Double = runCatching {
        com.miquottty.drivescope.store.ManifestDate.parse(
            JSONObject(java.io.File(dir, "manifest.json").readText()).getJSONObject("clock").getString("startedAt"),
        )
    }.getOrDefault(0.0)
}
