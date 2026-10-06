package com.miquottty.drivescope.map

import android.content.Context
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Paint
import android.graphics.Path
import android.location.Address
import android.location.Geocoder
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeDrawingPadding
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.Slider
import androidx.compose.material3.SliderDefaults
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableDoubleStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.runtime.withFrameNanos
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.toArgb
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalLifecycleOwner
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.viewinterop.AndroidView
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import com.miquottty.drivescope.Theme
import com.miquottty.drivescope.bridge.DriveKitBridge
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import org.json.JSONObject
import org.maplibre.android.MapLibre
import org.maplibre.android.camera.CameraPosition
import org.maplibre.android.camera.CameraUpdateFactory
import org.maplibre.android.geometry.LatLng
import org.maplibre.android.geometry.LatLngBounds
import org.maplibre.android.maps.MapLibreMap
import org.maplibre.android.maps.MapView
import org.maplibre.android.maps.Style
import org.maplibre.android.style.expressions.Expression
import org.maplibre.android.style.layers.CircleLayer
import org.maplibre.android.style.layers.LineLayer
import org.maplibre.android.style.layers.Property
import org.maplibre.android.style.layers.PropertyFactory
import org.maplibre.android.style.layers.SymbolLayer
import org.maplibre.android.style.sources.GeoJsonSource
import org.maplibre.geojson.Feature
import org.maplibre.geojson.FeatureCollection
import org.maplibre.geojson.LineString
import org.maplibre.geojson.Point
import java.io.File
import java.util.Locale
import kotlin.math.abs

/** S0 spike screen 3: the iOS Replay (route, played part, car arrow, FOLLOW / 3D) on MapLibre, frames from DriveKit. */
enum class MapStyle(val label: String, val url: String) {
    DARK("OFM dark", "https://tiles.openfreemap.org/styles/dark"),
    GSI("地理院", "https://gsi-cyberjapan.github.io/optimal_bvmap/style/std.json"),
    GOOGLE("Google", ""),
}

class Replay(val frames: DoubleArray, val markers: DoubleArray) {
    val count get() = frames.size / DriveKitBridge.FRAME_STRIDE
    val duration get() = if (count > 0) frames[(count - 1) * DriveKitBridge.FRAME_STRIDE] else 0.0
    fun at(i: Int, field: Int) = frames[i.coerceIn(0, count - 1) * DriveKitBridge.FRAME_STRIDE + field]
    fun point(i: Int): Point = Point.fromLngLat(at(i, 2), at(i, 1))

    /** Frame at time `t` (s), linear between the 10 Hz frames, course on the circle. */
    fun sample(t: Double): DoubleArray {
        val x = (t * HZ).coerceIn(0.0, (count - 1).toDouble())
        val i = x.toInt()
        val f = x - i
        val out = DoubleArray(DriveKitBridge.FRAME_STRIDE) { k -> at(i, k) + (at(i + 1, k) - at(i, k)) * f }
        var d = at(i + 1, 4) - at(i, 4)
        if (d > 180) d -= 360 else if (d < -180) d += 360
        out[4] = (at(i, 4) + d * f + 360) % 360
        return out
    }

    companion object {
        const val HZ = 10.0
    }
}

