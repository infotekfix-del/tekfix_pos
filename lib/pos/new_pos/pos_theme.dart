// New POS design tokens (premium dark theme). Every colour, radius and
// text style the new POS uses comes from here: widgets never hard-code
// colours.
//
// Contrast on the card surface (#151B2C, WCAG): text 14:1, muted 8:1,
// subtle 4.9:1, primary-light 10:1, success 9:1, warning 10:1, error 6:1.

import 'package:flutter/material.dart';

class PosTokens {
  PosTokens._();

  // Brand: indigo -> violet, used for the main action and selection.
  static const primary = Color(0xFF6366F1); // indigo 500 (white text 4.5:1)
  static const primaryDark = Color(0xFFC7CBFF); // light indigo: text on soft
  static const primarySoft = Color(0xFF242A57); // indigo tint on dark
  static const secondary = Color(0xFF2DD4BF); // teal 400
  static const secondarySoft = Color(0xFF0E2E2C);
  static const accent = Color(0xFFA78BFA); // violet 400
  static const accentSoft = Color(0xFF2A2253);

  // Status (always paired with an icon or text, never colour alone)
  static const success = Color(0xFF34D399);
  static const successSoft = Color(0xFF0F2C24);
  static const warning = Color(0xFFFBBF24);
  static const warningSoft = Color(0xFF2E2511);
  static const error = Color(0xFFF87171);
  static const errorSoft = Color(0xFF341B21);

  /// Text/icon colour on a bright status fill (success, warning...).
  static const onBright = Color(0xFF0A0E19);

  // Neutrals: deep navy layers, lighter = closer to the user.
  static const bg = Color(0xFF0B0F1A);
  static const surface = Color(0xFF151B2C);
  static const surfaceAlt = Color(0xFF1C2338);
  static const border = Color(0xFF283149);
  static const borderStrong = Color(0xFF3A4562);
  static const text = Color(0xFFEDF0F7);
  static const muted = Color(0xFFAAB4CB);
  static const subtle = Color(0xFF8590AB);

  /// Main action gradient (Complete payment, selected chip).
  static const gradient = LinearGradient(
    colors: [Color(0xFF6366F1), Color(0xFF8B5CF6)],
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
  );

  // Payment method colours (subtle, distinct)
  static const cash = success;
  static const upi = accent;
  static const credit = warning;

  // Shape and spacing
  static const double radius = 12;
  static const double radiusSm = 8;
  static const double gap = 12;
  static const double focusWidth = 2;
  static BorderRadius get br => BorderRadius.circular(radius);
  static BorderRadius get brSm => BorderRadius.circular(radiusSm);

  // Motion: short only.
  static const Duration fast = Duration(milliseconds: 150);

  // Layout breakpoints (logical px)
  static const double wide = 1100; // two columns, wide cart panel
  static const double medium = 800; // two columns, narrow cart panel
  static const double cartPanelWide = 420;
  static const double cartPanelNarrow = 340;

  static List<BoxShadow> get shadow => const [
        BoxShadow(
            color: Color(0x59000000), blurRadius: 18, offset: Offset(0, 6)),
      ];

  /// Soft indigo glow under the main action.
  static List<BoxShadow> get glow => const [
        BoxShadow(
            color: Color(0x666366F1), blurRadius: 22, offset: Offset(0, 8)),
      ];

  /// Money: bold with tabular (fixed-width) digits so columns line up.
  static const List<FontFeature> tabular = [FontFeature.tabularFigures()];
  static const TextStyle money = TextStyle(
      fontWeight: FontWeight.w800, color: text, fontFeatures: tabular);
  static const TextStyle grandTotal = TextStyle(
      fontSize: 30,
      height: 1.1,
      fontWeight: FontWeight.w900,
      color: primaryDark,
      fontFeatures: tabular);
  static const TextStyle sectionTitle =
      TextStyle(fontSize: 14, fontWeight: FontWeight.w800, color: text);
  static const TextStyle label =
      TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600, color: muted);
}

