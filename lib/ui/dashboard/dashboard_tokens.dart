import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

/// Design tokens specifically tailored for the TekFix ERP Dashboard.
/// v2: neutral slate surfaces, single indigo accent, flat cards,
/// Inter typography (poppins() kept as an alias for compatibility).
class DashboardColors {
  DashboardColors._();

  // Background Gradient Ends
  static const Color bgDarkNavyStart = Color(0xFF0B0F17);
  static const Color bgDarkNavyEnd = Color(0xFF0B0F17);

  // Surface & Glassmorphic Fills
  static const Color glassFill = Color(0xFF121826);
  static const Color glassFillHover = Color(0xFF171E2E);
  static const Color glassBorder = Color(0xFF1F2937);
  static const Color glassBorderHover = Color(0x66818CF8);

  // Neon & Brand Accents
  static const Color neonBlue = Color(0xFF818CF8); // primary accent (indigo-400)
  static const Color primaryBlue = Color(0xFF4F46E5); // filled buttons (indigo-600)
  static const Color neonPurple = Color(0xFFA5B4FC); // secondary accent tint
  static const Color neonPink = Color(0xFFF87171); // danger / due
  static const Color neonGreen = Color(0xFF34D399); // success / positive
  static const Color neonOrange = Color(0xFFFBBF24); // warning / in progress
  static const Color alertOrange = Color(0xFFF59E0B);
  static const Color alertRed = Color(0xFFEF4444);

  // Semantic surfaces (v2)
  static const Color surface = Color(0xFF121826);
  static const Color surfaceAlt = Color(0xFF171E2E);
  static const Color border = Color(0xFF1F2937);
  static const Color accentBg = Color(0x1F818CF8);

  // Typography
  static const Color textWhite = Color(0xFFF3F4F6);
  static const Color textLight = Color(0xFFE5E7EB);
  static const Color textMuted = Color(0xFF9CA3AF);
  static const Color textDarkMuted = Color(0xFF7C8594);

  // Background Gradient
  static const LinearGradient backgroundGradient = LinearGradient(
    colors: [bgDarkNavyStart, bgDarkNavyEnd],
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
  );

  // Active Pill Gradient (Blue)
  static const LinearGradient activePillGradient = LinearGradient(
    colors: [Color(0xFF4F46E5), Color(0xFF4F46E5)],
    begin: Alignment.centerLeft,
    end: Alignment.centerRight,
  );

  // Hero Banner Gradient (Purple to Blue)
  static const LinearGradient heroGradient = LinearGradient(
    colors: [Color(0xFF4F46E5), Color(0xFF4338CA)],
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
  );

  // Alert Banner Gradient (Orange)
  static const LinearGradient alertGradient = LinearGradient(
    colors: [Color(0xFF92400E), Color(0xFFB45309)],
    begin: Alignment.centerLeft,
    end: Alignment.centerRight,
  );

  // Glass card decoration helper
  static BoxDecoration glassCard({
    double radius = 12,
    Color? borderColor,
    double borderWidth = 1.0,
    Color? fillColor,
    bool glow = false,
    Color? glowColor,
  }) {
    return BoxDecoration(
      color: fillColor ?? glassFill,
      borderRadius: BorderRadius.circular(radius),
      border: Border.all(
        color: borderColor ??
            (glow && glowColor != null
                ? glowColor.withValues(alpha: 0.5)
                : glassBorder),
        width: borderWidth,
      ),
      boxShadow: [
        BoxShadow(
          color: Colors.black.withValues(alpha: 0.18),
          blurRadius: 8,
          offset: const Offset(0, 2),
        ),
        if (glow && glowColor != null)
          BoxShadow(
            color: glowColor.withValues(alpha: 0.12),
            blurRadius: 12,
            offset: const Offset(0, 2),
          ),
      ],
    );
  }
}

class DashboardTypography {
  DashboardTypography._();

  static const List<String> malayalamFallback = [
    'Noto Sans Malayalam',
    'Roboto',
    'Segoe UI',
    'sans-serif',
  ];

  static TextStyle inter({
    double fontSize = 14,
    FontWeight fontWeight = FontWeight.normal,
    Color color = DashboardColors.textWhite,
    double? letterSpacing,
    double? height,
  }) {
    return GoogleFonts.inter(
      fontSize: fontSize,
      fontWeight: fontWeight,
      color: color,
      letterSpacing: letterSpacing,
      height: height,
    ).copyWith(fontFamilyFallback: malayalamFallback);
  }

  static TextStyle poppins({
    double fontSize = 20,
    FontWeight fontWeight = FontWeight.bold,
    Color color = DashboardColors.textWhite,
    double? letterSpacing,
    double? height,
  }) {
    return GoogleFonts.inter(
      fontSize: fontSize,
      fontWeight: fontWeight,
      color: color,
      letterSpacing: letterSpacing,
      height: height,
    ).copyWith(
      fontFamilyFallback: malayalamFallback,
      fontFeatures: const [FontFeature.tabularFigures()],
    );
  }

  /// Dedicated high-legibility Malayalam font with explicit line-height
  /// to eliminate character clipping (chandrakala, vowel signs) at all DPIs.
  static TextStyle malayalam({
    double fontSize = 12,
    FontWeight fontWeight = FontWeight.normal,
    Color color = DashboardColors.textMuted,
    double height = 1.35,
    double? letterSpacing,
  }) {
    return GoogleFonts.notoSansMalayalam(
      fontSize: fontSize,
      fontWeight: fontWeight,
      color: color,
      height: height,
      letterSpacing: letterSpacing,
    );
  }
}
