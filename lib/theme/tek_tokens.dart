import 'package:flutter/material.dart';

/// ============================================================================
/// TEKFIX DIGITAL - DESIGN SYSTEM TOKENS
/// Strict brand color specifications, gradients, typography, and theme definitions
/// Mobile-First, Responsive Premium Dark UI with Malayalam & English support.
/// ============================================================================

class TekColors {
  TekColors._();

  // Core Surfaces
  static const Color bgMain = Color(0xFF080D1C);          // Main Background
  static const Color bgSecondary = Color(0xFF10182B);     // Secondary Background
  static const Color bgCard = Color(0xFF151F38);          // Card Background
  static const Color bgCardHover = Color(0xFF1E2A4B);     // Interactive Card Hover

  // Accents & Brand Primary
  static const Color primary = Color(0xFF7957FF);         // Primary Accent (#7957FF)
  static const Color primaryLight = Color(0xFF9074FF);    // Lighter Lavender Accent
  static const Color primaryDark = Color(0xFF6038F6);     // Deeper Purple
  static const Color secondary = Color(0xFFA78BFA);       // Secondary Accent (#A78BFA)
  static const Color secondarySoft = Color(0xFFC4B5FD);   // Soft Violet Tint

  // Status & Feedback Badges
  static const Color success = Color(0xFF22C55E);         // Success Green (#22C55E)
  static const Color warning = Color(0xFFFBBF24);         // Warning Amber (#FBBF24)
  static const Color error = Color(0xFFFB7185);           // Error Coral/Rose (#FB7185)
  static const Color info = Color(0xFF38BDF8);            // Sky Info Accent

  // Typography & Borders
  static const Color textPrimary = Color(0xFFF8FAFC);     // Primary Text (#F8FAFC)
  static const Color textSecondary = Color(0xFFA6B0C3);   // Secondary Text (#A6B0C3)
  static const Color textMuted = Color(0xFF6B7A99);       // Muted Hint Text
  static const Color border = Color(0xFF293550);          // Standard Border (#293550)
  static const Color borderSubtle = Color(0xFF1C263D);    // Subtle Divider Border

  // Gradients
  static const LinearGradient primaryGradient = LinearGradient(
    colors: [Color(0xFF7957FF), Color(0xFF6038F6)],
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
  );

  static const LinearGradient accentGradient = LinearGradient(
    colors: [Color(0xFF7957FF), Color(0xFFA78BFA)],
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
  );

  static const LinearGradient cardGradient = LinearGradient(
    colors: [Color(0xFF151F38), Color(0xFF10182B)],
    begin: Alignment.topCenter,
    end: Alignment.bottomCenter,
  );

  static const LinearGradient glowGradient = LinearGradient(
    colors: [Color(0x337957FF), Colors.transparent],
    begin: Alignment.topCenter,
    end: Alignment.bottomCenter,
  );

  // Shadows
  static List<BoxShadow> get cardShadow => [
        BoxShadow(
          color: Colors.black.withValues(alpha: 0.35),
          blurRadius: 16,
          offset: const Offset(0, 6),
        ),
      ];

  static List<BoxShadow> get primaryGlow => [
        BoxShadow(
          color: primary.withValues(alpha: 0.35),
          blurRadius: 14,
          offset: const Offset(0, 4),
        ),
      ];

  static List<BoxShadow> get floatingNavShadow => [
        BoxShadow(
          color: Colors.black.withValues(alpha: 0.5),
          blurRadius: 24,
          offset: const Offset(0, 8),
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
        fontSize: 20,
        fontWeight: FontWeight.bold,
        letterSpacing: -0.3,
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
        height: 1.35,
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