/// Material 3 theme for the new POS subtree. Keeps the app's font family.
ThemeData posTheme(ThemeData outer) {
  final scheme = ColorScheme.fromSeed(
    seedColor: PosTokens.primary,
    brightness: Brightness.dark,
  ).copyWith(
    primary: PosTokens.primary,
    onPrimary: Colors.white,
    primaryContainer: PosTokens.primarySoft,
    onPrimaryContainer: PosTokens.primaryDark,
    secondary: PosTokens.secondary,
    onSecondary: PosTokens.onBright,
    secondaryContainer: PosTokens.primarySoft,
    onSecondaryContainer: PosTokens.primaryDark,
    tertiary: PosTokens.accent,
    tertiaryContainer: PosTokens.accentSoft,
    error: PosTokens.error,
    errorContainer: PosTokens.errorSoft,
    surface: PosTokens.surface,
    onSurface: PosTokens.text,
    onSurfaceVariant: PosTokens.muted,
    surfaceContainerLowest: PosTokens.bg,
    surfaceContainerLow: PosTokens.surface,
    surfaceContainer: PosTokens.surface,
    surfaceContainerHigh: PosTokens.surface,
    surfaceContainerHighest: PosTokens.surfaceAlt,
    surfaceTint: Colors.transparent,
    outline: PosTokens.borderStrong,
    outlineVariant: PosTokens.border,
  );
  final focusBorder = OutlineInputBorder(
    borderRadius: PosTokens.br,
    borderSide:
        const BorderSide(color: PosTokens.primary, width: PosTokens.focusWidth),
  );
  final shape = RoundedRectangleBorder(borderRadius: PosTokens.br);
  return ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    fontFamily: outer.textTheme.bodyMedium?.fontFamily,
    brightness: Brightness.dark,
    scaffoldBackgroundColor: PosTokens.bg,
    canvasColor: PosTokens.surface,
    appBarTheme: const AppBarTheme(
      backgroundColor: PosTokens.bg,
      foregroundColor: PosTokens.text,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      scrolledUnderElevation: 0,
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: PosTokens.surface,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(18),
          side: const BorderSide(color: PosTokens.border)),
    ),
    bottomSheetTheme: const BottomSheetThemeData(
        backgroundColor: PosTokens.surface,
        surfaceTintColor: Colors.transparent),
    popupMenuTheme: const PopupMenuThemeData(
        color: PosTokens.surfaceAlt, surfaceTintColor: Colors.transparent),
    snackBarTheme: const SnackBarThemeData(
        backgroundColor: PosTokens.surfaceAlt,
        contentTextStyle: TextStyle(color: PosTokens.text)),
    tooltipTheme: TooltipThemeData(
      waitDuration: const Duration(milliseconds: 400),
      decoration: BoxDecoration(
          color: PosTokens.surfaceAlt,
          borderRadius: PosTokens.brSm,
          border: Border.all(color: PosTokens.borderStrong)),
      textStyle: const TextStyle(color: PosTokens.text, fontSize: 12),
    ),
    visualDensity: VisualDensity.standard,
    focusColor: PosTokens.primary.withValues(alpha: 0.12),
    hoverColor: PosTokens.primary.withValues(alpha: 0.06),
    dividerTheme:
        const DividerThemeData(color: PosTokens.border, space: 1, thickness: 1),
    cardTheme: CardThemeData(
      color: PosTokens.surface,
      elevation: 0,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(
          borderRadius: PosTokens.br,
          side: const BorderSide(color: PosTokens.border)),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: PosTokens.surfaceAlt,
      isDense: true,
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      labelStyle: const TextStyle(color: PosTokens.muted),
      hintStyle: const TextStyle(color: PosTokens.subtle),
      border: OutlineInputBorder(
          borderRadius: PosTokens.br,
          borderSide: const BorderSide(color: PosTokens.border)),
      enabledBorder: OutlineInputBorder(
          borderRadius: PosTokens.br,
          borderSide: const BorderSide(color: PosTokens.border)),
      focusedBorder: focusBorder,
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        minimumSize: const Size(48, 46),
        shape: shape,
        textStyle: const TextStyle(fontWeight: FontWeight.w800),
      ).copyWith(
        side: WidgetStateProperty.resolveWith((s) =>
            s.contains(WidgetState.focused)
                ? const BorderSide(color: PosTokens.primaryDark, width: 2)
                : null),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        minimumSize: const Size(48, 42),
        shape: shape,
        foregroundColor: PosTokens.text,
        side: const BorderSide(color: PosTokens.border),
      ).copyWith(
        side: WidgetStateProperty.resolveWith((s) =>
            s.contains(WidgetState.focused)
                ? const BorderSide(
                    color: PosTokens.primary, width: PosTokens.focusWidth)
                : const BorderSide(color: PosTokens.border)),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(shape: shape),
    ),
    chipTheme: ChipThemeData(
      shape: RoundedRectangleBorder(borderRadius: PosTokens.brSm),
      side: const BorderSide(color: PosTokens.border),
      backgroundColor: PosTokens.surface,
      selectedColor: PosTokens.primarySoft,
      labelStyle:
          const TextStyle(color: PosTokens.text, fontWeight: FontWeight.w600),
    ),
  );
}

