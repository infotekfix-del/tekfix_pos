import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

/// ============================================================================
/// TEKFIX DIGITAL - DESIGN SYSTEM TOKENS
/// Strict brand color specifications, gradients, typography, and theme definitions
/// Mobile-First, Responsive Premium Dark UI with Malayalam & English support.
/// ============================================================================

class TekColors {
  TekColors._();

  // Core Surfaces (Enterprise SaaS Palette)
  static const Color mainBg = Color(0xFF070B18);           // Main Background (#070B18)
  static const Color sidebarBg = Color(0xFF0B1226);        // Sidebar Background (#0B1226)
  static const Color cardBg = Color(0xFF111B35);           // Card Background (#111B35)
  static const Color elevatedSurface = Color(0xFF172442);  // Elevated Surface (#172442)

  // Backward compatibility surface aliases
  static const Color bgMain = mainBg;
  static const Color bgSecondary = sidebarBg;
  static const Color bgCard = cardBg;
  static const Color bgCardHover = elevatedSurface;

  // Accents & Brand Primaries
  static const Color primaryBlue = Color(0xFF1677FF);      // Primary Blue (#1677FF)
  static const Color electricCyan = Color(0xFF00D4FF);     // Electric Cyan (#00D4FF)
  static const Color premiumPurple = Color(0xFF8B5CF6);    // Premium Purple (#8B5CF6)
  static const Color primary = primaryBlue;                // Alias: Primary Blue
  static const Color primaryLight = Color(0xFF4096FF);     // Lighter Blue Accent
  static const Color primaryDark = Color(0xFF0958D9);      // Deeper Blue
  static const Color secondary = premiumPurple;            // Alias: Premium Purple
  static const Color secondarySoft = Color(0xFFA78BFA);    // Soft Violet Tint

  // Status & Feedback Badges
  static const Color success = Color(0xFF22C55E);          // Success Green (#22C55E)
  static const Color warning = Color(0xFFF59E0B);          // Warning Orange (#F59E0B)
  static const Color error = Color(0xFFF43F5E);            // Error Red (#F43F5E)
  static const Color info = electricCyan;                  // Electric Cyan

  // Typography & Borders
  static const Color textPrimary = Color(0xFFF8FAFC);      // Primary Text (#F8FAFC)
  static const Color textSecondary = Color(0xFF94A3B8);    // Secondary Text (#94A3B8)
  static const Color textMuted = Color(0xFF64748B);        // Muted Text
  static const Color border = Color(0xFF263452);           // Border (#263452)
  static const Color borderSubtle = Color(0xFF1A2640);     // Subtle Divider Border

  // Gradients
  static const LinearGradient primaryGradient = LinearGradient(
    colors: [primaryBlue, premiumPurple],
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
  );

  static const LinearGradient cyanBlueGradient = LinearGradient(
    colors: [electricCyan, primaryBlue],
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
  );

  static const LinearGradient accentGradient = LinearGradient(
    colors: [electricCyan, premiumPurple],
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
  );

  static const LinearGradient heroGradient = LinearGradient(
    colors: [Color(0xFF111B35), Color(0xFF172442), Color(0xFF0F1A33)],
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
  );

  static const LinearGradient cardGradient = LinearGradient(
    colors: [Color(0xFF111B35), Color(0xFF0B1226)],
    begin: Alignment.topCenter,
    end: Alignment.bottomCenter,
  );

  static const LinearGradient glowGradient = LinearGradient(
    colors: [Color(0x331677FF), Colors.transparent],
    begin: Alignment.topCenter,
    end: Alignment.bottomCenter,
  );

  // Shadows
  static List<BoxShadow> get cardShadow => [
        BoxShadow(
          color: Colors.black.withValues(alpha: 0.45),
          blurRadius: 18,
          offset: const Offset(0, 8),
        ),
      ];

  static List<BoxShadow> get primaryGlow => [
        BoxShadow(
          color: primaryBlue.withValues(alpha: 0.35),
          blurRadius: 16,
          offset: const Offset(0, 4),
        ),
      ];

  static List<BoxShadow> get floatingNavShadow => [
        BoxShadow(
          color: Colors.black.withValues(alpha: 0.6),
          blurRadius: 28,
          offset: const Offset(0, 10),
        ),
      ];
}

/// Typography tokens supporting English and Malayalam (Noto Sans Malayalam fallback)
class TekTypography {
  TekTypography._();

  static const List<String> malayalamFallback = [
    'Noto Sans Malayalam',
    'Roboto',
    'Segoe UI',
    'sans-serif',
  ];

