import 'package:flutter_test/flutter_test.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

void main() {
  test('Barcode Code 128 Generation and 38x25mm Label Dimensions Test', () async {
    const widthMm = 38.0;
    const heightMm = 25.0;

    final format = PdfPageFormat(
      widthMm * PdfPageFormat.mm,
      heightMm * PdfPageFormat.mm,
      marginAll: 1.0 * PdfPageFormat.mm,
    );

    expect(format.width, closeTo(38 * 2.834645669291339, 0.5));
    expect(format.height, closeTo(25 * 2.834645669291339, 0.5));

    final doc = pw.Document();

    final barcode = pw.Barcode.code128();

    doc.addPage(
      pw.Page(
        pageFormat: format,
        build: (pw.Context context) {
          return pw.Column(
            mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
            crossAxisAlignment: pw.CrossAxisAlignment.center,
            children: [
              // Header
              pw.Text(
                'TEKFIX DIGITAL',
                style: pw.TextStyle(
                  fontSize: 6.5,
                  fontWeight: pw.FontWeight.bold,
                ),
              ),
              // Product Name & Model
              pw.Text(
                'Fast Charger 65W GaN',
                maxLines: 1,
                overflow: pw.TextOverflow.clip,
                style: pw.TextStyle(fontSize: 5.5, fontWeight: pw.FontWeight.bold),
              ),
              pw.Text(
                'Model: FC-65W',
                maxLines: 1,
                style: const pw.TextStyle(fontSize: 4.5),
              ),
              // Barcode Graphic
              pw.Container(
                height: 22,
                width: 90,
                child: pw.BarcodeWidget(
                  barcode: barcode,
                  data: 'TF-894218',
                  drawText: false,
                ),
              ),
              // Barcode SKU Number
              pw.Text(
                'TF-894218',
                style: const pw.TextStyle(fontSize: 5, letterSpacing: 0.5),
              ),
              // Selling Price
              pw.Text(
                'MRP: Rs. 1,499.00',
                style: pw.TextStyle(fontSize: 6.0, fontWeight: pw.FontWeight.bold),
              ),
            ],
          );
        },
      ),
    );

    final bytes = await doc.save();
    expect(bytes.isNotEmpty, isTrue);
    expect(bytes.length, greaterThan(500));
  });
}
