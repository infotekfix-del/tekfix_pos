import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';
import 'package:hive_flutter/hive_flutter.dart';
import '../auth/auth_controller.dart';
import '../main.dart' show boxPurchaseBills, toast;
import '../ui/dashboard/dashboard_tokens.dart';
import 'purchase_models.dart';
import 'purchase_bill_service.dart';
import 'vendor_ledger_screen.dart';
import '../barcode/barcode_print_dialog.dart';
import 'manual_purchase_entry_screen.dart';

/// Detailed view of a single Purchase Bill.
/// Displays bill metadata, items table, warranty settings, payment status,
/// complete payment history trail, and bill attachment preview.
class PurchaseBillDetailsScreen extends StatefulWidget {
  final dynamic billKey;
  final PurchaseBill? bill;

  PurchaseBillDetailsScreen({
    super.key,
    dynamic billKey,
    this.bill,
  }) : billKey = billKey ?? bill?.key;

  @override
  State<PurchaseBillDetailsScreen> createState() => _PurchaseBillDetailsScreenState();
}

class _PurchaseBillDetailsScreenState extends State<PurchaseBillDetailsScreen> {
  final _dateFormat = DateFormat('dd MMM yyyy, hh:mm a');
  final _shortDateFormat = DateFormat('dd MMM yyyy');

