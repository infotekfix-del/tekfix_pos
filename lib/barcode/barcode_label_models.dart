/// Data models and printer configuration for Barcode Label Printing on TVS LP 46 Lite / LP 44 Lite.
library barcode_label_models;

/// Configurable Label Size Presets for TVS LP 46 Lite.
/// Single-up roll format (1-up only).
enum LabelPreset {
  preset38x25(
    name: '38mm × 25mm (Default)',
    shortName: '38×25 mm',
    widthMm: 38.0,
    heightMm: 25.0,
  ),
  preset50x25(
    name: '50mm × 25mm',
    shortName: '50×25 mm',
    widthMm: 50.0,
    heightMm: 25.0,
  ),
  custom(
    name: 'Custom Size',
    shortName: 'Custom',
    widthMm: 38.0,
    heightMm: 25.0,
  );

  final String name;
  final String shortName;
  final double widthMm;
  final double heightMm;

  const LabelPreset({
    required this.name,
    required this.shortName,
    required this.widthMm,
    required this.heightMm,
  });
}

/// Backwards compatibility alias for LabelPreset.
typedef LabelProfile = LabelPreset;

/// Represents an item to be printed on a barcode label.
class BarcodeLabelItem {
  final dynamic itemKey;
  final String itemId;
  final String name;
  final String model;
  final String brand;
  String barcode;
  final String itemCode;
  double? sellingPrice;
  double? mrp;
  int quantity;

  BarcodeLabelItem({
    this.itemKey,
    this.itemId = '',
    required this.name,
    this.model = '',
    this.brand = '',
    required this.barcode,
    String? itemCode,
    this.sellingPrice,
    this.mrp,
    this.quantity = 1,
  }) : itemCode = itemCode ?? (itemId.isNotEmpty ? itemId : barcode);

  /// Priority for pricing:
  /// Label MRP = the item's stored `mrp` if present and >= `sellingPrice`,
  /// otherwise `sellingPrice`.
  /// Protects against bogus reverse markups (e.g. 493.75 vs 680.00).
  /// No GST adjustment, no recalculation, no rounding changes.
  double? get effectivePrice {
    if (mrp != null && mrp! > 0) {
      if (sellingPrice != null && sellingPrice! > 0 && mrp! < sellingPrice!) {
        return sellingPrice;
      }
      return mrp;
    }
    if (sellingPrice != null && sellingPrice! > 0) return sellingPrice;
    return null;
  }

  /// Whether a valid non-zero price is available.
  bool get hasValidPrice => effectivePrice != null && effectivePrice! > 0;

  BarcodeLabelItem copyWith({
    dynamic itemKey,
    String? itemId,
    String? name,
    String? model,
    String? brand,
    String? barcode,
    String? itemCode,
    double? sellingPrice,
    double? mrp,
    int? quantity,
  }) {
    return BarcodeLabelItem(
      itemKey: itemKey ?? this.itemKey,
      itemId: itemId ?? this.itemId,
      name: name ?? this.name,
      model: model ?? this.model,
      brand: brand ?? this.brand,
      barcode: barcode ?? this.barcode,
      itemCode: itemCode ?? this.itemCode,
      sellingPrice: sellingPrice ?? this.sellingPrice,
      mrp: mrp ?? this.mrp,
      quantity: quantity ?? this.quantity,
    );
  }
}

/// Target printer specification for TVS LP 46 Lite (TSPL, 203 DPI).
/// Default: 38mm × 25mm, 3mm gap, 1-up single sticker, 16-dot safe margins.
class PrinterConfig {
  final String printerName;
  final double widthMm;
  final double heightMm;
  final double gapMm;
  final double xOffsetMm; // X offset in mm
  final double yOffsetMm; // Y offset in mm
  final int dpi;
  final int safeMarginDots; // Safe margin in dots (default 16 dots)
  final String storeName;
  final bool useDirectRaw;
  final int darkness; // TSPL DENSITY (1-15, default 8 per spec)
  final int speed; // TSPL SPEED (2-6, default 3)
  final LabelPreset preset;

  const PrinterConfig({
    this.printerName = '',
    this.widthMm = 38.0, // Default: 38mm x 25mm
    this.heightMm = 25.0,
    this.gapMm = 3.0,
    this.xOffsetMm = 0.0,
    this.yOffsetMm = 0.0,
    this.dpi = 203,
    this.safeMarginDots = 16, // 16-dot safe margins per spec
    this.storeName = 'TEKFIX DIGITAL',
    this.useDirectRaw = true,
    this.darkness = 8, // DENSITY 8
    this.speed = 3, // SPEED 3
    this.preset = LabelPreset.preset38x25,
  });

  /// Horizontal dots at 203 DPI (8 dots/mm) -> 38 * 8 = 304 dots
  int get widthDots => (widthMm * 8).round();

  /// Vertical dots at 203 DPI (8 dots/mm) -> 25 * 8 = 200 dots
  int get heightDots => (heightMm * 8).round();

  /// Safe margin in mm (16 dots = 2.0 mm)
  double get safetyMarginMm => safeMarginDots / 8.0;

  /// REFERENCE X in dots
  int get referenceXDots => (xOffsetMm * 8).round();

  /// REFERENCE Y in dots
  int get referenceYDots => (yOffsetMm * 8).round();

  /// Printable width in dots (subtract 16 dots from left and right)
  int get printableWidthDots => widthDots - (2 * safeMarginDots);