@Composable
fun MapScreen(sessionDir: File, onBack: () -> Unit) {
    val context = LocalContext.current
    var replay by remember { mutableStateOf<Replay?>(null) }
    var loadMs by remember { mutableStateOf(0L) }
    var style by remember { mutableStateOf(MapStyle.DARK) }
    var map by remember { mutableStateOf<MapLibreMap?>(null) }
    var loadedStyle by remember { mutableStateOf<Style?>(null) }
    var t by remember { mutableDoubleStateOf(0.0) }
    var playing by remember { mutableStateOf(false) }
    var rate by remember { mutableDoubleStateOf(8.0) }
    var follow by remember { mutableStateOf(true) }
    var threeD by remember { mutableStateOf(false) }
    var places by remember { mutableStateOf("Geocoding…") }

    LaunchedEffect(sessionDir) {
        val started = System.nanoTime()
        replay = withContext(Dispatchers.Default) {
            DriveKitBridge.configure(context.cacheDir.absolutePath)
            Replay(DriveKitBridge.replayFrames(sessionDir.absolutePath, Replay.HZ), DriveKitBridge.markers(sessionDir.absolutePath))
        }
        loadMs = (System.nanoTime() - started) / 1_000_000
        replay?.let { places = withContext(Dispatchers.IO) { comparePlaces(context, sessionDir, it) } }
    }

    // New style → route layers, then the camera fits the whole drive.
    LaunchedEffect(map, style, replay) {
        if (style == MapStyle.GOOGLE) return@LaunchedEffect
        val m = map ?: return@LaunchedEffect
        val r = replay ?: return@LaunchedEffect
        loadedStyle = null
        val builder = if (style == MapStyle.GSI) {
            Style.Builder().fromJson(withContext(Dispatchers.IO) { gsiStyleJson(style.url) })
        } else {
            Style.Builder().fromUri(style.url)
        }
        m.setStyle(builder) { s ->
            addRouteLayers(s, r)
            loadedStyle = s
            val bounds = LatLngBounds.Builder().includes((0 until r.count step 10).map { LatLng(r.at(it, 1), r.at(it, 2)) }).build()
            m.moveCamera(CameraUpdateFactory.newLatLngBounds(bounds, 80))
        }
    }

    // Playback clock.
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

    // Each frame: car arrow, played line (5 Hz), follow camera.
    var lastPlayedUpdate by remember { mutableDoubleStateOf(-1.0) }
    LaunchedEffect(t, loadedStyle, follow, threeD) {
        val s = loadedStyle ?: return@LaunchedEffect
        val r = replay ?: return@LaunchedEffect
        val f = r.sample(t)
        s.getSourceAs<GeoJsonSource>("car")?.setGeoJson(
            Feature.fromGeometry(Point.fromLngLat(f[2], f[1])).apply { addNumberProperty("course", f[4]) },
        )
        if (abs(t - lastPlayedUpdate) > 0.2 * rate || t == 0.0) {
            lastPlayedUpdate = t
            val end = (t * Replay.HZ).toInt().coerceIn(1, r.count - 1)
            s.getSourceAs<GeoJsonSource>("played")?.setGeoJson(LineString.fromLngLats((0..end step 5).map { r.point(it) } + r.point(end)))
        }
        if (follow) {
            map?.moveCamera(
                CameraUpdateFactory.newCameraPosition(
                    CameraPosition.Builder().target(LatLng(f[1], f[2]))
                        .zoom(if (threeD) 16.5 else 15.5)
                        .bearing(if (threeD) f[4] else 0.0)
                        .tilt(if (threeD) 60.0 else 0.0)
                        .build(),
                ),
            )
        }
    }

    Column(Modifier.fillMaxSize().background(Theme.background).safeDrawingPadding()) {
        Row(Modifier.fillMaxWidth().padding(12.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            Chip("‹", false) { onBack() }
            for (option in MapStyle.entries) Chip(option.label, style == option) {
                // The MapLibre view is disposed while Google shows; a new one reports its map when it comes back.
                if (option == MapStyle.GOOGLE) {
                    map = null
                    loadedStyle = null
                }
                style = option
            }
        }
        Box(Modifier.weight(1f).fillMaxWidth()) {
            val r = replay
            if (style == MapStyle.GOOGLE && r != null) {
                GoogleMapPane(r, t, follow, threeD)
            } else if (style != MapStyle.GOOGLE) {
                MapLibreView { map = it }
            }
            Row(Modifier.align(Alignment.TopEnd).padding(12.dp), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                Chip("FOLLOW", follow) { follow = !follow }
                Chip("3D", threeD) { threeD = !threeD }
            }
        }
        val r = replay
        Column(Modifier.fillMaxWidth().padding(12.dp), verticalArrangement = Arrangement.spacedBy(4.dp)) {
            if (r == null) {
                Text("Loading frames from DriveKit…", color = Theme.textSecondary)
            } else {
                val f = r.sample(t)
                Text(
                    "%s / %s · %.0f km/h · %.0f° · latG %+.2f".format(clock(t), clock(r.duration), f[3] * 3.6, f[4], f[6]),
                    color = Theme.textPrimary, fontFamily = FontFamily.Monospace, fontSize = 14.sp,
                )
                Slider(
                    value = t.toFloat(), valueRange = 0f..r.duration.toFloat(), onValueChange = { t = it.toDouble() },
                    colors = SliderDefaults.colors(thumbColor = Theme.accent, activeTrackColor = Theme.accent),
                )
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    Chip(if (playing) "PAUSE" else "PLAY", playing) { playing = !playing }
                    for (x in listOf(1.0, 8.0, 32.0)) Chip("${x.toInt()}×", rate == x) { rate = x }
                }
                Text("${r.count} frames (10 Hz) from DriveKit in $loadMs ms", color = Theme.textTertiary, fontSize = 11.sp)
                Text(places, color = Theme.textSecondary, fontSize = 12.sp, fontFamily = FontFamily.Monospace)
            }
        }
    }
}

