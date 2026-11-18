package dev.mirror.continuity.ui.theme

import android.app.Activity
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.SideEffect
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.toArgb
import androidx.compose.ui.platform.LocalView
import androidx.core.view.WindowCompat

private val StudioDarkColorScheme = darkColorScheme(
    primary = StudioTeal,
    onPrimary = Color(0xFF042420),
    primaryContainer = StudioTealTint,
    onPrimaryContainer = Color(0xFF99F6E4),
    secondary = Color(0xFF94A3B8),
    onSecondary = Color(0xFF0F172A),
    background = DarkWindowBg,
    onBackground = Color(0xFFF1F5F9),
    surface = DarkCardBg,
    onSurface = Color(0xFFF1F5F9),
    surfaceVariant = DarkRaisedBg,
    onSurfaceVariant = Color(0xFF94A3B8),
    outline = DarkBorder,
    outlineVariant = Color(0xFF232730),
    error = ContinuityRed
)

private val StudioLightColorScheme = lightColorScheme(
    primary = StudioTealDark,
    onPrimary = Color.White,
    primaryContainer = StudioTealContainerLight,
    onPrimaryContainer = Color(0xFF0F3D39),
    secondary = Color(0xFF475569),
    onSecondary = Color.White,
    background = LightWindowBg,
    onBackground = Color(0xFF0F172A),
    surface = LightCardBg,
    onSurface = Color(0xFF0F172A),
    surfaceVariant = LightRaisedBg,
    onSurfaceVariant = Color(0xFF475569),
    outline = LightBorder,
    outlineVariant = Color(0xFFE2E8F0),
    error = ContinuityRed
)

@Composable
fun ContinuityTheme(
    darkTheme: Boolean = isSystemInDarkTheme(),
    content: @Composable () -> Unit
) {
    val colorScheme = if (darkTheme) StudioDarkColorScheme else StudioLightColorScheme
    val view = LocalView.current
    if (!view.isInEditMode) {
        SideEffect {
            val window = (view.context as? Activity)?.window ?: return@SideEffect
            @Suppress("DEPRECATION")
            window.statusBarColor = colorScheme.background.toArgb()
            WindowCompat.getInsetsController(window, view).isAppearanceLightStatusBars = !darkTheme
        }
    }

    MaterialTheme(
        colorScheme = colorScheme,
        content = content
    )
}