  Future<void> _editBill(PurchaseBill bill) async {
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => ManualPurchaseEntryScreen(editBill: bill),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder(
      valueListenable: widget.billKey != null
          ? Hive.box(boxPurchaseBills).listenable(keys: [widget.billKey])
          : Hive.box(boxPurchaseBills).listenable(),
      builder: (context, Box box, _) {
        final bill = widget.billKey != null
            ? PurchaseBillService.instance.getPurchaseBill(widget.billKey)
            : widget.bill;
        if (bill == null) {
          return Scaffold(
            backgroundColor: DashboardColors.bgDarkNavyStart,
            appBar: AppBar(backgroundColor: const Color(0xFF0C1236)),
            body: const Center(
              child: Text('Purchase bill not found', style: TextStyle(color: Colors.white)),
            ),
          );
        }

        final auth = context.watch<AuthController>();
        final statusColor = BillPaymentStatus.getColor(bill.paymentStatus);
        final statusIcon = BillPaymentStatus.getIcon(bill.paymentStatus);

        return Scaffold(
          backgroundColor: DashboardColors.bgDarkNavyStart,
          appBar: _buildAppBar(bill),
          body: Container(
            decoration: const BoxDecoration(gradient: DashboardColors.backgroundGradient),
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // 1. Bill Overview & Status Header Card
                  _buildHeaderCard(bill, statusColor, statusIcon),

                  const SizedBox(height: 20),

                  // 2. Action Buttons Toolbar
                  _buildActionBar(bill, auth),

                  const SizedBox(height: 20),

                  // 3. Main Content: Items Table & Attachment Preview
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // Items Table & Financial Breakdown
                      Expanded(
                        flex: 3,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            _buildItemsTable(bill),
                            const SizedBox(height: 20),
                            _buildPaymentHistorySection(bill),
                          ],
                        ),
                      ),

                      const SizedBox(width: 20),

                      // Side Cards: Attachment Preview & Financial Summary
                      Expanded(
                        flex: 2,
                        child: Column(
                          children: [
                            _buildFinancialSummaryCard(bill),
                            const SizedBox(height: 16),
                            _buildAttachmentPreviewCard(bill),
                            const SizedBox(height: 16),
                            _buildAuditMetadataCard(bill),
                          ],
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  // ---------------------------------------------------------------------------
  // APP BAR
  // ---------------------------------------------------------------------------

  PreferredSizeWidget _buildAppBar(PurchaseBill bill) {
    return AppBar(
      backgroundColor: const Color(0xFF0C1236),
      elevation: 0,
      title: Row(
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            decoration: BoxDecoration(
              gradient: DashboardColors.activePillGradient,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Text(
              bill.billNumber,
              style: DashboardTypography.poppins(
                fontSize: 14,
                fontWeight: FontWeight.w800,
                color: Colors.white,
                letterSpacing: 0.5,
              ),
            ),
          ),
          const SizedBox(width: 12),
          Text(
            'Vendor: ${bill.vendorName}',
            style: DashboardTypography.poppins(fontSize: 15, fontWeight: FontWeight.w600),
          ),
        ],
      ),
      actions: [
        Container(
          margin: const EdgeInsets.only(right: 12),
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
          decoration: BoxDecoration(
            color: bill.entrySource == EntrySource.manual
                ? DashboardColors.neonGreen.withValues(alpha: 0.15)
                : DashboardColors.neonPurple.withValues(alpha: 0.15),
            borderRadius: BorderRadius.circular(6),
            border: Border.all(
              color: bill.entrySource == EntrySource.manual
                  ? DashboardColors.neonGreen.withValues(alpha: 0.4)
                  : DashboardColors.neonPurple.withValues(alpha: 0.4),
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                bill.entrySource == EntrySource.manual
                    ? Icons.edit_note_rounded
                    : Icons.document_scanner_rounded,
                size: 13,
                color: bill.entrySource == EntrySource.manual
                    ? DashboardColors.neonGreen
                    : DashboardColors.neonPurple,
              ),
              const SizedBox(width: 4),
              Text(
                bill.entrySource == EntrySource.manual
                    ? 'Manual Entry'
                    : 'Auto / Bill Upload',
                style: DashboardTypography.inter(
                  fontSize: 11,
                  fontWeight: FontWeight.bold,
                  color: bill.entrySource == EntrySource.manual
                      ? DashboardColors.neonGreen
                      : DashboardColors.neonPurple,
                ),
              ),
            ],
          ),
        ),
        if (bill.isDraft)
          Container(
            margin: const EdgeInsets.only(right: 16),
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            decoration: BoxDecoration(
              color: const Color(0x33F59E0B),
              borderRadius: BorderRadius.circular(6),
              border: Border.all(color: const Color(0x66F59E0B)),
            ),
            child: Text(
              'Draft Bill',
              style: DashboardTypography.inter(fontSize: 11, fontWeight: FontWeight.bold, color: DashboardColors.neonOrange),
            ),
          ),
        IconButton(
          icon: const Icon(Icons.edit_note_rounded, color: DashboardColors.neonOrange),
          tooltip: 'Edit Purchase Bill',
          onPressed: () => _editBill(bill),
        ),
        const SizedBox(width: 8),
      ],
    );
  }

  // ---------------------------------------------------------------------------
  // HEADER CARD
  // ---------------------------------------------------------------------------

  Widget _buildHeaderCard(PurchaseBill bill, Color statusColor, IconData statusIcon) {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: DashboardColors.glassCard(
        borderColor: statusColor.withValues(alpha: 0.4),
        glow: bill.balanceDue > 0,
        glowColor: statusColor,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Text(
                          bill.vendorName,
                          style: DashboardTypography.poppins(fontSize: 18, fontWeight: FontWeight.bold, color: Colors.white),
                        ),
                        const SizedBox(width: 10),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                          decoration: BoxDecoration(
                            color: const Color(0x2600D4FF),
                            borderRadius: BorderRadius.circular(6),
                            border: Border.all(color: const Color(0x4D00D4FF)),
                          ),
                          child: Text(
                            'Vendor Inv: ${bill.vendorInvoiceNumber}',
                            style: DashboardTypography.inter(fontSize: 11.5, fontWeight: FontWeight.bold, color: DashboardColors.neonBlue),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    Text(
                      'Phone: ${bill.vendorPhone}  •  Purchase Date: ${_dateFormat.format(bill.purchaseDate)}  •  Uploaded: ${_dateFormat.format(bill.uploadTimestamp)}',
                      style: DashboardTypography.inter(fontSize: 12.5, color: DashboardColors.textLight),
                    ),
                    if (bill.notes != null && bill.notes!.isNotEmpty) ...[
                      const SizedBox(height: 6),
                      Text(
                        'Notes: ${bill.notes}',
                        style: DashboardTypography.inter(fontSize: 12, color: DashboardColors.textMuted),
                      ),
                    ],
                  ],
                ),
              ),
              // Status Badge
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                decoration: BoxDecoration(
                  color: statusColor.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: statusColor.withValues(alpha: 0.6), width: 1.2),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(statusIcon, color: statusColor, size: 18),
                    const SizedBox(width: 8),
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          bill.paymentStatus,
                          style: DashboardTypography.poppins(
                            fontSize: 13,
                            fontWeight: FontWeight.bold,
                            color: statusColor,
                          ),
                        ),
                        Text(
                          bill.balanceDue > 0
                              ? 'Due: ₹${bill.balanceDue.toStringAsFixed(2)}'
                              : 'Settled in Full',
                          style: DashboardTypography.inter(fontSize: 10.5, color: Colors.white70),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // ACTION BAR
  // ---------------------------------------------------------------------------

  Widget _buildActionBar(PurchaseBill bill, AuthController auth) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      decoration: DashboardColors.glassCard(radius: 12),
      child: Row(
        children: [
          // 1. Add Payment
          if (bill.balanceDue > 0) ...[
            FilledButton.icon(
              style: FilledButton.styleFrom(
                backgroundColor: DashboardColors.primaryBlue,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              ),
              onPressed: () => _showAddPaymentDialog(bill, auth),
              icon: const Icon(Icons.payment_rounded, size: 16),
              label: Text('Record Payment', style: DashboardTypography.poppins(fontSize: 12, fontWeight: FontWeight.bold)),
            ),
            const SizedBox(width: 10),
          ],

          // 2. View Vendor Ledger
          OutlinedButton.icon(
            style: OutlinedButton.styleFrom(
              foregroundColor: DashboardColors.neonBlue,
              side: const BorderSide(color: DashboardColors.neonBlue),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            ),
            onPressed: () {
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => VendorLedgerScreen(
                    vendorKey: bill.vendorKey,
                    vendorName: bill.vendorName,
                  ),
                ),
              );
            },
            icon: const Icon(Icons.account_balance_wallet_rounded, size: 16),
            label: Text('View Vendor Ledger', style: DashboardTypography.inter(fontSize: 12, fontWeight: FontWeight.w600)),
          ),

          const SizedBox(width: 10),

          // 3. View Attachment
          if (bill.attachment != null) ...[
            OutlinedButton.icon(
              style: OutlinedButton.styleFrom(
                foregroundColor: DashboardColors.neonPurple,
                side: const BorderSide(color: DashboardColors.neonPurple),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              ),
              onPressed: () => _showAttachmentViewerDialog(bill),
              icon: const Icon(Icons.receipt_long_rounded, size: 16),
              label: Text('View Bill Attachment', style: DashboardTypography.inter(fontSize: 12, fontWeight: FontWeight.w600)),
            ),
            const SizedBox(width: 10),
          ],

          // 4. Print Barcode Labels (TVS LP 46 Lite - 38 x 25 mm)
          FilledButton.icon(
            style: FilledButton.styleFrom(
              backgroundColor: DashboardColors.neonGreen,
              foregroundColor: Colors.black,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            ),
            onPressed: () => BarcodePrintDialog.showForPurchaseBill(context, bill),
            icon: const Icon(Icons.qr_code_2_rounded, size: 16, color: Colors.black),
            label: Text(
              'Print Barcode Labels (38×25mm)',
              style: DashboardTypography.poppins(fontSize: 12, fontWeight: FontWeight.bold, color: Colors.black),
            ),
          ),

          const SizedBox(width: 10),

          // 5. Edit Bill
          OutlinedButton.icon(
            style: OutlinedButton.styleFrom(
              foregroundColor: DashboardColors.neonOrange,
              side: const BorderSide(color: DashboardColors.neonOrange),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            ),
            onPressed: () => _editBill(bill),
            icon: const Icon(Icons.edit_note_rounded, size: 16),
            label: Text('Edit Bill', style: DashboardTypography.poppins(fontSize: 12, fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // ITEMS TABLE
  // ---------------------------------------------------------------------------

  Widget _buildItemsTable(PurchaseBill bill) {
    return Container(
      decoration: DashboardColors.glassCard(radius: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 12),
            child: Row(
              children: [
                const Icon(Icons.inventory_2_rounded, color: DashboardColors.neonBlue, size: 18),
                const SizedBox(width: 8),
                Text(
                  'Purchased Items (${bill.items.length})',
                  style: DashboardTypography.poppins(fontSize: 14, fontWeight: FontWeight.bold, color: Colors.white),
                ),
              ],
            ),
          ),
          ClipRRect(
            borderRadius: const BorderRadius.vertical(bottom: Radius.circular(16)),
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: DataTable(
                horizontalMargin: 20,
                columnSpacing: 20,
                headingRowHeight: 44,
                dataRowMaxHeight: 60,
                headingRowColor: WidgetStateProperty.all(const Color(0xFF0C1236)),
                columns: [
                  DataColumn(label: Text('ITEM NAME', style: _colHeaderStyle)),
                  DataColumn(label: Text('SERIAL / IMEI', style: _colHeaderStyle)),
                  DataColumn(label: Text('QTY', style: _colHeaderStyle)),
                  DataColumn(label: Text('PURCHASE RATE', style: _colHeaderStyle)),
                  DataColumn(label: Text('DISCOUNT', style: _colHeaderStyle)),
                  DataColumn(label: Text('TAX', style: _colHeaderStyle)),
                  DataColumn(label: Text('LINE TOTAL', style: _colHeaderStyle)),
                  DataColumn(label: Text('WARRANTY TERM', style: _colHeaderStyle)),
                  DataColumn(label: Text('WARRANTY EXPIRY', style: _colHeaderStyle)),
                  DataColumn(label: Text('BARCODE', style: _colHeaderStyle)),
                ],
                rows: bill.items.map((it) {
                  return DataRow(
                    cells: [
                      // Item Name & Category
                      DataCell(
                        Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Text(it.name, style: DashboardTypography.inter(fontSize: 13, fontWeight: FontWeight.bold, color: Colors.white)),
                            if (it.brand.isNotEmpty || it.model.isNotEmpty)
                              Text('${it.brand} ${it.model}'.trim(), style: DashboardTypography.inter(fontSize: 11, color: DashboardColors.textMuted)),
                          ],
                        ),
                      ),

                      // Serial / IMEI
                      DataCell(
                        Text(
                          it.imeiOrSerial.isNotEmpty ? it.imeiOrSerial : '—',
                          style: DashboardTypography.inter(
                            fontSize: 12,
                            fontWeight: it.imeiOrSerial.isNotEmpty ? FontWeight.bold : FontWeight.normal,
                            color: it.imeiOrSerial.isNotEmpty ? DashboardColors.neonBlue : DashboardColors.textMuted,
                          ),
                        ),
                      ),

                      // Qty
                      DataCell(Text('${it.quantity}', style: DashboardTypography.inter(fontSize: 13, color: Colors.white))),

                      // Rate
                      DataCell(Text('₹${it.purchaseRate.toStringAsFixed(2)}', style: DashboardTypography.inter(fontSize: 12.5, color: Colors.white))),

                      // Discount
                      DataCell(Text(it.discount > 0 ? '₹${it.discount.toStringAsFixed(2)}' : '—', style: DashboardTypography.inter(fontSize: 12, color: DashboardColors.textMuted))),

                      // Tax
                      DataCell(Text(it.taxAmount > 0 ? '₹${it.taxAmount.toStringAsFixed(2)} (${it.taxPercent}%)' : '—', style: DashboardTypography.inter(fontSize: 12, color: DashboardColors.textMuted))),

                      // Line Total
                      DataCell(Text('₹${it.lineTotal.toStringAsFixed(2)}', style: DashboardTypography.poppins(fontSize: 13, fontWeight: FontWeight.bold, color: Colors.white))),

                      // Warranty Term
                      DataCell(
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                          decoration: BoxDecoration(
                            color: it.warrantyAvailable
                                ? const Color(0x2610B981)
                                : const Color(0x1AFFFFFF),
                            borderRadius: BorderRadius.circular(6),
                            border: Border.all(
                              color: it.warrantyAvailable ? const Color(0x6610B981) : const Color(0x26FFFFFF),
                            ),
                          ),
                          child: Text(
                            it.warrantyDuration,
                            style: DashboardTypography.inter(
                              fontSize: 11,
                              fontWeight: FontWeight.bold,
                              color: it.warrantyAvailable ? DashboardColors.neonGreen : DashboardColors.textMuted,
                            ),
                          ),
                        ),
                      ),

                      // Warranty Expiry
                      DataCell(
                        Text(
                          it.warrantyExpiryDate != null ? _shortDateFormat.format(it.warrantyExpiryDate!) : 'No Expiry',
                          style: DashboardTypography.inter(fontSize: 12, color: DashboardColors.textLight),
                        ),
                      ),

                      // Barcode Sticker Action
                      DataCell(
                        IconButton(
                          icon: const Icon(Icons.qr_code_2_rounded, color: DashboardColors.neonGreen, size: 20),
                          tooltip: 'Print ${it.quantity} Barcode Stickers (38×25mm)',
                          onPressed: () {
                            BarcodePrintDialog.showForSingleProduct(
                              context,
                              itemKey: it.itemKey,
                              name: it.name,
                              model: it.model,
                              brand: it.brand,
                              existingBarcode: it.sku.isNotEmpty ? it.sku : null,
                              initialQuantity: it.quantity,
                            );
                          },
                        ),
                      ),
                    ],
                  );
                }).toList(),
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // PAYMENT HISTORY TABLE
  // ---------------------------------------------------------------------------

  Widget _buildPaymentHistorySection(PurchaseBill bill) {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: DashboardColors.glassCard(radius: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Row(
                children: [
                  const Icon(Icons.history_edu_rounded, color: DashboardColors.neonPurple, size: 20),
                  const SizedBox(width: 8),
                  Text(
                    'Bill Payment History (${bill.payments.length})',
                    style: DashboardTypography.poppins(fontSize: 14, fontWeight: FontWeight.bold, color: Colors.white),
                  ),
                ],
              ),
              if (bill.balanceDue > 0)
                Text(
                  'Remaining Balance Due: ₹${bill.balanceDue.toStringAsFixed(2)}',
                  style: DashboardTypography.inter(fontSize: 12, fontWeight: FontWeight.bold, color: DashboardColors.alertOrange),
                ),
            ],
          ),
          const SizedBox(height: 14),
          if (bill.payments.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 24),
              child: Center(
                child: Text(
                  'No payments recorded yet against this purchase bill.',
                  style: DashboardTypography.inter(fontSize: 13, color: DashboardColors.textMuted),
                ),
              ),
            )
          else
            ListView.separated(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              itemCount: bill.payments.length,
              separatorBuilder: (_, __) => const Divider(height: 16, color: Color(0x14FFFFFF)),
              itemBuilder: (context, idx) {
                final p = bill.payments[idx];
                return Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(
                        color: const Color(0x1F10B981),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: const Icon(Icons.check_rounded, color: DashboardColors.neonGreen, size: 16),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Text(
                                p.paymentMethod,
                                style: DashboardTypography.poppins(fontSize: 13, fontWeight: FontWeight.bold, color: Colors.white),
                              ),
                              const SizedBox(width: 8),
                              Text(
                                '•  Ref: ${p.transactionReference}',
                                style: DashboardTypography.inter(fontSize: 11.5, color: DashboardColors.neonBlue),
                              ),
                            ],
                          ),
                          Text(
                            '${_dateFormat.format(p.paymentDate)}  •  Recorded by: ${p.recordedByName}',
                            style: DashboardTypography.inter(fontSize: 11, color: DashboardColors.textMuted),
                          ),
                          if (p.notes != null && p.notes!.isNotEmpty)
                            Text('Note: ${p.notes}', style: DashboardTypography.inter(fontSize: 11, color: DashboardColors.textLight)),
                        ],
                      ),
                    ),
                    Text(
                      '₹${p.amount.toStringAsFixed(2)}',
                      style: DashboardTypography.poppins(
                        fontSize: 15,
                        fontWeight: FontWeight.w800,
                        color: DashboardColors.neonGreen,
                      ),
                    ),
                  ],
                );
              },
            ),
        ],
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // FINANCIAL SUMMARY CARD
  // ---------------------------------------------------------------------------

  Widget _buildFinancialSummaryCard(PurchaseBill bill) {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: DashboardColors.glassCard(),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Purchase Bill Financials',
            style: DashboardTypography.poppins(fontSize: 14, fontWeight: FontWeight.bold, color: Colors.white),
          ),
          const SizedBox(height: 14),
          _buildSummaryLine('Subtotal', '₹${bill.subtotal.toStringAsFixed(2)}'),
          _buildSummaryLine('Total Quantity', '${bill.totalQuantity} items'),
          if (bill.totalDiscount > 0)
            _buildSummaryLine('Total Discount', '-₹${bill.totalDiscount.toStringAsFixed(2)}', color: DashboardColors.neonGreen),
          if (bill.totalTax > 0)
            _buildSummaryLine('Tax / GST', '+₹${bill.totalTax.toStringAsFixed(2)}'),
          if (bill.otherCharges > 0)
            _buildSummaryLine('Other Charges', '+₹${bill.otherCharges.toStringAsFixed(2)}'),
          const Divider(height: 18, color: Color(0x26FFFFFF)),
          _buildSummaryLine('Grand Total Purchase', '₹${bill.grandTotal.toStringAsFixed(2)}', highlight: true, fontSize: 16),
          _buildSummaryLine('Amount Paid', '₹${bill.paidAmount.toStringAsFixed(2)}', color: DashboardColors.neonGreen),
          _buildSummaryLine(
            'Remaining Balance Due',
            '₹${bill.balanceDue.toStringAsFixed(2)}',
            color: bill.balanceDue > 0 ? DashboardColors.alertOrange : DashboardColors.neonGreen,
            highlight: true,
          ),
        ],
      ),
    );
  }

  Widget _buildSummaryLine(
    String label,
    String value, {
    Color? color,
    bool highlight = false,
    double fontSize = 13,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(
            label,
            style: DashboardTypography.inter(
              fontSize: fontSize,
              fontWeight: highlight ? FontWeight.bold : FontWeight.normal,
              color: highlight ? Colors.white : DashboardColors.textLight,
            ),
          ),
          Text(
            value,
            style: DashboardTypography.poppins(
              fontSize: fontSize,
              fontWeight: highlight ? FontWeight.w800 : FontWeight.w600,
              color: color ?? Colors.white,
            ),
          ),
        ],
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // ATTACHMENT PREVIEW CARD
  // ---------------------------------------------------------------------------

  Widget _buildAttachmentPreviewCard(PurchaseBill bill) {
    final att = bill.attachment;

    return Container(
      padding: const EdgeInsets.all(20),
      decoration: DashboardColors.glassCard(),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                'Bill Document Attachment',
                style: DashboardTypography.poppins(fontSize: 14, fontWeight: FontWeight.bold, color: Colors.white),
              ),
              if (att != null)
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                  decoration: BoxDecoration(
                    color: const Color(0x3300D4FF),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Text(
                    att.fileType.toUpperCase(),
                    style: DashboardTypography.inter(fontSize: 10, fontWeight: FontWeight.bold, color: DashboardColors.neonBlue),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 14),
          if (att == null)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 20),
              child: Center(
                child: Column(
                  children: [
                    const Icon(Icons.attachment_rounded, size: 36, color: DashboardColors.textMuted),
                    const SizedBox(height: 8),
                    Text(
                      'No bill image or PDF attached to this record.',
                      style: DashboardTypography.inter(fontSize: 12, color: DashboardColors.textMuted),
                    ),
                  ],
                ),
              ),
            )
          else ...[
            InkWell(
              onTap: () => _showAttachmentViewerDialog(bill),
              borderRadius: BorderRadius.circular(12),
              child: Container(
                width: double.infinity,
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: const Color(0x1F1E293B),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: const Color(0x33FFFFFF)),
                ),
                child: Row(
                  children: [
                    Container(
                      width: 44,
                      height: 44,
                      decoration: BoxDecoration(
                        color: att.fileType == 'pdf'
                            ? const Color(0x33EF4444)
                            : const Color(0x3338BDF8),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Icon(
                        att.fileType == 'pdf' ? Icons.picture_as_pdf_rounded : Icons.image_rounded,
                        color: att.fileType == 'pdf' ? const Color(0xFFEF4444) : DashboardColors.neonBlue,
                        size: 24,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            att.fileName,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: DashboardTypography.inter(fontSize: 12.5, fontWeight: FontWeight.bold, color: Colors.white),
                          ),
                          Text(
                            'Uploaded ${_dateFormat.format(att.uploadedAt)}',
                            style: DashboardTypography.inter(fontSize: 11, color: DashboardColors.textMuted),
                          ),
                        ],
                      ),
                    ),
                    const Icon(Icons.visibility_rounded, color: DashboardColors.neonBlue, size: 20),
                  ],
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // AUDIT METADATA CARD
  // ---------------------------------------------------------------------------

  Widget _buildAuditMetadataCard(PurchaseBill bill) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: DashboardColors.glassCard(),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Audit Information', style: DashboardTypography.poppins(fontSize: 12.5, fontWeight: FontWeight.bold, color: DashboardColors.textLight)),
          const SizedBox(height: 8),
          _buildAuditRow('Created By', bill.createdByName),
          _buildAuditRow('Created At', _dateFormat.format(bill.createdAt)),
          if (bill.lastUpdatedByName != null)
            _buildAuditRow('Last Updated By', bill.lastUpdatedByName!),
          _buildAuditRow('Last Modified', _dateFormat.format(bill.updatedAt)),
        ],
      ),
    );
  }

  Widget _buildAuditRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2.5),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label, style: DashboardTypography.inter(fontSize: 11, color: DashboardColors.textMuted)),
          Text(value, style: DashboardTypography.inter(fontSize: 11.5, color: Colors.white70)),
        ],
      ),
    );
  }

  TextStyle get _colHeaderStyle => DashboardTypography.poppins(fontSize: 11, fontWeight: FontWeight.bold, color: DashboardColors.textLight);

  // ---------------------------------------------------------------------------
  // DIALOGS: ADD PAYMENT & ATTACHMENT VIEWER
  // ---------------------------------------------------------------------------

  void _showAddPaymentDialog(PurchaseBill bill, AuthController auth) {
    final amountCtrl = TextEditingController(text: bill.balanceDue.toStringAsFixed(0));
    final refCtrl = TextEditingController();
    final notesCtrl = TextEditingController();
    String method = 'UPI';
    DateTime payDate = DateTime.now();
    bool submitting = false;

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setD) => AlertDialog(
          backgroundColor: const Color(0xFF0F172A),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
          title: Row(
            children: [
              const Icon(Icons.payment_rounded, color: DashboardColors.neonGreen),
              const SizedBox(width: 10),
              Text(
                'Record Payment for ${bill.billNumber}',
                style: DashboardTypography.poppins(fontSize: 16, fontWeight: FontWeight.bold, color: Colors.white),
              ),
            ],
          ),
          content: SizedBox(
            width: 440,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Outstanding Bill Balance: ₹${bill.balanceDue.toStringAsFixed(2)}',
                  style: DashboardTypography.inter(fontSize: 13, fontWeight: FontWeight.bold, color: DashboardColors.alertOrange),
                ),
                const SizedBox(height: 14),
                TextField(
                  controller: amountCtrl,
                  keyboardType: TextInputType.number,
                  style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
                  decoration: const InputDecoration(
                    labelText: 'Amount (₹) *',
                    labelStyle: TextStyle(color: Colors.white70),
                    prefixText: '₹ ',
                    prefixStyle: TextStyle(color: DashboardColors.neonGreen, fontWeight: FontWeight.bold),
                    filled: true,
                    fillColor: Color(0x26000000),
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 12),
                Text('Payment Method *', style: DashboardTypography.inter(fontSize: 12, color: DashboardColors.textLight)),
                const SizedBox(height: 4),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  decoration: BoxDecoration(
                    color: const Color(0x26000000),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: const Color(0x33FFFFFF)),
                  ),
                  child: DropdownButtonHideUnderline(
                    child: DropdownButton<String>(
                      isExpanded: true,
                      dropdownColor: const Color(0xFF1E293B),
                      value: method,
                      items: ['Cash', 'UPI', 'Bank Transfer', 'Card', 'Cheque', 'Other'].map((m) {
                        return DropdownMenuItem(value: m, child: Text(m, style: const TextStyle(color: Colors.white)));
                      }).toList(),
                      onChanged: (val) => setD(() => method = val ?? 'UPI'),
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: refCtrl,
                  style: const TextStyle(color: Colors.white),
                  decoration: const InputDecoration(
                    labelText: 'Transaction Reference / UTR # *',
                    labelStyle: TextStyle(color: Colors.white70),
                    filled: true,
                    fillColor: Color(0x26000000),
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: notesCtrl,
                  style: const TextStyle(color: Colors.white),
                  decoration: const InputDecoration(
                    labelText: 'Notes',
                    labelStyle: TextStyle(color: Colors.white70),
                    filled: true,
                    fillColor: Color(0x26000000),
                    border: OutlineInputBorder(),
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: submitting ? null : () => Navigator.pop(ctx),
              child: Text('Cancel', style: DashboardTypography.inter(color: Colors.white70)),
            ),
            FilledButton(
              style: FilledButton.styleFrom(backgroundColor: DashboardColors.neonGreen),
              onPressed: submitting
                  ? null
                  : () async {
                      final amt = double.tryParse(amountCtrl.text.trim()) ?? 0.0;
                      if (amt <= 0) {
                        toast(context, 'Please enter a valid amount', error: true);
                        return;
                      }
                      if (refCtrl.text.trim().isEmpty) {
                        toast(context, 'Please enter transaction reference / UTR', error: true);
                        return;
                      }

                      setD(() => submitting = true);
                      try {
                        await PurchaseBillService.instance.recordBillPayment(
                          billKey: bill.key,
                          amount: amt,
                          paymentDate: payDate,
                          paymentMethod: method,
                          transactionReference: refCtrl.text.trim(),
                          notes: notesCtrl.text.trim().isNotEmpty ? notesCtrl.text.trim() : null,
                          staffId: auth.uid,
                          staffName: auth.name.isNotEmpty ? auth.name : 'Staff User',
                        );
                        if (ctx.mounted) {
                          Navigator.pop(ctx);
                          toast(context, 'Payment of ₹$amt saved successfully');
                        }
                      } catch (e) {
                        setD(() => submitting = false);
                        if (ctx.mounted) toast(context, 'Failed: $e', error: true);
                      }
                    },
              child: submitting
                  ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(color: Colors.black, strokeWidth: 2))
                  : Text('Confirm Payment', style: DashboardTypography.inter(fontWeight: FontWeight.bold, color: Colors.black)),
            ),
          ],
        ),
      ),
    );
  }

  void _showAttachmentViewerDialog(PurchaseBill bill) {
    final att = bill.attachment;
    if (att == null) return;

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF0F172A),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(att.fileName, style: DashboardTypography.poppins(fontSize: 15, fontWeight: FontWeight.bold, color: Colors.white)),
            IconButton(
              icon: const Icon(Icons.close_rounded, color: Colors.white70),
              onPressed: () => Navigator.pop(ctx),
            ),
          ],
        ),
        content: SizedBox(
          width: 600,
          height: 480,
          child: att.bytesBase64 != null
              ? Center(
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(12),
                    child: Image.memory(
                      base64Decode(att.bytesBase64!),
                      fit: BoxFit.contain,
                    ),
                  ),
                )
              : Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(
                        att.fileType == 'pdf' ? Icons.picture_as_pdf_rounded : Icons.image_rounded,
                        size: 64,
                        color: DashboardColors.neonBlue,
                      ),
                      const SizedBox(height: 12),
                      Text(att.fileName, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
                      const SizedBox(height: 4),
                      Text('Size: ${(att.fileSizeBytes / 1024).toStringAsFixed(1)} KB', style: const TextStyle(color: Colors.white60)),
                    ],
                  ),
                ),
        ),
      ),
    );
  }
}
