import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

/// Design tokens specifically tailored for the TekFix ERP Dashboard.
/// Implements Dark navy background (#0B1030 to #101846 gradient),
/// Glassmorphism styling, glowing borders, and Poppins/Inter typography.
class DashboardColors {
  DashboardColors._();

  // Background Gradient Ends
  static const Color bgDarkNavyStart = Color(0xFF0B1030);
  static const Color bgDarkNavyEnd = Color(0xFF101846);

  // Surface & Glassmorphic Fills
  static const Color glassFill = Color(0x1A1B2A55);
  static const Color glassFillHover = Color(0x2B273A6E);
  static const Color glassBorder = Color(0x24FFFFFF);
  static const Color glassBorderHover = Color(0x4D00D4FF);

  // Neon & Brand Accents
  static const Color neonBlue = Color(0xFF00D4FF);
  static const Color primaryBlue = Color(0xFF1677FF);
  static const Color neonPurple = Color(0xFF8B5CF6);
  static const Color neonPink = Color(0xFFEC4899);
  static const Color neonGreen = Color(0xFF10B981);
  static const Color neonOrange = Color(0xFFF59E0B);
  static const Color alertOrange = Color(0xFFFF6B00);

  // Typography
  static const Color textWhite = Color(0xFFFFFFFF);
  static const Color textLight = Color(0xFFE2E8F0);
  static const Color textMuted = Color(0xFF94A3B8);
  static const Color textDarkMuted = Color(0xFF64748B);

  // Background Gradient
  static const LinearGradient backgroundGradient = LinearGradient(
    colors: [bgDarkNavyStart, bgDarkNavyEnd],
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
  );

  // Active Pill Gradient (Blue)
  static const LinearGradient activePillGradient = LinearGradient(
    colors: [Color(0xFF00D4FF), Color(0xFF1677FF)],
    begin: Alignment.centerLeft,
    end: Alignment.centerRight,
  );

  // Hero Banner Gradient (Purple to Blue)
  static const LinearGradient heroGradient = LinearGradient(
    colors: [Color(0xFF5B21B6), Color(0xFF3B82F6), Color(0xFF1D4ED8)],
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
  );

  // Alert Banner Gradient (Orange)
  static const LinearGradient alertGradient = LinearGradient(
    colors: [Color(0xFFEA580C), Color(0xFFF97316)],
    begin: Alignment.centerLeft,
    end: Alignment.centerRight,
  );

  // Glass card decoration helper
  static BoxDecoration glassCard({
    double radius = 18,
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
        color: borderColor ?? (glow && glowColor != null ? glowColor.withValues(alpha: 0.5) : glassBorder),
        width: borderWidth,
      ),
      boxShadow: [
        BoxShadow(
          color: Colors.black.withValues(alpha: 0.35),
          blurRadius: 18,
          offset: const Offset(0, 6),
        ),
        if (glow && glowColor != null)
          BoxShadow(
            color: glowColor.withValues(alpha: 0.22),
            blurRadius: 16,
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
    return GoogleFonts.poppins(
      fontSize: fontSize,
      fontWeight: fontWeight,
      color: color,
      letterSpacing: letterSpacing,
      height: height,
    ).copyWith(fontFamilyFallback: malayalamFallback);
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
