package com.miquottty.drivescope.map

import android.content.Context
import android.content.pm.PackageManager
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.toArgb
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import com.google.android.gms.maps.CameraUpdateFactory
import com.google.android.gms.maps.model.BitmapDescriptorFactory
import com.google.android.gms.maps.model.CameraPosition
import com.google.android.gms.maps.model.LatLng
import com.google.android.gms.maps.model.LatLngBounds
import com.google.android.gms.maps.model.MapStyleOptions
import com.google.maps.android.compose.Circle
import com.google.maps.android.compose.GoogleMap
import com.google.maps.android.compose.MapProperties
import com.google.maps.android.compose.MapUiSettings
import com.google.maps.android.compose.Marker
import com.google.maps.android.compose.MarkerState
import com.google.maps.android.compose.Polyline
import com.google.maps.android.compose.rememberCameraPositionState
import com.miquottty.drivescope.Theme

/** The same Replay layers on Google Maps (Maps Compose), for the S0 map comparison. */
@Composable
fun GoogleMapPane(replay: Replay, t: Double, follow: Boolean, threeD: Boolean) {
    val context = LocalContext.current
    if (!hasMapsKey(context)) {
        Box(Modifier.fillMaxSize().background(Theme.surface)) {
            Text(
                "No Google Maps key — add MAPS_API_KEY=… to Android/local.properties and rebuild",
                color = Theme.textSecondary, modifier = Modifier.align(Alignment.Center).padding(24.dp),
            )
        }
        return
    }
    val route = remember(replay) { (0 until replay.count step 5).map { LatLng(replay.at(it, 1), replay.at(it, 2)) } }
    val markerPoints = remember(replay) {
        (replay.markers.indices step 2).map { k -> (replay.markers[k] * Replay.HZ).toInt().let { LatLng(replay.at(it, 1), replay.at(it, 2)) } }
    }
    val arrow = remember { BitmapDescriptorFactory.fromBitmap(arrowBitmap()) }
    val camera = rememberCameraPositionState()
    val f = replay.sample(t)
    val end = (t * Replay.HZ).toInt().coerceIn(1, replay.count - 1) / 5

    LaunchedEffect(replay) {
        val bounds = LatLngBounds.builder().apply { route.forEach { include(it) } }.build()
        camera.move(CameraUpdateFactory.newLatLngBounds(bounds, 120))
    }
    LaunchedEffect(t, follow, threeD) {
        if (!follow) return@LaunchedEffect
        camera.move(
            CameraUpdateFactory.newCameraPosition(
                CameraPosition.Builder().target(LatLng(f[1], f[2]))
                    .zoom(if (threeD) 17f else 16f)
                    .bearing(if (threeD) f[4].toFloat() else 0f)
                    .tilt(if (threeD) 60f else 0f)
                    .build(),
            ),
        )
    }

    GoogleMap(
        modifier = Modifier.fillMaxSize(),
        cameraPositionState = camera,
        properties = MapProperties(mapStyleOptions = MapStyleOptions(DARK_STYLE), isBuildingEnabled = true),
        uiSettings = MapUiSettings(zoomControlsEnabled = false, mapToolbarEnabled = false, compassEnabled = false),
    ) {
        Polyline(points = route, color = Theme.textTertiary, width = 12f)
        Polyline(points = route.take(end + 1) + LatLng(f[1], f[2]), color = Theme.accent, width = 14f)
        Circle(center = route.first(), radius = 8.0, fillColor = Theme.good, strokeColor = Theme.background, strokeWidth = 4f)
        Circle(center = route.last(), radius = 8.0, fillColor = Theme.rec, strokeColor = Theme.background, strokeWidth = 4f)
        for (point in markerPoints) {
            Circle(center = point, radius = 6.0, fillColor = Theme.textPrimary, strokeColor = Theme.background, strokeWidth = 4f)
        }
        Marker(
            state = MarkerState(LatLng(f[1], f[2])), icon = arrow, rotation = f[4].toFloat(), flat = true,
            anchor = androidx.compose.ui.geometry.Offset(0.5f, 0.5f),
        )
    }
}

private fun hasMapsKey(context: Context): Boolean {
    val info = context.packageManager.getApplicationInfo(context.packageName, PackageManager.GET_META_DATA)
    return !info.metaData?.getString("com.google.android.geo.API_KEY").isNullOrBlank()
}

/** Google's JSON styling in the app's tokens: muted dark, no points of interest (as MapKit's `.muted`). */
private val DARK_STYLE = """
[
  {"elementType":"geometry","stylers":[{"color":"#${hex(Theme.surface.toArgb())}"}]},
  {"elementType":"labels.text.fill","stylers":[{"color":"#${hex(Theme.textSecondary.toArgb())}"}]},
  {"elementType":"labels.text.stroke","stylers":[{"color":"#${hex(Theme.background.toArgb())}"}]},
  {"featureType":"poi","stylers":[{"visibility":"off"}]},
  {"featureType":"transit","stylers":[{"visibility":"off"}]},
  {"featureType":"road","elementType":"geometry","stylers":[{"color":"#2A323B"}]},
  {"featureType":"road.highway","elementType":"geometry","stylers":[{"color":"#3A434E"}]},
  {"featureType":"water","elementType":"geometry","stylers":[{"color":"#${hex(Theme.background.toArgb())}"}]}
]
""".trimIndent()

private fun hex(argb: Int) = "%06X".format(argb and 0xFFFFFF)
