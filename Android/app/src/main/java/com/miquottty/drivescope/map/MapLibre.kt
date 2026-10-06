package com.miquottty.drivescope.map

import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Paint
import android.graphics.Path
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.remember
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.toArgb
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalLifecycleOwner
import androidx.compose.ui.viewinterop.AndroidView
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import com.miquottty.drivescope.Theme
import com.miquottty.drivescope.bridge.DriveKitBridge
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import org.json.JSONObject
import org.maplibre.android.MapLibre
import org.maplibre.android.camera.CameraUpdateFactory
import org.maplibre.android.geometry.LatLng
import org.maplibre.android.geometry.LatLngBounds
import org.maplibre.android.maps.MapLibreMap
import org.maplibre.android.maps.MapLibreMapOptions
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

/** The app's maps (docs/ANDROID_SPIKE.md: MapLibre; Google Maps parked in #40). */
enum class MapStyle(val label: String, val url: String) {
    /** Default: dark and muted, like MapKit's `.muted` with no points of interest. */
    DARK("Dark", "https://tiles.openfreemap.org/styles/dark"),
    GSI("地理院", "https://gsi-cyberjapan.github.io/optimal_bvmap/style/std.json"),
}

/** Loads `style` into `map` (GSI's PMTiles source rewritten for MapLibre Native), then calls `onLoaded`. */
suspend fun MapLibreMap.load(style: MapStyle, onLoaded: (Style) -> Unit) {
    val builder = if (style == MapStyle.GSI) {
        Style.Builder().fromJson(withContext(Dispatchers.IO) { gsiStyleJson(style.url) })
    } else {
        Style.Builder().fromUri(style.url)
    }
    setStyle(builder) { onLoaded(it) }
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

/** A MapLibre `MapView` tied to the screen's lifecycle; `onMap` gets the map once it is ready. */
@Composable
fun MapLibreView(
    modifier: Modifier = Modifier.fillMaxSize(),
    interactive: Boolean = true,
    /** A map inside a scrolling screen needs a TextureView: the default SurfaceView stays blank there. */
    textureMode: Boolean = false,
    onMap: (MapLibreMap) -> Unit,
) {
    val context = LocalContext.current
    val lifecycle = LocalLifecycleOwner.current.lifecycle
    val mapView = remember {
        MapLibre.getInstance(context)
        MapView(context, MapLibreMapOptions.createFromAttributes(context).textureMode(textureMode)).apply {
            onCreate(null)
            getMapAsync { map ->
                map.uiSettings.isLogoEnabled = false
                map.uiSettings.isCompassEnabled = false
                map.uiSettings.setAllGesturesEnabled(interactive)
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
    AndroidView(factory = { mapView }, modifier = modifier)
}

/** Frames of a session from DriveKit (the iOS Replay interpolation) plus its markers. */
class Replay(val frames: DoubleArray, val markers: DoubleArray) {
    val count get() = frames.size / DriveKitBridge.FRAME_STRIDE
    val duration get() = if (count > 0) frames[(count - 1) * DriveKitBridge.FRAME_STRIDE] else 0.0
    fun at(i: Int, field: Int) = frames[i.coerceIn(0, count - 1) * DriveKitBridge.FRAME_STRIDE + field]
    fun point(i: Int): Point = Point.fromLngLat(at(i, 2), at(i, 1))
    fun latLng(i: Int) = LatLng(at(i, 1), at(i, 2))

    /**
     * Frames whose fix is good enough to draw (iOS `ReplayTimeline.routeAccuracyLimit`, 50 m): Wi‑Fi positions before
     * the satellite lock would zigzag across the map.
     */
    val routeIndices: List<Int> by lazy { (0 until count step 5).filter { at(it, 7) > 0 && at(it, 7) <= 50 } }

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

    /** Markers as (elapsed, kind) — kind 0 MARK, 1 SYNC, 2 HIGHLIGHT. */
    val markerList get() = (markers.indices step 2).map { markers[it] to markers[it + 1].toInt() }

    companion object {
        const val HZ = 10.0

        fun load(sessionDir: String) = Replay(DriveKitBridge.replayFrames(sessionDir, HZ), DriveKitBridge.markers(sessionDir))
    }
}

/** Route (dim), played part (amber), start / end / marker pins and the car arrow — mock artboards 4 and 5. */
fun addRouteLayers(style: Style, r: Replay, withCar: Boolean) {
    if (r.routeIndices.size < 2) return
    val route = LineString.fromLngLats(r.routeIndices.map { r.point(it) })
    style.addSource(GeoJsonSource("route", route))
    style.addSource(GeoJsonSource("played", LineString.fromLngLats(listOf(r.point(0), r.point(0)))))
    val pins = mutableListOf(
        Feature.fromGeometry(r.point(r.routeIndices.first())).apply { addStringProperty("kind", "start") },
        Feature.fromGeometry(r.point(r.routeIndices.last())).apply { addStringProperty("kind", "end") },
    )
    for ((elapsed, kind) in r.markerList) {
        pins += Feature.fromGeometry(r.point((elapsed * Replay.HZ).toInt())).apply { addStringProperty("kind", MARKER_KINDS[kind] ?: "mark") }
    }
    style.addSource(GeoJsonSource("pins", FeatureCollection.fromFeatures(pins)))
    style.addLayer(LineLayer("route-line", "route").withProperties(
        PropertyFactory.lineColor((if (withCar) Theme.textTertiary else Theme.accent).toArgb()), PropertyFactory.lineWidth(4f),
        PropertyFactory.lineCap(Property.LINE_CAP_ROUND), PropertyFactory.lineJoin(Property.LINE_JOIN_ROUND),
    ))
    style.addLayer(LineLayer("played-line", "played").withProperties(
        PropertyFactory.lineColor(Theme.accent.toArgb()), PropertyFactory.lineWidth(5f),
        PropertyFactory.lineCap(Property.LINE_CAP_ROUND), PropertyFactory.lineJoin(Property.LINE_JOIN_ROUND),
    ))
    // MARK white, SYNC green, HIGHLIGHT amber, start green, end red (iOS Replay pins).
    style.addLayer(CircleLayer("pin-circles", "pins").withProperties(
        PropertyFactory.circleRadius(7f),
        PropertyFactory.circleColor(
            Expression.match(
                Expression.get("kind"), Expression.color(Theme.textPrimary.toArgb()),
                Expression.stop("start", Expression.color(Theme.good.toArgb())),
                Expression.stop("end", Expression.color(Theme.rec.toArgb())),
                Expression.stop("sync", Expression.color(Theme.good.toArgb())),
                Expression.stop("highlight", Expression.color(Theme.accent.toArgb())),
            ),
        ),
        PropertyFactory.circleStrokeColor(Theme.background.toArgb()), PropertyFactory.circleStrokeWidth(2f),
    ))
    if (withCar) {
        style.addSource(GeoJsonSource("car", Feature.fromGeometry(r.point(0))))
        style.addImage("car-arrow", arrowBitmap())
        style.addLayer(SymbolLayer("car-symbol", "car").withProperties(
            PropertyFactory.iconImage("car-arrow"), PropertyFactory.iconRotate(Expression.get("course")),
            PropertyFactory.iconRotationAlignment(Property.ICON_ROTATION_ALIGNMENT_MAP),
            PropertyFactory.iconAllowOverlap(true), PropertyFactory.iconIgnorePlacement(true),
        ))
    }
}

private val MARKER_KINDS = mapOf(0 to "mark", 1 to "sync", 2 to "highlight")

fun MapLibreMap.fit(r: Replay, padding: Int = 80) {
    if (r.routeIndices.size < 2) return
    val bounds = LatLngBounds.Builder().includes(r.routeIndices.map { r.latLng(it) }).build()
    moveCamera(CameraUpdateFactory.newLatLngBounds(bounds, padding))
}

private fun arrowBitmap(): Bitmap {
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
