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
  static const Color mainBg = Color(0xFF0B0F17); // Main Background (#0B0F17) — neutral slate
  static const Color sidebarBg =
      Color(0xFF0E131D); // Sidebar Background (#0E131D)
  static const Color cardBg = Color(0xFF121826); // Card Background (#121826)
  static const Color elevatedSurface =
      Color(0xFF171E2E); // Elevated Surface (#171E2E)

  // Backward compatibility surface aliases
  static const Color bgMain = mainBg;
  static const Color bgSecondary = sidebarBg;
  static const Color bgCard = cardBg;
  static const Color bgCardHover = elevatedSurface;

  // Accents & Brand Primaries
  static const Color primaryBlue = Color(0xFF4F46E5); // Primary Indigo (#4F46E5) — the single brand accent
  static const Color electricCyan =
      Color(0xFF818CF8); // Accent tint for text/icons on dark (#818CF8)
  static const Color premiumPurple =
      Color(0xFFA5B4FC); // Soft indigo (#A5B4FC)
  static const Color primary = primaryBlue; // Alias: Primary Blue
  static const Color primaryLight = Color(0xFF818CF8); // Lighter Indigo Accent
  static const Color primaryDark = Color(0xFF4338CA); // Deeper Indigo
  static const Color secondary = premiumPurple; // Alias: Premium Purple
  static const Color secondarySoft = Color(0xFFC7D2FE); // Soft Indigo Tint

  // Status & Feedback Badges
  static const Color success = Color(0xFF34D399); // Success Green (#34D399)
  static const Color warning = Color(0xFFFBBF24); // Warning Amber (#FBBF24)
  static const Color error = Color(0xFFF87171); // Error Red (#F87171)
  static const Color info = Color(0xFF60A5FA); // Info Blue

  // Typography & Borders
  static const Color textPrimary = Color(0xFFE5E7EB); // Primary Text (#E5E7EB)
  static const Color textSecondary =
      Color(0xFF9CA3AF); // Secondary Text (#9CA3AF)
  static const Color textMuted = Color(0xFF7C8594); // Muted Text (≥4.5:1 on cards)
  static const Color border = Color(0xFF1F2937); // Border (#1F2937)
  static const Color borderSubtle = Color(0xFF182131); // Subtle Divider Border

  // Gradients
  static const LinearGradient primaryGradient = LinearGradient(
    colors: [primaryBlue, Color(0xFF6366F1)],
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
  );

  static const LinearGradient cyanBlueGradient = LinearGradient(
    colors: [Color(0xFF6366F1), primaryBlue],
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
  );

  static const LinearGradient accentGradient = LinearGradient(
    colors: [Color(0xFF6366F1), primaryBlue],
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
  );

  static const LinearGradient heroGradient = LinearGradient(
    colors: [Color(0xFF121826), Color(0xFF121826)],
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
  );

  static const LinearGradient cardGradient = LinearGradient(
    colors: [Color(0xFF121826), Color(0xFF121826)],
    begin: Alignment.topCenter,
    end: Alignment.bottomCenter,
  );

  static const LinearGradient glowGradient = LinearGradient(
    colors: [Color(0x1A4F46E5), Colors.transparent],
    begin: Alignment.topCenter,
    end: Alignment.bottomCenter,
  );

  // Shadows
  static List<BoxShadow> get cardShadow => [
        BoxShadow(
          color: Colors.black.withValues(alpha: 0.18),
          blurRadius: 8,
          offset: const Offset(0, 2),
        ),
      ];

  static List<BoxShadow> get primaryGlow => [
        BoxShadow(
          color: primaryBlue.withValues(alpha: 0.18),
          blurRadius: 10,
          offset: const Offset(0, 2),
        ),
      ];

  static List<BoxShadow> get floatingNavShadow => [
        BoxShadow(
          color: Colors.black.withValues(alpha: 0.35),
          blurRadius: 20,
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
///
/// v2 (Nov 2026): neutral slate surfaces, one indigo accent, Inter for Latin
/// text with Noto Sans Malayalam fallback, flat 12px-radius components.
class TekTheme {
  TekTheme._();

  static const double radius = 12;

  static TextTheme _textTheme(TextTheme base) {
    return GoogleFonts.interTextTheme(base)
        .apply(
          bodyColor: TekColors.textPrimary,
          displayColor: TekColors.textPrimary,
          fontFamilyFallback: TekTypography.malayalamFallback,
        );
  }

  static ThemeData get darkTheme {
    final colorScheme = const ColorScheme.dark().copyWith(
      primary: TekColors.primary,
      onPrimary: Colors.white,
      primaryContainer: const Color(0xFF262A5C),
      onPrimaryContainer: const Color(0xFFE0E7FF),
      secondary: TekColors.primaryLight,
      onSecondary: const Color(0xFF0B0F17),
      tertiary: TekColors.success,
      surface: TekColors.bgCard,
      onSurface: TekColors.textPrimary,
      onSurfaceVariant: TekColors.textSecondary,
      surfaceContainerLowest: TekColors.bgMain,
      surfaceContainerLow: TekColors.bgSecondary,
      surfaceContainer: TekColors.bgCard,
      surfaceContainerHigh: TekColors.elevatedSurface,
      surfaceContainerHighest: const Color(0xFF1C2436),
      outline: TekColors.border,
      outlineVariant: TekColors.borderSubtle,
      error: TekColors.error,
      onError: const Color(0xFF0B0F17),
    );

    final shape = RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(radius),
    );

    final inputBorder = OutlineInputBorder(
      borderRadius: BorderRadius.circular(10),
      borderSide: const BorderSide(color: TekColors.border, width: 1),
    );

    final base = ThemeData(brightness: Brightness.dark, useMaterial3: true);

    return ThemeData(
      useMaterial3: true,
      brightness: Brightness.dark,
      colorScheme: colorScheme,
      fontFamily: GoogleFonts.inter().fontFamily,
      fontFamilyFallback: TekTypography.malayalamFallback,
      textTheme: _textTheme(base.textTheme),
      scaffoldBackgroundColor: TekColors.bgMain,
      canvasColor: TekColors.bgMain,
      cardColor: TekColors.bgCard,
      dividerColor: TekColors.border,
      splashFactory: InkSparkle.splashFactory,
      visualDensity: VisualDensity.standard,
      dividerTheme: const DividerThemeData(
        color: TekColors.border,
        thickness: 1,
        space: 1,
      ),
      cardTheme: CardThemeData(
        color: TekColors.bgCard,
        elevation: 0,
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(radius),
          side: const BorderSide(color: TekColors.border, width: 1),
        ),
      ),
      appBarTheme: AppBarTheme(
        backgroundColor: TekColors.bgMain,
        surfaceTintColor: Colors.transparent,
        foregroundColor: TekColors.textPrimary,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: false,
        shape: const Border(
          bottom: BorderSide(color: TekColors.border, width: 1),
        ),
        titleTextStyle: GoogleFonts.inter(
          color: TekColors.textPrimary,
          fontSize: 18,
          fontWeight: FontWeight.w600,
          letterSpacing: -0.2,
        ).copyWith(fontFamilyFallback: TekTypography.malayalamFallback),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: TekColors.bgSecondary,
        isDense: false,
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
        border: inputBorder,
        enabledBorder: inputBorder,
        disabledBorder: inputBorder.copyWith(
          borderSide: const BorderSide(color: TekColors.borderSubtle),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: const BorderSide(color: TekColors.primaryLight, width: 1.6),
        ),
        errorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: const BorderSide(color: TekColors.error, width: 1.2),
        ),
        focusedErrorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: const BorderSide(color: TekColors.error, width: 1.6),
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
        prefixIconColor: TekColors.textSecondary,
        suffixIconColor: TekColors.textSecondary,
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: TekColors.primary,
          foregroundColor: Colors.white,
          disabledBackgroundColor: TekColors.elevatedSurface,
          disabledForegroundColor: TekColors.textMuted,
          elevation: 0,
          minimumSize: const Size(64, 44),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
          textStyle: const TextStyle(
            fontWeight: FontWeight.w600,
            fontSize: 14,
            fontFamilyFallback: TekTypography.malayalamFallback,
          ),
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: TekColors.primary,
          foregroundColor: Colors.white,
          minimumSize: const Size(64, 44),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
          textStyle: const TextStyle(
            fontWeight: FontWeight.w600,
            fontSize: 14,
            fontFamilyFallback: TekTypography.malayalamFallback,
          ),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: TekColors.textPrimary,
          side: const BorderSide(color: TekColors.border, width: 1),
          minimumSize: const Size(64, 44),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: TekColors.primaryLight,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        ),
      ),
      iconButtonTheme: IconButtonThemeData(
        style: IconButton.styleFrom(
          foregroundColor: TekColors.textSecondary,
          minimumSize: const Size(40, 40),
        ),
      ),
      floatingActionButtonTheme: FloatingActionButtonThemeData(
        backgroundColor: TekColors.primary,
        foregroundColor: Colors.white,
        elevation: 2,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      ),
      chipTheme: ChipThemeData(
        backgroundColor: TekColors.bgSecondary,
        selectedColor: const Color(0xFF262A5C),
        side: const BorderSide(color: TekColors.border),
        labelStyle: const TextStyle(
          color: TekColors.textPrimary,
          fontSize: 12.5,
          fontWeight: FontWeight.w500,
          fontFamilyFallback: TekTypography.malayalamFallback,
        ),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: TekColors.bgCard,
        surfaceTintColor: Colors.transparent,
        elevation: 8,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: const BorderSide(color: TekColors.border),
        ),
      ),
      bottomSheetTheme: const BottomSheetThemeData(
        backgroundColor: TekColors.bgCard,
        surfaceTintColor: Colors.transparent,
        showDragHandle: true,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
        ),
      ),
      popupMenuTheme: PopupMenuThemeData(
        color: TekColors.elevatedSurface,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(10),
          side: const BorderSide(color: TekColors.border),
        ),
      ),
      menuTheme: MenuThemeData(
        style: MenuStyle(
          backgroundColor: const WidgetStatePropertyAll(TekColors.elevatedSurface),
          surfaceTintColor: const WidgetStatePropertyAll(Colors.transparent),
          shape: WidgetStatePropertyAll(
            RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(10),
              side: const BorderSide(color: TekColors.border),
            ),
          ),
        ),
      ),
      tooltipTheme: TooltipThemeData(
        decoration: BoxDecoration(
          color: TekColors.elevatedSurface,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: TekColors.border),
        ),
        textStyle: const TextStyle(
          color: TekColors.textPrimary,
          fontSize: 12,
          fontFamilyFallback: TekTypography.malayalamFallback,
        ),
      ),
      listTileTheme: ListTileThemeData(
        iconColor: TekColors.textSecondary,
        textColor: TekColors.textPrimary,
        shape: shape,
      ),
      tabBarTheme: const TabBarThemeData(
        labelColor: TekColors.textPrimary,
        unselectedLabelColor: TekColors.textSecondary,
        indicatorColor: TekColors.primaryLight,
        dividerColor: TekColors.border,
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: TekColors.bgSecondary,
        surfaceTintColor: Colors.transparent,
        indicatorColor: const Color(0xFF262A5C),
        height: 66,
        labelTextStyle: const WidgetStatePropertyAll(
          TextStyle(
            fontSize: 11.5,
            fontWeight: FontWeight.w600,
            fontFamilyFallback: TekTypography.malayalamFallback,
          ),
        ),
      ),
      switchTheme: SwitchThemeData(
        thumbColor: WidgetStateProperty.resolveWith(
          (s) => s.contains(WidgetState.selected)
              ? Colors.white
              : TekColors.textSecondary,
        ),
        trackColor: WidgetStateProperty.resolveWith(
          (s) => s.contains(WidgetState.selected)
              ? TekColors.primary
              : TekColors.elevatedSurface,
        ),
      ),
      checkboxTheme: CheckboxThemeData(
        fillColor: WidgetStateProperty.resolveWith(
          (s) => s.contains(WidgetState.selected)
              ? TekColors.primary
              : Colors.transparent,
        ),
        side: const BorderSide(color: TekColors.textMuted, width: 1.4),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)),
      ),
      progressIndicatorTheme: const ProgressIndicatorThemeData(
        color: TekColors.primaryLight,
        linearTrackColor: TekColors.elevatedSurface,
      ),
      scrollbarTheme: ScrollbarThemeData(
        thumbColor: WidgetStatePropertyAll(
          TekColors.textMuted.withValues(alpha: 0.45),
        ),
        radius: const Radius.circular(8),
        thickness: const WidgetStatePropertyAll(6),
      ),
      snackBarTheme: SnackBarThemeData(
        backgroundColor: TekColors.elevatedSurface,
        contentTextStyle: const TextStyle(
          color: TekColors.textPrimary,
          fontFamilyFallback: TekTypography.malayalamFallback,
        ),
        actionTextColor: TekColors.primaryLight,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(10),
          side: const BorderSide(color: TekColors.border),
        ),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }
}
