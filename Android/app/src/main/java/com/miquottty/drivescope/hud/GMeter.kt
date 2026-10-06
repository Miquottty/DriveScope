package com.miquottty.drivescope.hud

import androidx.compose.foundation.Canvas
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.remember
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.drawText
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.rememberTextMeasurer
import androidx.compose.ui.unit.sp
import com.miquottty.drivescope.Theme
import kotlin.math.hypot
import kotlin.math.min

/**
 * Friction-circle G meter (iOS `GMeterView`, #32): rings at ⅓ / ⅔ / 1 of `range`; the dot moves the way the driver is
 * pushed — a left turn (+lateral) plots right, braking plots up, accelerating down. Amber wedge = the recent trail.
 */
@Composable
fun GMeter(lateralG: Double, longitudinalG: Double, modifier: Modifier = Modifier, range: Double = 1.0) {
    val trail = remember { mutableStateListOf<Pair<Double, Double>>() }
    LaunchedEffect(lateralG, longitudinalG) {
        trail.add(lateralG to longitudinalG)
        while (trail.size > 12) trail.removeAt(0)
    }
    val measurer = rememberTextMeasurer()
    Canvas(modifier) {
        val center = Offset(size.width / 2, size.height / 2)
        val outer = min(size.width, size.height) / 2 - 4
        fun point(lat: Double, long: Double): Offset {
            var x = LATERAL_SIGN * lat / range
            var y = LONGITUDINAL_SIGN * long / range
            val r = hypot(x, y)
            if (r > 1) { x /= r; y /= r }
            return Offset(center.x + (x * outer).toFloat(), center.y - (y * outer).toFloat())
        }
        for ((fraction, width) in listOf(1f to 1.5f, 2 / 3f to 1f, 1 / 3f to 1f)) {
            drawCircle(Theme.divider, radius = outer * fraction, center = center, style = Stroke(width * density))
        }
        drawLine(Theme.divider, Offset(center.x, center.y - outer), Offset(center.x, center.y + outer), density)
        drawLine(Theme.divider, Offset(center.x - outer, center.y), Offset(center.x + outer, center.y), density)
        if (trail.size > 1) {
            val wedge = Path().apply {
                moveTo(center.x, center.y)
                for ((lat, long) in trail) point(lat, long).let { lineTo(it.x, it.y) }
                close()
            }
            drawPath(wedge, Theme.accent.copy(alpha = 0.18f))
        }
        val label = measurer.measure("%.1f G".format(range), TextStyle(color = Theme.textSecondary, fontSize = 12.sp, fontFamily = FontFamily.Monospace))
        drawText(label, topLeft = Offset(center.x - label.size.width / 2, center.y - outer + 8))
        drawCircle(Theme.accent, radius = 10 * density, center = point(lateralG, longitudinalG))
    }
}

/** Screen direction per g, as the driver is pushed (iOS `GMeterView.lateralSign` / `longitudinalSign`). */
private const val LATERAL_SIGN = 1.0
private const val LONGITUDINAL_SIGN = -1.0
