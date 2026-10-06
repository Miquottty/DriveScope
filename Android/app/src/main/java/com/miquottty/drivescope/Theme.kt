package com.miquottty.drivescope

import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.darkColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.ui.graphics.Color

/** Design tokens from design/mock/README.md — the same dark single theme as the iOS app's `Theme`. */
object Theme {
    val background = Color(0xFF0B0D10)
    val hudBackground = Color(0xFF000000)
    val surface = Color(0xFF14181D)
    val divider = Color(0xFF1F252C)
    val textPrimary = Color(0xFFE8ECF0)
    val textSecondary = Color(0xFF8A94A0)
    val textTertiary = Color(0xFF5C6670)
    val accent = Color(0xFFF2A33A)
    val rec = Color(0xFFE5484D)
    val good = Color(0xFF7BD88F)
}

@Composable
fun DriveScopeTheme(content: @Composable () -> Unit) {
    MaterialTheme(
        colorScheme = darkColorScheme(
            primary = Theme.accent,
            background = Theme.background,
            surface = Theme.surface,
            onBackground = Theme.textPrimary,
            onSurface = Theme.textPrimary,
            error = Theme.rec,
        ),
        content = content,
    )
}
