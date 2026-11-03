/// Data models and printer configuration for Barcode Label Printing on TVS LP 46 Lite / LP 44 Lite.

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
    this.quantity = 1,
  }) : itemCode = itemCode ?? (itemId.isNotEmpty ? itemId : barcode);

  BarcodeLabelItem copyWith({
    dynamic itemKey,
    String? itemId,
    String? name,
    String? model,
    String? brand,
    String? barcode,
    String? itemCode,
    double? sellingPrice,
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
      quantity: quantity ?? this.quantity,
    );
  }
}

/// Target printer specification for TVS LP 46 Lite / LP 44 Lite (TSPL, 203 DPI, 50x25mm).
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

  const PrinterConfig({
    this.printerName = '',
    this.widthMm = 50.0,
    this.heightMm = 25.0,
    this.gapMm = 3.0,
    this.offsetMm = 0.0,
    this.dpi = 203,
    this.safetyMarginMm = 1.5,
    this.storeName = 'TEKFIX DIGITAL',
    this.useDirectRaw = true,
  });

  /// Horizontal dots at 203 DPI (8 dots/mm) -> 50 * 8 = 400 dots
  int get widthDots => (widthMm * 8).round();

  /// Vertical dots at 203 DPI (8 dots/mm) -> 25 * 8 = 200 dots
  int get heightDots => (heightMm * 8).round();

  /// Gap dots at 203 DPI -> 3 * 8 = 24 dots
  int get gapDots => (gapMm * 8).round();

  /// Margin dots -> 1.5 * 8 = 12 dots
  int get safetyMarginDots => (safetyMarginMm * 8).round();

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
    };
  }

  factory PrinterConfig.fromMap(Map<dynamic, dynamic>? map) {
    if (map == null) return const PrinterConfig();
    return PrinterConfig(
      printerName: (map['printerName'] ?? '').toString(),
      widthMm: (map['widthMm'] as num?)?.toDouble() ?? 50.0,
      heightMm: (map['heightMm'] as num?)?.toDouble() ?? 25.0,
      gapMm: (map['gapMm'] as num?)?.toDouble() ?? 3.0,
      offsetMm: (map['offsetMm'] as num?)?.toDouble() ?? 0.0,
      dpi: (map['dpi'] as num?)?.toInt() ?? 203,
      safetyMarginMm: (map['safetyMarginMm'] as num?)?.toDouble() ?? 1.5,
      storeName: (map['storeName'] ?? 'TEKFIX DIGITAL').toString(),
      useDirectRaw: map['useDirectRaw'] ?? true,
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