// --------------------------------------------------------- bilingual text
final RegExp _kBi = RegExp(r'^(.*?)\s*\(([^()]*[ഀ-ൿ][^()]*)\)\s*(.*)$');

/// "Customer View (കസ്റ്റമർ വ്യൂ)  F11" -> (en: "Customer View F11",
/// ml: "കസ്റ്റമർ വ്യൂ"). Text without Malayalam in brackets -> ml ''.
({String en, String ml}) posSplitBi(String s) {
  final m = _kBi.firstMatch(s);
  if (m == null) return (en: s.trim(), ml: '');
  final rest = m[3]!.trim();
  return (
    en: [m[1]!.trim(), if (rest.isNotEmpty) rest].join(' '),
    ml: m[2]!.trim(),
  );
}

/// English on top, Malayalam below in a smaller, muted font, so tight
/// places (chips, buttons, headers) never cram both on one line.
class PosBiText extends StatelessWidget {
  final String en;
  final String ml;
  final TextStyle? style;
  final Color? mlColor;
  final CrossAxisAlignment cross;
  final TextAlign align;
  final int maxLines;

  const PosBiText(
    this.en,
    this.ml, {
    super.key,
    this.style,
    this.mlColor,
    this.cross = CrossAxisAlignment.start,
    this.align = TextAlign.start,
    this.maxLines = 1,
  });

  factory PosBiText.split(
    String s, {
    Key? key,
    TextStyle? style,
    Color? mlColor,
    CrossAxisAlignment cross = CrossAxisAlignment.start,
    TextAlign align = TextAlign.start,
    int maxLines = 1,
  }) {
    final b = posSplitBi(s);
    return PosBiText(b.en, b.ml,
        key: key,
        style: style,
        mlColor: mlColor,
        cross: cross,
        align: align,
        maxLines: maxLines);
  }

  @override
  Widget build(BuildContext context) {
    final base = DefaultTextStyle.of(context).style.merge(style);
    final size = base.fontSize ?? 14;
    return Semantics(
      label: ml.isEmpty ? en : '$en ($ml)',
      excludeSemantics: true,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: cross,
        children: [
          Text(en,
              maxLines: maxLines,
              overflow: TextOverflow.ellipsis,
              textAlign: align,
              style: base),
          if (ml.isNotEmpty)
            Text(ml,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: align,
                style: base.copyWith(
                    fontSize: size * 0.8,
                    height: 1.2,
                    fontWeight: FontWeight.w500,
                    color: mlColor ??
                        (base.color ?? PosTokens.text)
                            .withValues(alpha: 0.72))),
        ],
      ),
    );
  }
}

/// Small section label used to group the bill panel ("CUSTOMER · കസ്റ്റമർ").
class PosSectionLabel extends StatelessWidget {
  final String en;
  final String ml;
  final IconData icon;
  final Widget? trailing;
  const PosSectionLabel(this.en, this.ml, this.icon,
      {super.key, this.trailing});

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Row(children: [
          Icon(icon, size: 16, color: PosTokens.subtle),
          const SizedBox(width: 6),
          Text(en.toUpperCase(),
              style: const TextStyle(
                  fontSize: 11.5,
                  letterSpacing: 0.6,
                  fontWeight: FontWeight.w800,
                  color: PosTokens.muted)),
          const SizedBox(width: 6),
          Flexible(
            child: Text(ml,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 11, color: PosTokens.subtle)),
          ),
          if (trailing != null) ...[const Spacer(), trailing!],
        ]),
      );
}
