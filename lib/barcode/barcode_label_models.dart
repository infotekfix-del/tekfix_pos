/// Data models and printer configuration for Barcode Label Printing on TVS LP 46 Lite / LP 44 Lite.
library barcode_label_models;

/// Configurable Label Profiles for TVS LP 46 Lite.
enum LabelProfile {
  profile38x25(
    name: '38mm × 25mm (Default)',
    shortName: '38×25 mm',
    widthMm: 38.0,
    heightMm: 25.0,
    gapMm: 3.0,
    safetyMarginMm: 1.5,
  ),
  profile50x25(
    name: '50mm × 25mm',
    shortName: '50×25 mm',
    widthMm: 50.0,
    heightMm: 25.0,
    gapMm: 3.0,
    safetyMarginMm: 1.5,
  );

  final String name;
  final String shortName;
  final double widthMm;
  final double heightMm;
  final double gapMm;
  final double safetyMarginMm;

  const LabelProfile({
    required this.name,
    required this.shortName,
    required this.widthMm,
    required this.heightMm,
    required this.gapMm,
    required this.safetyMarginMm,
  });

  double get printableWidthMm => widthMm - (2 * safetyMarginMm);
  double get printableHeightMm => heightMm - (2 * safetyMarginMm);
}

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
  /// 1. Selling Price
  /// 2. MRP (if Selling Price is unavailable/0)
  double? get effectivePrice {
    if (sellingPrice != null && sellingPrice! > 0) return sellingPrice;
    if (mrp != null && mrp! > 0) return mrp;
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

/// Target printer specification for TVS LP 46 Lite / LP 44 Lite (TSPL, 203 DPI).
/// Default Profile: 38mm × 25mm (35mm × 22mm printable area).
class PrinterConfig {
  final String printerName;
  final double widthMm;
  final double heightMm;
  final double gapMm;
  final double offsetMm;
  final int dpi;
  final double safetyMarginMm;
  final String storeName;
  final bool useDirectRaw;
  final int darkness; // TSPL DENSITY (1-15, default 10)
  final int speed; // TSPL SPEED (2-6, default 3)

  const PrinterConfig({
    this.printerName = '',
    this.widthMm = 38.0, // Default: PROFILE 1 (38mm x 25mm)
    this.heightMm = 25.0,
    this.gapMm = 3.0,
    this.offsetMm = 0.0,
    this.dpi = 203,
    this.safetyMarginMm = 1.5,
    this.storeName = 'TEKFIX DIGITAL',
    this.useDirectRaw = true,
    this.darkness = 10,
    this.speed = 3,
  });

  /// Current profile (38x25mm or 50x25mm)
  LabelProfile get profile =>
      widthMm <= 40.0 ? LabelProfile.profile38x25 : LabelProfile.profile50x25;

  /// Horizontal dots at 203 DPI (8 dots/mm) -> 38 * 8 = 304 dots (or 50 * 8 = 400 dots)
  int get widthDots => (widthMm * 8).round();

  /// Vertical dots at 203 DPI (8 dots/mm) -> 25 * 8 = 200 dots
  int get heightDots => (heightMm * 8).round();

  /// Gap dots at 203 DPI -> 3 * 8 = 24 dots
  int get gapDots => (gapMm * 8).round();

  /// Margin dots -> 1.5 * 8 = 12 dots
  int get safetyMarginDots => (safetyMarginMm * 8).round();

  /// Printable width in mm -> 38 - 3 = 35.0 mm (or 50 - 3 = 47.0 mm)
  double get printableWidthMm => widthMm - (2 * safetyMarginMm);

  /// Printable height in mm -> 25 - 3 = 22.0 mm
  double get printableHeightMm => heightMm - (2 * safetyMarginMm);

  /// Printable width in dots -> 35 * 8 = 280 dots (or 47 * 8 = 376 dots)
  int get printableWidthDots => (printableWidthMm * 8).round();

  /// Printable height in dots -> 22 * 8 = 176 dots
  int get printableHeightDots => (printableHeightMm * 8).round();

  PrinterConfig copyWith({
    String? printerName,
    double? widthMm,
    double? heightMm,
    double? gapMm,
    double? offsetMm,
    int? dpi,
    double? safetyMarginMm,
    String? storeName,
    bool? useDirectRaw,
    int? darkness,
    int? speed,
  }) {
    return PrinterConfig(
      printerName: printerName ?? this.printerName,
      widthMm: widthMm ?? this.widthMm,
      heightMm: heightMm ?? this.heightMm,
      gapMm: gapMm ?? this.gapMm,
      offsetMm: offsetMm ?? this.offsetMm,
      dpi: dpi ?? this.dpi,
      safetyMarginMm: safetyMarginMm ?? this.safetyMarginMm,
      storeName: storeName ?? this.storeName,
      useDirectRaw: useDirectRaw ?? this.useDirectRaw,
      darkness: darkness ?? this.darkness,
      speed: speed ?? this.speed,
    );
  }

  PrinterConfig withProfile(LabelProfile prof) {
    return copyWith(
      widthMm: prof.widthMm,
      heightMm: prof.heightMm,
      gapMm: prof.gapMm,
      safetyMarginMm: prof.safetyMarginMm,
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'printerName': printerName,
      'widthMm': widthMm,
      'heightMm': heightMm,
      'gapMm': gapMm,
      'offsetMm': offsetMm,
      'dpi': dpi,
      'safetyMarginMm': safetyMarginMm,
      'storeName': storeName,
      'useDirectRaw': useDirectRaw,
      'darkness': darkness,
      'speed': speed,
    };
  }

  factory PrinterConfig.fromMap(Map<dynamic, dynamic>? map) {
    if (map == null) return const PrinterConfig();
    return PrinterConfig(
      printerName: (map['printerName'] ?? '').toString(),
      widthMm: (map['widthMm'] as num?)?.toDouble() ?? 38.0,
      heightMm: (map['heightMm'] as num?)?.toDouble() ?? 25.0,
      gapMm: (map['gapMm'] as num?)?.toDouble() ?? 3.0,
      offsetMm: (map['offsetMm'] as num?)?.toDouble() ?? 0.0,
      dpi: (map['dpi'] as num?)?.toInt() ?? 203,
      safetyMarginMm: (map['safetyMarginMm'] as num?)?.toDouble() ?? 1.5,
      storeName: (map['storeName'] ?? 'TEKFIX DIGITAL').toString(),
      useDirectRaw: map['useDirectRaw'] ?? true,
      darkness: (map['darkness'] as num?)?.toInt() ?? 10,
      speed: (map['speed'] as num?)?.toInt() ?? 3,
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