  /// Printable height in dots (subtract 16 dots from top and bottom)
  int get printableHeightDots => heightDots - (2 * safeMarginDots);

  /// Printable width in mm
  double get printableWidthMm => widthMm - ((2 * safeMarginDots) / 8);

  /// Printable height in mm
  double get printableHeightMm => heightMm - ((2 * safeMarginDots) / 8);

  /// Compatibility getter for profile
  LabelPreset get profile => preset;

  PrinterConfig copyWith({
    String? printerName,
    double? widthMm,
    double? heightMm,
    double? gapMm,
    double? xOffsetMm,
    double? yOffsetMm,
    int? dpi,
    int? safeMarginDots,
    String? storeName,
    bool? useDirectRaw,
    int? darkness,
    int? speed,
    LabelPreset? preset,
  }) {
    return PrinterConfig(
      printerName: printerName ?? this.printerName,
      widthMm: widthMm ?? this.widthMm,
      heightMm: heightMm ?? this.heightMm,
      gapMm: gapMm ?? this.gapMm,
      xOffsetMm: xOffsetMm ?? this.xOffsetMm,
      yOffsetMm: yOffsetMm ?? this.yOffsetMm,
      dpi: dpi ?? this.dpi,
      safeMarginDots: safeMarginDots ?? this.safeMarginDots,
      storeName: storeName ?? this.storeName,
      useDirectRaw: useDirectRaw ?? this.useDirectRaw,
      darkness: darkness ?? this.darkness,
      speed: speed ?? this.speed,
      preset: preset ?? this.preset,
    );
  }

  PrinterConfig withPreset(LabelPreset newPreset,
      {double? customWidth, double? customHeight}) {
    if (newPreset == LabelPreset.custom) {
      return copyWith(
        preset: LabelPreset.custom,
        widthMm: customWidth ?? widthMm,
        heightMm: customHeight ?? heightMm,
      );
    }
    return copyWith(
      preset: newPreset,
      widthMm: newPreset.widthMm,
      heightMm: newPreset.heightMm,
    );
  }

  PrinterConfig withProfile(LabelPreset prof) => withPreset(prof);

  Map<String, dynamic> toMap() {
    return {
      'printerName': printerName,
      'widthMm': widthMm,
      'heightMm': heightMm,
      'gapMm': gapMm,
      'xOffsetMm': xOffsetMm,
      'yOffsetMm': yOffsetMm,
      'dpi': dpi,
      'safeMarginDots': safeMarginDots,
      'storeName': storeName,
      'useDirectRaw': useDirectRaw,
      'darkness': darkness,
      'speed': speed,
      'preset': preset.name,
    };
  }

  factory PrinterConfig.fromMap(Map<dynamic, dynamic>? map) {
    if (map == null) return const PrinterConfig();
    LabelPreset preset = LabelPreset.preset38x25;
    final presetStr = map['preset']?.toString();
    if (presetStr == LabelPreset.preset50x25.name ||
        presetStr == 'profile50x25') {
      preset = LabelPreset.preset50x25;
    } else if (presetStr == LabelPreset.custom.name) {
      preset = LabelPreset.custom;
    }

    return PrinterConfig(
      printerName: (map['printerName'] ?? '').toString(),
      widthMm: (map['widthMm'] as num?)?.toDouble() ?? 38.0,
      heightMm: (map['heightMm'] as num?)?.toDouble() ?? 25.0,
      gapMm: (map['gapMm'] as num?)?.toDouble() ?? 3.0,
      xOffsetMm: (map['xOffsetMm'] as num?)?.toDouble() ?? 0.0,
      yOffsetMm: (map['yOffsetMm'] as num?)?.toDouble() ?? 0.0,
      dpi: (map['dpi'] as num?)?.toInt() ?? 203,
      safeMarginDots: (map['safeMarginDots'] as num?)?.toInt() ?? 16,
      storeName: (map['storeName'] ?? 'TEKFIX DIGITAL').toString(),
      useDirectRaw: map['useDirectRaw'] ?? true,
      darkness: (map['darkness'] as num?)?.toInt() ?? 8,
      speed: (map['speed'] as num?)?.toInt() ?? 3,
      preset: preset,
    );
  }
}

/// Printer connection and activity status.
enum PrinterConnectionStatus {
  disconnected,
  connecting,
  connected,
  printing,
  error,
}

/// Discovered printer device descriptor.
class PrinterDevice {
  final String name;
  final String driver;
  final String port;
  final bool isDefault;

  const PrinterDevice({
    required this.name,
    this.driver = '',
    this.port = '',
    this.isDefault = false,
  });

  /// Identifies if the printer is TVS LP 46 Lite, LP 44 Lite, or compatible TSC/TT065 printer.
  bool get isTargetTvs {
    final lower = name.toLowerCase();
    final driverLower = driver.toLowerCase();
    return lower.contains('tvs') ||
        lower.contains('lp 46') ||
        lower.contains('lp46') ||
        lower.contains('lp 44') ||
        lower.contains('lp44') ||
        lower.contains('tt065') ||
        lower.contains('tsc') ||
        lower.contains('bar code') ||
        driverLower.contains('tvs') ||
        driverLower.contains('tt065') ||
        driverLower.contains('tsc');
  }

  @override
  String toString() => '$name ($port)';
}

/// Outcome of a print job.
class PrintJobResult {
  final bool success;
  final String message;
  final int labelsPrinted;
  final String? error;

  const PrintJobResult({
    required this.success,
    required this.message,
    this.labelsPrinted = 0,
    this.error,
  });
}