@Composable
private fun Chip(label: String, selected: Boolean, onClick: () -> Unit) {
    Button(
        onClick = onClick,
        shape = RoundedCornerShape(10.dp),
        colors = ButtonDefaults.buttonColors(
            containerColor = if (selected) Theme.accent else Theme.surface,
            contentColor = if (selected) Theme.background else Theme.textPrimary,
        ),
    ) { Text(label, fontSize = 13.sp) }
}

@Composable
private fun MapLibreView(onMap: (MapLibreMap) -> Unit) {
    val context = LocalContext.current
    val lifecycle = LocalLifecycleOwner.current.lifecycle
    val mapView = remember {
        MapLibre.getInstance(context)
        MapView(context).apply {
            onCreate(null)
            getMapAsync { map ->
                map.uiSettings.isAttributionEnabled = true
                map.uiSettings.isLogoEnabled = false
                onMap(map)
            }
        }
    }
    DisposableEffect(lifecycle) {
        val observer = LifecycleEventObserver { _, event ->
            when (event) {
                Lifecycle.Event.ON_START -> mapView.onStart()
                Lifecycle.Event.ON_RESUME -> mapView.onResume()
                Lifecycle.Event.ON_PAUSE -> mapView.onPause()
                Lifecycle.Event.ON_STOP -> mapView.onStop()
                else -> Unit
            }
        }
        lifecycle.addObserver(observer)
        mapView.onStart()
        mapView.onResume()
        onDispose {
            lifecycle.removeObserver(observer)
            mapView.onPause()
            mapView.onStop()
            mapView.onDestroy()
        }
    }
    AndroidView(factory = { mapView }, modifier = Modifier.fillMaxSize())
}

/** Route (dim), played part (amber), start / end / marker pins and the car arrow — mock artboard 5's layers. */
private fun addRouteLayers(style: Style, r: Replay) {
    val route = LineString.fromLngLats((0 until r.count step 5).map { r.point(it) } + r.point(r.count - 1))
    style.addSource(GeoJsonSource("route", route))
    style.addSource(GeoJsonSource("played", LineString.fromLngLats(listOf(r.point(0), r.point(0)))))
    val pins = mutableListOf(
        Feature.fromGeometry(r.point(0)).apply { addStringProperty("kind", "start") },
        Feature.fromGeometry(r.point(r.count - 1)).apply { addStringProperty("kind", "end") },
    )
    for (k in r.markers.indices step 2) {
        val i = (r.markers[k] * Replay.HZ).toInt()
        pins += Feature.fromGeometry(r.point(i)).apply { addStringProperty("kind", "marker") }
    }
    style.addSource(GeoJsonSource("pins", FeatureCollection.fromFeatures(pins)))
    style.addSource(GeoJsonSource("car", Feature.fromGeometry(r.point(0))))
    style.addImage("car-arrow", arrowBitmap())

    style.addLayer(LineLayer("route-line", "route").withProperties(
        PropertyFactory.lineColor(Theme.textTertiary.toArgb()), PropertyFactory.lineWidth(4f),
        PropertyFactory.lineCap(Property.LINE_CAP_ROUND), PropertyFactory.lineJoin(Property.LINE_JOIN_ROUND),
    ))
    style.addLayer(LineLayer("played-line", "played").withProperties(
        PropertyFactory.lineColor(Theme.accent.toArgb()), PropertyFactory.lineWidth(5f),
        PropertyFactory.lineCap(Property.LINE_CAP_ROUND), PropertyFactory.lineJoin(Property.LINE_JOIN_ROUND),
    ))
    style.addLayer(CircleLayer("pin-circles", "pins").withProperties(
        PropertyFactory.circleRadius(7f),
        PropertyFactory.circleColor(
            Expression.match(
                Expression.get("kind"), Expression.color(Theme.textPrimary.toArgb()),
                Expression.stop("start", Expression.color(Theme.good.toArgb())),
                Expression.stop("end", Expression.color(Theme.rec.toArgb())),
            ),
        ),
        PropertyFactory.circleStrokeColor(Theme.background.toArgb()), PropertyFactory.circleStrokeWidth(2f),
    ))
    style.addLayer(SymbolLayer("car-symbol", "car").withProperties(
        PropertyFactory.iconImage("car-arrow"), PropertyFactory.iconRotate(Expression.get("course")),
        PropertyFactory.iconRotationAlignment(Property.ICON_ROTATION_ALIGNMENT_MAP),
        PropertyFactory.iconAllowOverlap(true), PropertyFactory.iconIgnorePlacement(true),
    ))
}