  static TextStyle get titleLarge => const TextStyle(
        color: TekColors.textPrimary,
        fontSize: 22,
        fontWeight: FontWeight.bold,
        letterSpacing: -0.4,
        fontFamilyFallback: malayalamFallback,
      );

  static TextStyle get titleMedium => const TextStyle(
        color: TekColors.textPrimary,
        fontSize: 16,
        fontWeight: FontWeight.w600,
        fontFamilyFallback: malayalamFallback,
      );

  static TextStyle get bodyPrimary => const TextStyle(
        color: TekColors.textPrimary,
        fontSize: 14,
        fontWeight: FontWeight.normal,
        fontFamilyFallback: malayalamFallback,
      );

  static TextStyle get bodySecondary => const TextStyle(
        color: TekColors.textSecondary,
        fontSize: 13,
        fontWeight: FontWeight.normal,
        height: 1.4,
        fontFamilyFallback: malayalamFallback,
      );

  static TextStyle get caption => const TextStyle(
        color: TekColors.textSecondary,
        fontSize: 11,
        fontWeight: FontWeight.w500,
        fontFamilyFallback: malayalamFallback,
      );

  static TextStyle get badge => const TextStyle(
        color: Colors.white,
        fontSize: 11,
        fontWeight: FontWeight.bold,
        letterSpacing: 0.3,
        fontFamilyFallback: malayalamFallback,
      );

  /// Dedicated high-legibility Malayalam font with explicit line-height (1.35-1.4)
  /// preventing vowel sign and chandrakala clipping across mobile screens.
  static TextStyle malayalam({
    double fontSize = 12,
    FontWeight fontWeight = FontWeight.normal,
    Color color = TekColors.textSecondary,
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

/// Global Theme provider for TekFix Digital
class TekTheme {
  TekTheme._();

  static ThemeData get darkTheme {
    final colorScheme = const ColorScheme.dark().copyWith(
      primary: TekColors.primary,
      onPrimary: Colors.white,
      secondary: TekColors.secondary,
      onSecondary: Colors.white,
      surface: TekColors.bgCard,
      onSurface: TekColors.textPrimary,
      onSurfaceVariant: TekColors.textSecondary,
      outline: TekColors.border,
      outlineVariant: TekColors.borderSubtle,
      error: TekColors.error,
      onError: Colors.white,
    );

    final inputBorder = OutlineInputBorder(
      borderRadius: BorderRadius.circular(14),
      borderSide: const BorderSide(color: TekColors.border, width: 1.2),
    );

    return ThemeData(
      useMaterial3: true,
      brightness: Brightness.dark,
      colorScheme: colorScheme,
      scaffoldBackgroundColor: TekColors.bgMain,
      fontFamilyFallback: TekTypography.malayalamFallback,
      cardColor: TekColors.bgCard,
      dividerColor: TekColors.border,
      cardTheme: CardThemeData(
        color: TekColors.bgCard,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: const BorderSide(color: TekColors.border, width: 1.2),
        ),
      ),
      appBarTheme: const AppBarTheme(
        backgroundColor: TekColors.bgSecondary,
        foregroundColor: TekColors.textPrimary,
        elevation: 0,
        centerTitle: false,
        titleTextStyle: TextStyle(
          color: TekColors.textPrimary,
          fontSize: 18,
          fontWeight: FontWeight.bold,
          fontFamilyFallback: TekTypography.malayalamFallback,
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: TekColors.bgSecondary,
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        border: inputBorder,
        enabledBorder: inputBorder,
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: const BorderSide(color: TekColors.primary, width: 1.8),
        ),
        hintStyle: const TextStyle(
          color: TekColors.textMuted,
          fontSize: 13,
          fontFamilyFallback: TekTypography.malayalamFallback,
        ),
        labelStyle: const TextStyle(
          color: TekColors.textSecondary,
          fontSize: 13,
          fontFamilyFallback: TekTypography.malayalamFallback,
        ),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: TekColors.primary,
          foregroundColor: Colors.white,
          elevation: 2,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
          textStyle: const TextStyle(
            fontWeight: FontWeight.bold,
            fontSize: 14,
            fontFamilyFallback: TekTypography.malayalamFallback,
          ),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: TekColors.secondary,
          side: const BorderSide(color: TekColors.border, width: 1.2),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
        ),
      ),
      snackBarTheme: SnackBarThemeData(
        backgroundColor: TekColors.bgSecondary,
        contentTextStyle: const TextStyle(
          color: TekColors.textPrimary,
          fontFamilyFallback: TekTypography.malayalamFallback,
        ),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: const BorderSide(color: TekColors.border),
        ),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }
}
