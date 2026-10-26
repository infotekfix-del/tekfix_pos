package com.tekfix.orders.ui.theme

import android.app.Activity
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.SideEffect
import androidx.compose.ui.graphics.toArgb
import androidx.compose.ui.platform.LocalView
import androidx.core.view.WindowCompat

private val LightColorScheme = lightColorScheme(
    primary = TekfixGreen,
    onPrimary = SurfaceLight,
    primaryContainer = TekfixLightGreen,
    onPrimaryContainer = TekfixDarkGreen,
    secondary = WhatsAppGreen,
    onSecondary = SurfaceLight,
    secondaryContainer = WhatsAppTeal,
    onSecondaryContainer = SurfaceLight,
    tertiary = WhatsAppDarkGreen,
    background = BackgroundLight,
    onBackground = TextPrimary,
    surface = SurfaceLight,
    onSurface = TextPrimary,
    surfaceVariant = SurfaceVariantLight,
    onSurfaceVariant = TextSecondary,
    outline = CardBorder
)

private val DarkColorScheme = darkColorScheme(
    primary = TekfixMint,
    onPrimary = TekfixDarkGreen,
    primaryContainer = TekfixDarkGreen,
    onPrimaryContainer = TekfixLightGreen,
    secondary = WhatsAppGreen,
    onSecondary = BackgroundDark,
    background = BackgroundDark,
    onBackground = TextPrimaryDark,
    surface = SurfaceDark,
    onSurface = TextPrimaryDark,
    surfaceVariant = SurfaceVariantDark,
    onSurfaceVariant = TextSecondaryDark,
    outline = SurfaceVariantDark
)

@Composable
fun TekfixOrdersTheme(
    darkTheme: Boolean = isSystemInDarkTheme(),
    content: @Composable () -> Unit
) {
    val colorScheme = if (darkTheme) DarkColorScheme else LightColorScheme
    val view = LocalView.current
    if (!view.isInEditMode) {
        SideEffect {
            val window = (view.context as Activity).window
            window.statusBarColor = if (darkTheme) BackgroundDark.toArgb() else TekfixDarkGreen.toArgb()
            WindowCompat.getInsetsController(window, view).isAppearanceLightStatusBars = false
        }
    }

    MaterialTheme(
        colorScheme = colorScheme,
        typography = Typography,
        content = content
    )
}