/**
 * The GSI style names its PMTiles archive the GL JS way (`tiles: ["pmtiles://…/{z}/{x}/{y}"]`); MapLibre Native wants
 * the archive itself as the source `url`.
 */
private fun gsiStyleJson(url: String): String {
    val style = JSONObject(java.net.URL(url).readText())
    val sources = style.getJSONObject("sources")
    for (name in sources.keys()) {
        val source = sources.getJSONObject(name)
        val tiles = source.optJSONArray("tiles") ?: continue
        val first = tiles.getString(0)
        if (!first.startsWith("pmtiles://")) continue
        source.remove("tiles")
        source.put("url", first.substringBefore("/{z}"))
    }
    return style.toString()
}

internal fun arrowBitmap(): Bitmap {
    val size = 72
    val bitmap = Bitmap.createBitmap(size, size, Bitmap.Config.ARGB_8888)
    val canvas = Canvas(bitmap)
    val path = Path().apply {
        moveTo(size / 2f, 6f); lineTo(size - 12f, size - 8f); lineTo(size / 2f, size * 0.68f); lineTo(12f, size - 8f); close()
    }
    canvas.drawPath(path, Paint(Paint.ANTI_ALIAS_FLAG).apply { color = Theme.accent.toArgb() })
    canvas.drawPath(path, Paint(Paint.ANTI_ALIAS_FLAG).apply { color = Theme.background.toArgb(); style = Paint.Style.STROKE; strokeWidth = 4f })
    return bitmap
}

private fun clock(seconds: Double): String {
    val s = seconds.toInt()
    return "%d:%02d".format(s / 60, s % 60)
}

/** Android's Geocoder on the start and end of the drive, next to what MapKit gave on the iPhone (ios-places.json). */
private suspend fun comparePlaces(context: Context, sessionDir: File, r: Replay): String {
    val geocoder = Geocoder(context, Locale.JAPAN)
    fun line(a: Address?) = a?.let { listOfNotNull(it.adminArea, it.subAdminArea, it.locality, it.subLocality, it.thoroughfare, it.featureName).joinToString(" / ") } ?: "—"
    suspend fun lookup(i: Int): Address? = kotlinx.coroutines.suspendCancellableCoroutine { cont ->
        geocoder.getFromLocation(r.at(i, 1), r.at(i, 2), 1, object : Geocoder.GeocodeListener {
            override fun onGeocode(addresses: MutableList<Address>) { cont.resumeWith(Result.success(addresses.firstOrNull())) }
            override fun onError(errorMessage: String?) { cont.resumeWith(Result.success(null)) }
        })
    }
    val ios = runCatching { JSONObject(File(sessionDir, "ios-places.json").readText()).getJSONArray("places") }.getOrNull()
    fun iosLine(role: String): String {
        val places = ios ?: return "—"
        for (k in 0 until places.length()) {
            val p = places.getJSONObject(k)
            if (p.getString("role") == role) return listOf("administrativeArea", "locality", "subLocality", "name").mapNotNull { p.optString(it).takeIf { v -> v.isNotEmpty() && v != "null" } }.joinToString(" / ")
        }
        return "—"
    }
    return """
        start  Android: ${line(lookup(0))}
               iOS:     ${iosLine("start")}
        end    Android: ${line(lookup(r.count - 1))}
               iOS:     ${iosLine("end")}
    """.trimIndent()
}
