import 'dart:async';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import '../main.dart' show Db, ModeSelector, printInvoice, toast;
import '../pos/pos_models.dart';
import '../pos/pos_service.dart';
import '../staff/activity_log.dart';
import '../theme/tek_tokens.dart';
import '../ui/dashboard/dashboard_tokens.dart';
import '../ui/tek_feedback.dart';
import '../utils/tek_helpers.dart';
import 'repair_models.dart';

/// Source of the spare part.
enum SparePartSource {
  inventory,
  external,
}

/// Represents an itemized spare part (inventory-linked or custom external) on a service bill.
class ServiceSparePartItem {
  final String? itemId; // Document ID in shops/{shopId}/inventory or items
  final dynamic localItemKey; // Local Hive key if available
  final String name;
  final String model;
  final String category;
  final String barcode;
  int quantity;
  double unitPrice; // In Rupees
  double costPrice; // In Rupees
  final int availableStock; // Live stock from inventory (0 for external)
  final SparePartSource source; // inventory or external

  ServiceSparePartItem({
    this.itemId,
    this.localItemKey,
    required this.name,
    this.model = '',
    this.category = '',
    this.barcode = '',
    this.quantity = 1,
    required this.unitPrice,
    this.costPrice = 0.0,
    this.availableStock = 0,
    required this.source,
  });

  bool get isExternal => source == SparePartSource.external;
  bool get isInventory => source == SparePartSource.inventory;

  double get lineTotal => unitPrice * quantity;
  int get unitPricePaise => (unitPrice * 100).round();
  int get totalPricePaise => (lineTotal * 100).round();
  int get costPricePaise => (costPrice * 100).round();

  Map<String, dynamic> toJobSpareMap() => {
        'itemId': isInventory ? itemId : null,
        'itemName': name,
        'model': model,
        'category': category,
        'quantity': quantity,
        'unitPricePaise': unitPricePaise,
        'totalPricePaise': totalPricePaise,
        'source': isInventory ? 'INVENTORY' : 'EXTERNAL',
      };

  Map<String, dynamic> toInvoiceLineMap() => {
        'itemId': isInventory ? itemId : null,
        'name': isInventory ? '$name [INVENTORY]' : '$name [EXTERNAL SPARE]',
        'qty': quantity,
        'price': unitPrice,
        'costPrice': costPrice,
        'lineTotal': lineTotal,
        'isExternal': isExternal,
        'source': isInventory ? 'INVENTORY' : 'EXTERNAL',
      };
}

/// Inventory-Linked Service Checkout / Billing Modal for TekFix ERP.
/// Integrates live inventory searching, selected spare parts table, custom external spares,
/// paise-based calculations, atomic Firestore transaction deduction, and daily sales ledger updates.
class ServiceBillDialog extends StatefulWidget {
  final dynamic jobKey;
  final Map<String, dynamic> jobData;
  final RepairJob? repairJob;
  final String? shopId;
  final String? staffId;
  final String? staffName;

  const ServiceBillDialog({
    super.key,
    this.jobKey,
    required this.jobData,
    this.repairJob,
    this.shopId,
    this.staffId,
    this.staffName,
  });

  /// Factory helper for Map-based service jobs (from main.dart / desktop view).
  static Future<bool> show(
    BuildContext context, {
    required dynamic jobKey,
    required Map<String, dynamic> job,
    String? shopId,
    String? staffId,
    String? staffName,
  }) async {
    if (job['billCreated'] == true) {
      TekFeedback.error('ഈ Job-ന് ബിൽ ഇതിനകം സൃഷ്ടിച്ചിട്ടുണ്ട് (Bill already created)');
      return false;
    }

    final result = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (_) => ServiceBillDialog(
        jobKey: jobKey,
        jobData: job,
        shopId: shopId,
        staffId: staffId,
        staffName: staffName,
      ),
    );
    return result ?? false;
  }

  /// Factory helper for RepairJob objects (from staff_repairs_screen.dart).
  static Future<bool> showForRepairJob(
    BuildContext context, {
    required RepairJob job,
    String? shopId,
    String? staffId,
    String? staffName,
  }) async {
    if (job.billCreated || (job.invoice != null && job.invoice!.isNotEmpty)) {
      TekFeedback.error('ഈ Job-ന് ബിൽ ഇതിനകം സൃഷ്ടിച്ചിട്ടുണ്ട് (Bill already created)');
      return false;
    }

    final jobMap = <String, dynamic>{
      'jobId': job.id,
      'customerName': job.customerName,
      'phone': job.phone,
      'brandModel': job.brandModel,
      'serial': job.serial,
      'productType': job.productType,
      'complaint': job.complaint,
      'estimatedCost': job.estimatedCost,
      'advance': job.advance,
      'warrantyDays': job.warrantyDays,
      'billCreated': job.billCreated,
      'invoice': job.invoice,
    };

    final result = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (_) => ServiceBillDialog(
        jobKey: job.key,
        jobData: jobMap,
        repairJob: job,
        shopId: shopId,
        staffId: staffId,
        staffName: staffName,
      ),
    );
    return result ?? false;
  }

  @override
  State<ServiceBillDialog> createState() => _ServiceBillDialogState();
}

class _ServiceBillDialogState extends State<ServiceBillDialog> {
  static final Set<String> _inFlightInvoices = {};

  late final TextEditingController _serviceChargeCtrl;
  late final TextEditingController _labourCtrl;
  late final TextEditingController _discountCtrl;
  final TextEditingController _searchCtrl = TextEditingController();
  final FocusNode _searchFocus = FocusNode();

  final List<ServiceSparePartItem> _selectedParts = [];
  List<ServiceSparePartItem> _searchResults = [];
  bool _isSearching = false;
  String _paymentMode = 'Cash';
  bool _isSubmitting = false;
  String? _errorMessage;

  String get _shopId {
    if (widget.shopId != null && widget.shopId!.isNotEmpty) return widget.shopId!;
    return Db.setting('shop_id', 'tekfix');
  }

  String get _staffId {
    if (widget.staffId != null && widget.staffId!.isNotEmpty) return widget.staffId!;
    return Db.setting('active_user_id', Db.setting('active_user', 'Staff'));
  }

  String get _staffName {
    if (widget.staffName != null && widget.staffName!.isNotEmpty) return widget.staffName!;
    return Db.setting('active_user', 'Staff');
  }

  String get _jobId => '${widget.jobData['jobId'] ?? widget.repairJob?.id ?? ''}';
  String get _customerName => '${widget.jobData['customerName'] ?? widget.repairJob?.customerName ?? 'Customer'}';
  String get _customerPhone => '${widget.jobData['phone'] ?? widget.repairJob?.phone ?? ''}';
  String get _brandModel => '${widget.jobData['brandModel'] ?? widget.repairJob?.brandModel ?? 'Device'}';
  int get _warrantyDays => (widget.jobData['warrantyDays'] as num?)?.toInt() ?? widget.repairJob?.warrantyDays ?? 30;

  @override
  void initState() {
    super.initState();
    final estCost = (widget.jobData['estimatedCost'] as num?)?.toDouble() ??
        widget.repairJob?.estimatedCost ??
        0.0;
    _serviceChargeCtrl = TextEditingController(
      text: estCost > 0 ? estCost.toStringAsFixed(0) : '0',
    );
    _labourCtrl = TextEditingController(text: '0');
    _discountCtrl = TextEditingController(text: '0');

    _searchCtrl.addListener(_onSearchChanged);
  }

  @override
  void dispose() {
    _serviceChargeCtrl.dispose();
    _labourCtrl.dispose();
    _discountCtrl.dispose();
    _searchCtrl.removeListener(_onSearchChanged);
    _searchCtrl.dispose();
    _searchFocus.dispose();
    super.dispose();
  }

  // ---------------------------------------------------------------------------
  // 1. LIVE SEARCH: shops/{shopId}/inventory & POS Catalog & Local Cache
  // ---------------------------------------------------------------------------
  void _onSearchChanged() {
    final query = _searchCtrl.text.trim().toLowerCase();
    if (query.isEmpty) {
      if (_searchResults.isNotEmpty) {
        setState(() {
          _searchResults = [];
          _isSearching = false;
        });
      }
      return;
    }

    final results = <ServiceSparePartItem>[];
    final seenIds = <String>{};

    // 1. Search in local Hive / POS Catalog cache (Instant response)
    final catalog = PosService.instance.getCatalogItems();
    for (final it in catalog) {
      final name = it.name.toLowerCase();
      final sku = it.sku.toLowerCase();
      final barcode = it.barcode.toLowerCase();
      final cat = it.category.toLowerCase();

      if (name.contains(query) || sku.contains(query) || barcode.contains(query) || cat.contains(query)) {
        if (!seenIds.contains(it.id)) {
          seenIds.add(it.id);
          results.add(ServiceSparePartItem(
            itemId: it.id,
            name: it.name,
            category: it.category,
            barcode: it.barcode,
            unitPrice: it.sellingPrice,
            costPrice: it.minPrice,
            availableStock: it.stock,
            source: SparePartSource.inventory,
          ));
        }
      }
    }

    // 2. Also search Db.items for full models and custom fields
    final allDbItems = entriesOf(Db.items);
    for (final e in allDbItems) {
      final m = e.value;
      final id = '${m['_id'] ?? e.key}';
      if (seenIds.contains(id)) continue;

      final name = '${m['name'] ?? ''}'.toLowerCase();
      final model = '${m['model'] ?? ''}'.toLowerCase();
      final cat = '${m['category'] ?? ''}'.toLowerCase();
      final barcode = '${m['barcode'] ?? m['code'] ?? m['sku'] ?? ''}'.toLowerCase();

      if (name.contains(query) || model.contains(query) || cat.contains(query) || barcode.contains(query)) {
        seenIds.add(id);
        final price = (m['sellingPrice'] as num?)?.toDouble() ??
            (m['price'] as num?)?.toDouble() ??
            0.0;
        final cost = (m['costPrice'] as num?)?.toDouble() ?? 0.0;
        final stock = (m['stock'] as num?)?.toInt() ?? 0;

        results.add(ServiceSparePartItem(
          itemId: id,
          localItemKey: e.key,
          name: '${m['name'] ?? 'Spare Part'}',
          model: '${m['model'] ?? ''}',
          category: '${m['category'] ?? ''}',
          barcode: '${m['barcode'] ?? m['code'] ?? ''}',
          unitPrice: price > 0 ? price : cost,
          costPrice: cost,
          availableStock: stock,
          source: SparePartSource.inventory,
        ));
      }
    }

    setState(() {
      _searchResults = results.take(10).toList();
      _isSearching = true;
    });
  }

  // ---------------------------------------------------------------------------
  // 2. FINANCIAL CALCULATIONS IN PAISE & INR
  // ---------------------------------------------------------------------------
  double get _serviceCharge => double.tryParse(_serviceChargeCtrl.text.trim()) ?? 0.0;
  double get _labour => double.tryParse(_labourCtrl.text.trim()) ?? 0.0;
  double get _discount => double.tryParse(_discountCtrl.text.trim()) ?? 0.0;

  double get _inventorySparesTotal => _selectedParts
      .where((p) => p.isInventory)
      .fold<double>(0.0, (sum, p) => sum + p.lineTotal);

  double get _externalSparesTotal => _selectedParts
      .where((p) => p.isExternal)
      .fold<double>(0.0, (sum, p) => sum + p.lineTotal);

  double get _allSparesTotal => _inventorySparesTotal + _externalSparesTotal;

  double get _advanceReceived {
    final adv = widget.jobData['advance'] ?? widget.repairJob?.advance ?? 0.0;
    return (adv as num?)?.toDouble() ?? double.tryParse('$adv') ?? 0.0;
  }

  // Internal paise calculations
  int get _serviceChargePaise => (_serviceCharge * 100).round();
  int get _labourChargePaise => (_labour * 100).round();
  int get _discountPaise => (_discount * 100).round();
  int get _inventorySparesPaise => (_inventorySparesTotal * 100).round();
  int get _externalSparesPaise => (_externalSparesTotal * 100).round();
  int get _allSparesPaise => _inventorySparesPaise + _externalSparesPaise;
  int get _advanceReceivedPaise => (_advanceReceived * 100).round();

  int get _grossTotalPaise {
    final gross = _allSparesPaise + _serviceChargePaise + _labourChargePaise - _discountPaise;
    return gross < 0 ? 0 : gross;
  }

  double get _grossTotal => _grossTotalPaise / 100.0;

  int get _advanceAppliedPaise {
    if (_advanceReceivedPaise <= 0) return 0;
    return _grossTotalPaise < _advanceReceivedPaise ? _grossTotalPaise : _advanceReceivedPaise;
  }

  double get _advanceApplied => _advanceAppliedPaise / 100.0;

  int get _netPayablePaise {
    final net = _grossTotalPaise - _advanceAppliedPaise;
    return net < 0 ? 0 : net;
  }

  double get _netPayable => _netPayablePaise / 100.0;

  // ---------------------------------------------------------------------------
  // 3. SELECTION & TABLE MANIPULATION (Validations & Steppers)
  // ---------------------------------------------------------------------------
  void _addInventoryPart(ServiceSparePartItem item) {
    final existingIndex = _selectedParts.indexWhere((p) => p.itemId == item.itemId && p.isInventory);

    if (existingIndex >= 0) {
      final existing = _selectedParts[existingIndex];
      if (existing.quantity < item.availableStock) {
        setState(() {
          existing.quantity++;
        });
        TekFeedback.toast('Incremented ${existing.name} (Qty: ${existing.quantity})');
      } else {
        TekFeedback.error('Cannot add more than available stock (${item.availableStock}) for ${item.name}');
      }
    } else {
      if (item.availableStock <= 0) {
        TekFeedback.error('Warning: "${item.name}" has 0 stock in inventory.');
      }
      setState(() {
        _selectedParts.add(
          ServiceSparePartItem(
            itemId: item.itemId,
            localItemKey: item.localItemKey,
            name: item.name,
            model: item.model,
            category: item.category,
            barcode: item.barcode,
            unitPrice: item.unitPrice,
            costPrice: item.costPrice,
            quantity: 1,
            availableStock: item.availableStock,
            source: SparePartSource.inventory,
          ),
        );
      });
      TekFeedback.success('Added "${item.name}" to service bill');
    }

    _searchCtrl.clear();
    setState(() {
      _searchResults = [];
      _isSearching = false;
    });
  }

  void _updateQuantity(int index, int delta) {
    setState(() {
      final part = _selectedParts[index];
      final newQty = part.quantity + delta;

      if (newQty <= 0) {
        _selectedParts.removeAt(index);
      } else if (part.isInventory && newQty > part.availableStock) {
        TekFeedback.error('Cannot exceed available stock (${part.availableStock}) for ${part.name}');
      } else {
        part.quantity = newQty;
      }
    });
  }

  void _updateUnitPrice(int index, String value) {
    final parsed = double.tryParse(value.trim());
    if (parsed != null && parsed >= 0) {
      setState(() {
        _selectedParts[index].unitPrice = parsed;
      });
    }
  }

  void _removePart(int index) {
    setState(() {
      _selectedParts.removeAt(index);
    });
  }

  // ---------------------------------------------------------------------------
  // 4. CUSTOM / EXTERNAL SPARE PARTS MODAL
  // ---------------------------------------------------------------------------
  Future<void> _showAddCustomSpareDialog() async {
    final nameCtrl = TextEditingController();
    final qtyCtrl = TextEditingController(text: '1');
    final priceCtrl = TextEditingController(text: '0');

    final added = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF101846),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: const BorderSide(color: DashboardColors.glassBorderHover),
        ),
        title: Row(
          children: [
            const Icon(Icons.build_circle_outlined, color: DashboardColors.neonOrange, size: 22),
            const SizedBox(width: 8),
            const Text(
              'Add Custom / External Spare Part',
              style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold),
            ),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Use this for parts purchased outside the shop. These parts will NOT deduct shop inventory.',
              style: TextStyle(color: DashboardColors.textMuted, fontSize: 11.5),
            ),
            const SizedBox(height: 14),
            TextField(
              controller: nameCtrl,
              autofocus: true,
              style: const TextStyle(color: Colors.white, fontSize: 13),
              decoration: InputDecoration(
                labelText: 'Spare Part Name *',
                labelStyle: const TextStyle(color: DashboardColors.textMuted),
                hintText: 'e.g. Charging IC, Camera Lens, Back Glass',
                hintStyle: const TextStyle(color: Colors.white24, fontSize: 12),
                filled: true,
                fillColor: Colors.white.withValues(alpha: 0.05),
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
              ),
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: qtyCtrl,
                    keyboardType: TextInputType.number,
                    style: const TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.bold),
                    decoration: InputDecoration(
                      labelText: 'Quantity *',
                      labelStyle: const TextStyle(color: DashboardColors.textMuted),
                      filled: true,
                      fillColor: Colors.white.withValues(alpha: 0.05),
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: TextField(
                    controller: priceCtrl,
                    keyboardType: TextInputType.number,
                    style: const TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.bold),
                    decoration: InputDecoration(
                      labelText: 'Unit Rate ₹ *',
                      labelStyle: const TextStyle(color: DashboardColors.textMuted),
                      prefixText: '₹ ',
                      prefixStyle: const TextStyle(color: DashboardColors.neonGreen),
                      filled: true,
                      fillColor: Colors.white.withValues(alpha: 0.05),
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel', style: TextStyle(color: DashboardColors.textMuted)),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: DashboardColors.neonOrange,
              foregroundColor: Colors.black,
            ),
            onPressed: () {
              if (nameCtrl.text.trim().isEmpty) {
                TekFeedback.error('Please enter the spare part name');
                return;
              }
              final qty = int.tryParse(qtyCtrl.text.trim()) ?? 0;
              final rate = double.tryParse(priceCtrl.text.trim()) ?? -1.0;
              if (qty <= 0 || rate < 0) {
                TekFeedback.error('Please enter valid positive quantity and rate');
                return;
              }
              Navigator.pop(ctx, true);
            },
            child: const Text('Add External Spare', style: TextStyle(fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    );

    if (added == true) {
      final name = nameCtrl.text.trim();
      final qty = int.tryParse(qtyCtrl.text.trim()) ?? 1;
      final rate = double.tryParse(priceCtrl.text.trim()) ?? 0.0;

      setState(() {
        _selectedParts.add(
          ServiceSparePartItem(
            itemId: null,
            name: name,
            quantity: qty,
            unitPrice: rate,
            costPrice: rate,
            availableStock: 0,
            source: SparePartSource.external,
          ),
        );
      });
      TekFeedback.success('Added External Spare: $name');
    }
  }

  // ---------------------------------------------------------------------------
  // 5. ATOMIC FIRESTORE TRANSACTION: DEDUCTION, INVOICE, JOB CARD, DAILY SALES
  // ---------------------------------------------------------------------------
  Future<void> _handleConfirmBill() async {
    if (_isSubmitting) return;

    if (_grossTotal < 0 || _discount < 0) {
      setState(() => _errorMessage = 'Please enter valid positive amounts.');
      return;
    }

    if (_grossTotal < _advanceReceived) {
      setState(() => _errorMessage =
          'Final bill (₹${_grossTotal.toStringAsFixed(0)}) cannot be less than advance already paid (₹${_advanceReceived.toStringAsFixed(0)}).');
      return;
    }

    // Client-side stock pre-check
    for (final part in _selectedParts) {
      if (part.isInventory && part.quantity > part.availableStock) {
        setState(() => _errorMessage =
            'Insufficient stock for "${part.name}": Available ${part.availableStock}, Required ${part.quantity}');
        return;
      }
    }

    setState(() {
      _isSubmitting = true;
      _errorMessage = null;
    });

    final now = DateTime.now();
    final todayStr = '${now.year}${now.month.toString().padLeft(2, '0')}${now.day.toString().padLeft(2, '0')}';
    final invoiceId = await PosService.instance.generateStaffInvoiceId(_shopId, _staffName);

    // Double submission in-flight memory guard
    if (_inFlightInvoices.contains(invoiceId)) {
      setState(() {
        _isSubmitting = false;
        _errorMessage = 'Duplicate invoice submission blocked. Please wait.';
      });
      return;
    }
    _inFlightInvoices.add(invoiceId);

    try {
      final due = _netPayable;
      final appliedAdvance = _advanceApplied;

      // ATOMIC FIRESTORE TRANSACTION
      if (_shopId.isNotEmpty) {
        await FirebaseFirestore.instance.runTransaction((transaction) async {
          final shopDocRef = FirebaseFirestore.instance.collection('shops').doc(_shopId);

          // 1. READ PHASE: Verify live stock for all inventory items
          final itemSnapshots = <String, DocumentSnapshot<Map<String, dynamic>>>{};
          for (final part in _selectedParts) {
            if (part.isInventory && part.itemId != null) {
              // Check in shops/{shopId}/inventory first, then fallback to shops/{shopId}/items
              DocumentReference<Map<String, dynamic>> ref =
                  shopDocRef.collection('inventory').doc(part.itemId);
              var snap = await transaction.get(ref);

              if (!snap.exists) {
                ref = shopDocRef.collection('items').doc(part.itemId);
                snap = await transaction.get(ref);
              }

              itemSnapshots[part.itemId!] = snap;

              if (snap.exists) {
                final data = snap.data();
                final currentStock = (data?['stock'] ?? data?['stockCount'] as num?)?.toInt() ?? 0;
                if (currentStock < part.quantity) {
                  throw Exception(
                    'ആവശ്യത്തിന് സ്റ്റോക്കില്ല: "${part.name}" (Live Available: $currentStock, Required: ${part.quantity})',
                  );
                }
              }
            }
          }

          // Check invoice idempotency in Firestore
          final invRef = shopDocRef.collection('sales').doc(invoiceId);
          final invSnap = await transaction.get(invRef);
          if (invSnap.exists) {
            throw Exception('Invoice $invoiceId already exists. Aborting duplicate.');
          }

          // 2. WRITE PHASE:
          // A. Stock deduction & Inventory consumption logs
          for (final part in _selectedParts) {
            if (part.isInventory && part.itemId != null) {
              final snap = itemSnapshots[part.itemId!];
              if (snap != null && snap.exists) {
                final ref = snap.reference;
                final curStock = (snap.data()?['stock'] ?? snap.data()?['stockCount'] as num?)?.toInt() ?? 0;
                final newStock = curStock - part.quantity;

                transaction.update(ref, {
                  'stock': newStock,
                  'stockCount': newStock,
                  'updatedAt': FieldValue.serverTimestamp(),
                });

                // Inventory Log: shops/{shopId}/inventory_logs/{logId}
                final logRef = shopDocRef.collection('inventory_logs').doc();
                transaction.set(logRef, {
                  'type': 'SERVICE_CONSUMPTION',
                  'itemId': part.itemId,
                  'itemName': part.name,
                  'quantity': part.quantity,
                  'jobId': _jobId,
                  'billId': invoiceId,
                  'createdAt': FieldValue.serverTimestamp(),
                  'createdBy': _staffId,
                });

                // Stock Movement Log
                final moveRef = shopDocRef.collection('stockMovements').doc();
                transaction.set(moveRef, {
                  'itemId': part.itemId,
                  'itemName': part.name,
                  'qtyChange': -part.quantity,
                  'reason': 'Service Job $_jobId Consumption',
                  'jobId': _jobId,
                  'invoiceId': invoiceId,
                  'staffId': _staffId,
                  'staffName': _staffName,
                  'timestamp': FieldValue.serverTimestamp(),
                });
              }
            }
          }

          // B. Service Job Card Update (shops/{shopId}/service_jobs & shops/{shopId}/services)
          final sparePartsUsedMaps = _selectedParts.map((p) => p.toJobSpareMap()).toList();
          final jobPayload = {
            'billCreated': true,
            'billId': invoiceId,
            'invoice': invoiceId,
            'sparePartsUsed': sparePartsUsedMaps,
            'sparePartsTotalPaise': _allSparesPaise,
            'serviceChargePaise': _serviceChargePaise,
            'labourChargePaise': _labourChargePaise,
            'discountPaise': _discountPaise,
            'advanceReceivedPaise': _advanceReceivedPaise,
            'netPayablePaise': _netPayablePaise,
            'finalAmount': _netPayable,
            'paidAmount': _netPayable,
            'advanceApplied': appliedAdvance,
            'paymentMethod': _paymentMode,
            'paymentStatus': 'PAID',
            'status': 'Ready',
            'updatedAt': FieldValue.serverTimestamp(),
            'createdBy': _staffId,
          };

          if (_jobId.isNotEmpty) {
            final jobRef1 = shopDocRef.collection('service_jobs').doc(_jobId);
            transaction.set(jobRef1, jobPayload, SetOptions(merge: true));

            final jobRef2 = shopDocRef.collection('services').doc(_jobId);
            transaction.set(jobRef2, jobPayload, SetOptions(merge: true));
          }

          // C. Sales & Daily Ledger Invoices
          final lineItems = <Map<String, dynamic>>[
            {
              'name': 'Service #$_jobId • $_brandModel (Service & Labour)',
              'qty': 1,
              'price': _serviceCharge + _labour - _discount,
              'costPrice': 0.0,
              'warranty': '$_warrantyDays days',
            },
            for (final p in _selectedParts) p.toInvoiceLineMap(),
          ];

          final salesInvoiceMap = {
            'invoiceId': invoiceId,
            'invoice': invoiceId,
            'shopId': _shopId,
            'staffId': _staffId,
            'staffName': _staffName,
            'date': todayStr,
            'customerName': _customerName,
            'customerPhone': _customerPhone,
            'deviceModel': _brandModel,
            'serviceJobId': _jobId,
            'serviceBill': true,
            'items': lineItems,
            'sparePartsUsed': sparePartsUsedMaps,
            'serviceCharge': _serviceCharge,
            'labourCharge': _labour,
            'sparesTotal': _allSparesTotal,
            'subtotal': _grossTotal,
            'discount': _discount,
            'total': _grossTotal,
            'advanceReceived': _advanceReceived,
            'advanceApplied': appliedAdvance,
            'netPayable': due,
            'paymentMethod': _paymentMode,
            'payment': {
              'mode': _paymentMode,
              'cashAmount': _paymentMode == 'Cash' ? due : 0.0,
              'upiAmount': _paymentMode == 'UPI' ? due : 0.0,
              'cardAmount': _paymentMode == 'Card' ? due : 0.0,
            },
            'cash': _paymentMode == 'Cash' ? due : 0.0,
            'upi': _paymentMode == 'UPI' ? due : 0.0,
            'card': _paymentMode == 'Card' ? due : 0.0,
            'due': 0.0,
            'status': 'completed',
            'createdAt': FieldValue.serverTimestamp(),
          };

          transaction.set(shopDocRef.collection('sales').doc(invoiceId), salesInvoiceMap);
          transaction.set(shopDocRef.collection('sales_orders').doc(invoiceId), salesInvoiceMap);

          // D. Daily Sales Counters for EOD Closing & Cash/UPI Register
          final counterRef = shopDocRef.collection('counters').doc('daily_sales_$todayStr');
          transaction.set(counterRef, {
            'totalSales': FieldValue.increment(due),
            'cashSales': FieldValue.increment(_paymentMode == 'Cash' ? due : 0.0),
            'upiSales': FieldValue.increment(_paymentMode == 'UPI' ? due : 0.0),
            'cardSales': FieldValue.increment(_paymentMode == 'Card' ? due : 0.0),
            'serviceSales': FieldValue.increment(due),
            'billCount': FieldValue.increment(1),
            'lastUpdated': FieldValue.serverTimestamp(),
          }, SetOptions(merge: true));
        });
      }

      // 3. Local Hive & Accounting Updates (Offline Safe)
      for (final part in _selectedParts) {
        if (part.isInventory) {
          for (final k in Db.items.keys) {
            final cur = tekM(Db.items.get(k));
            if (cur['_id'] == part.itemId || '$k' == part.itemId || cur['name'] == part.name) {
              final curStock = (cur['stock'] as num?)?.toInt() ?? 0;
              cur['stock'] = curStock - part.quantity;
              await Db.items.put(k, cur);
              await Db.stockMove(k, part.name, -part.quantity, 'Service $_jobId Consumption');
              break;
            }
          }
        }
      }

      final localBill = <String, dynamic>{
        'invoice': invoiceId,
        'createdAt': now.toIso8601String(),
        'customerName': _customerName,
        'customerPhone': _customerPhone,
        'partyKey': null,
        'items': [
          {
            'name': 'Service #$_jobId • $_brandModel',
            'qty': 1,
            'price': _serviceCharge + _labour - _discount,
            'costPrice': 0.0,
            'warranty': '$_warrantyDays days',
          },
          for (final p in _selectedParts) p.toInvoiceLineMap(),
        ],
        'subtotal': _grossTotal,
        'discount': _discount,
        'total': _grossTotal,
        'cash': _paymentMode == 'Cash' ? due : 0.0,
        'upi': _paymentMode == 'UPI' ? due : 0.0,
        'card': _paymentMode == 'Card' ? due : 0.0,
        'due': 0.0,
        'serviceJobId': _jobId,
        'serviceAdvanceApplied': appliedAdvance,
        'serviceBill': true,
        'sparePartsUsed': _selectedParts.map((p) => p.toJobSpareMap()).toList(),
        'status': 'SOLD',
        ...ActivityLog.stamp(),
      };

      await Db.sales.add(localBill);
      await Db.logAction(
        action: 'Service Billed',
        entity: 'Invoice',
        entityId: invoiceId,
        newValue: {'job': _jobId, 'total': due, 'paymentMode': _paymentMode},
      );

      if (due > 0) {
        await Db.moveMoney(_paymentMode, due, 'Service bill $invoiceId');
      }

      // Update Service Job in Hive
      if (widget.jobKey != null && Db.services.containsKey(widget.jobKey)) {
        final existingJob = tekM(Db.services.get(widget.jobKey));
        final updatedJob = Map<String, dynamic>.from(existingJob);
        updatedJob['finalAmount'] = _netPayable;
        updatedJob['paidAmount'] = _netPayable;
        updatedJob['advanceApplied'] = appliedAdvance;
        updatedJob['billCreated'] = true;
        updatedJob['invoice'] = invoiceId;
        updatedJob['parts'] = _selectedParts.map((p) => p.toJobSpareMap()).toList();
        updatedJob['status'] = 'Ready';
        updatedJob['warrantyStart'] = now.toIso8601String();
        updatedJob['warrantyEnd'] = now.add(Duration(days: _warrantyDays)).toIso8601String();
        await Db.services.put(widget.jobKey, updatedJob);
      }

      if (mounted) {
        TekFeedback.success('Service Invoice #$invoiceId created successfully!');
        Navigator.of(context).pop(true);
        await printInvoice(context, localBill, a4: true);
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isSubmitting = false;
          _errorMessage = 'Billing error: $e';
        });
        TekFeedback.error('Billing failed: $e');
      }
    } finally {
      _inFlightInvoices.remove(invoiceId);
    }
  }

  // ---------------------------------------------------------------------------
  // 6. UI PRESENTATION: TEKFIX ERP DARK THEME & RESPONSIVE LAYOUT
  // ---------------------------------------------------------------------------
  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: const Color(0xFF0C1236),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(20),
        side: const BorderSide(color: DashboardColors.glassBorderHover),
      ),
      insetPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 20),
      child: Container(
        width: 860,
        constraints: const BoxConstraints(maxHeight: 760),
        padding: const EdgeInsets.all(22),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // DIALOG HEADER
            Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: DashboardColors.neonBlue.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: const Icon(Icons.receipt_long_rounded, color: DashboardColors.neonBlue, size: 24),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Service Checkout • Job #$_jobId',
                        style: DashboardTypography.poppins(
                          fontSize: 17,
                          fontWeight: FontWeight.w700,
                          color: Colors.white,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        '$_customerName • $_brandModel • Phone: $_customerPhone',
                        style: const TextStyle(color: DashboardColors.textMuted, fontSize: 12),
                      ),
                    ],
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.close_rounded, color: Colors.white70),
                  onPressed: () => Navigator.pop(context),
                  tooltip: 'Close',
                ),
              ],
            ),

            const SizedBox(height: 12),
            const Divider(color: Color(0x1AFFFFFF)),
            const SizedBox(height: 10),

            // MAIN BODY
            Expanded(
              child: SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // A. SERVICE & LABOUR CHARGES ROW
                    Row(
                      children: [
                        Expanded(
                          child: _buildInputField(
                            controller: _serviceChargeCtrl,
                            label: 'Service Charge ₹',
                            icon: Icons.handyman_rounded,
                            onChanged: (_) => setState(() {}),
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: _buildInputField(
                            controller: _labourCtrl,
                            label: 'Labour Charge ₹',
                            icon: Icons.engineering_rounded,
                            onChanged: (_) => setState(() {}),
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: _buildInputField(
                            controller: _discountCtrl,
                            label: 'Discount ₹',
                            icon: Icons.local_offer_rounded,
                            onChanged: (_) => setState(() {}),
                          ),
                        ),
                      ],
                    ),

                    const SizedBox(height: 16),

                    // B. SPARE PARTS SEARCH & ADD HEADER
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Row(
                          children: [
                            const Icon(Icons.inventory_2_rounded, size: 18, color: DashboardColors.neonGreen),
                            const SizedBox(width: 8),
                            Text(
                              'Spare Parts',
                              style: DashboardTypography.poppins(
                                fontSize: 14,
                                fontWeight: FontWeight.w600,
                                color: Colors.white,
                              ),
                            ),
                          ],
                        ),
                        OutlinedButton.icon(
                          style: OutlinedButton.styleFrom(
                            foregroundColor: DashboardColors.neonOrange,
                            side: const BorderSide(color: DashboardColors.neonOrange),
                            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                          ),
                          icon: const Icon(Icons.add_circle_outline_rounded, size: 15),
                          label: const Text('+ Add Custom / External Spare', style: TextStyle(fontSize: 11.5)),
                          onPressed: _showAddCustomSpareDialog,
                        ),
                      ],
                    ),

                    const SizedBox(height: 8),

                    // Searchable Autocomplete Bar
                    Stack(
                      clipBehavior: Clip.none,
                      children: [
                        TextField(
                          controller: _searchCtrl,
                          focusNode: _searchFocus,
                          style: const TextStyle(color: Colors.white, fontSize: 13),
                          decoration: InputDecoration(
                            isDense: true,
                            hintText: 'Search Spare Part (Combo, Battery, Display, IC, Barcode)...',
                            hintStyle: const TextStyle(color: DashboardColors.textMuted, fontSize: 12),
                            prefixIcon: const Icon(Icons.search_rounded, color: DashboardColors.neonBlue, size: 20),
                            suffixIcon: _searchCtrl.text.isNotEmpty
                                ? IconButton(
                                    icon: const Icon(Icons.clear_rounded, size: 18, color: Colors.white60),
                                    onPressed: () {
                                      _searchCtrl.clear();
                                      setState(() {
                                        _searchResults = [];
                                        _isSearching = false;
                                      });
                                    },
                                  )
                                : null,
                            filled: true,
                            fillColor: Colors.white.withValues(alpha: 0.05),
                            contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
                            border: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(10),
                              borderSide: const BorderSide(color: Color(0x33FFFFFF)),
                            ),
                            focusedBorder: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(10),
                              borderSide: const BorderSide(color: DashboardColors.neonBlue, width: 1.5),
                            ),
                          ),
                        ),

                        // Suggestions Dropdown
                        if (_isSearching && _searchResults.isNotEmpty)
                          Positioned(
                            top: 48,
                            left: 0,
                            right: 0,
                            child: Material(
                              elevation: 12,
                              borderRadius: BorderRadius.circular(10),
                              color: const Color(0xFF141C48),
                              child: Container(
                                constraints: const BoxConstraints(maxHeight: 240),
                                decoration: BoxDecoration(
                                  borderRadius: BorderRadius.circular(10),
                                  border: Border.all(color: DashboardColors.neonBlue.withValues(alpha: 0.5)),
                                ),
                                child: ListView.separated(
                                  shrinkWrap: true,
                                  padding: const EdgeInsets.symmetric(vertical: 4),
                                  itemCount: _searchResults.length,
                                  separatorBuilder: (_, __) => const Divider(color: Color(0x14FFFFFF), height: 1),
                                  itemBuilder: (ctx, idx) {
                                    final it = _searchResults[idx];
                                    final inStock = it.availableStock > 0;

                                    return ListTile(
                                      dense: true,
                                      leading: CircleAvatar(
                                        radius: 14,
                                        backgroundColor: inStock
                                            ? DashboardColors.neonGreen.withValues(alpha: 0.15)
                                            : Colors.red.withValues(alpha: 0.15),
                                        child: Icon(
                                          inStock ? Icons.check_circle_rounded : Icons.warning_rounded,
                                          size: 16,
                                          color: inStock ? DashboardColors.neonGreen : Colors.red,
                                        ),
                                      ),
                                      title: Text(
                                        it.name,
                                        style: const TextStyle(
                                          color: Colors.white,
                                          fontSize: 13,
                                          fontWeight: FontWeight.w600,
                                        ),
                                      ),
                                      subtitle: Text(
                                        '${it.model.isNotEmpty ? "${it.model} • " : ""}${it.category.isNotEmpty ? "${it.category} • " : ""}Stock: ${it.availableStock}',
                                        style: TextStyle(
                                          color: inStock ? DashboardColors.neonGreen : Colors.red,
                                          fontSize: 11,
                                        ),
                                      ),
                                      trailing: Row(
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          Text(
                                            '₹${it.unitPrice.toStringAsFixed(0)}',
                                            style: const TextStyle(
                                              color: DashboardColors.neonBlue,
                                              fontSize: 13,
                                              fontWeight: FontWeight.bold,
                                            ),
                                          ),
                                          const SizedBox(width: 8),
                                          ElevatedButton(
                                            style: ElevatedButton.styleFrom(
                                              backgroundColor: inStock ? DashboardColors.neonBlue : Colors.white24,
                                              foregroundColor: Colors.black,
                                              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                                              minimumSize: Size.zero,
                                              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                                            ),
                                            onPressed: () => _addInventoryPart(it),
                                            child: const Text('Add', style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold)),
                                          ),
                                        ],
                                      ),
                                      onTap: () => _addInventoryPart(it),
                                    );
                                  },
                                ),
                              ),
                            ),
                          ),
                      ],
                    ),

                    const SizedBox(height: 12),

                    // C. SELECTED SPARE PARTS TABLE
                    Container(
                      decoration: BoxDecoration(
                        color: Colors.white.withValues(alpha: 0.03),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: const Color(0x1AFFFFFF)),
                      ),
                      padding: const EdgeInsets.all(12),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              Text(
                                'Selected Spare Parts (${_selectedParts.length})',
                                style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600, fontSize: 13),
                              ),
                              Row(
                                children: [
                                  if (_inventorySparesTotal > 0) ...[
                                    _buildBadge('Inventory: ₹${_inventorySparesTotal.toStringAsFixed(0)}', DashboardColors.neonBlue),
                                    const SizedBox(width: 6),
                                  ],
                                  if (_externalSparesTotal > 0) ...[
                                    _buildBadge('External: ₹${_externalSparesTotal.toStringAsFixed(0)}', DashboardColors.neonOrange),
                                    const SizedBox(width: 6),
                                  ],
                                  _buildBadge('Total: ₹${_allSparesTotal.toStringAsFixed(0)}', DashboardColors.neonGreen),
                                ],
                              ),
                            ],
                          ),
                          const SizedBox(height: 10),

                          if (_selectedParts.isEmpty)
                            Padding(
                              padding: const EdgeInsets.symmetric(vertical: 20),
                              child: Center(
                                child: Column(
                                  children: const [
                                    Icon(Icons.inventory_2_outlined, size: 30, color: Colors.white24),
                                    SizedBox(height: 8),
                                    Text('No spare parts attached yet.', style: TextStyle(color: DashboardColors.textMuted, fontSize: 12.5)),
                                    Text('Search inventory above to add screens, batteries, or click "+ Add Custom / External Spare"',
                                        style: TextStyle(color: Colors.white38, fontSize: 11)),
                                  ],
                                ),
                              ),
                            )
                          else
                            Column(
                              children: [
                                // Table Header
                                Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                                  decoration: BoxDecoration(
                                    color: Colors.white.withValues(alpha: 0.04),
                                    borderRadius: BorderRadius.circular(6),
                                  ),
                                  child: Row(
                                    children: const [
                                      Expanded(flex: 4, child: Text('Item Name', style: TextStyle(color: DashboardColors.textMuted, fontSize: 11, fontWeight: FontWeight.bold))),
                                      Expanded(flex: 2, child: Text('Qty', textAlign: TextAlign.center, style: TextStyle(color: DashboardColors.textMuted, fontSize: 11, fontWeight: FontWeight.bold))),
                                      Expanded(flex: 2, child: Text('Rate (₹)', textAlign: TextAlign.right, style: TextStyle(color: DashboardColors.textMuted, fontSize: 11, fontWeight: FontWeight.bold))),
                                      Expanded(flex: 2, child: Text('Total (₹)', textAlign: TextAlign.right, style: TextStyle(color: DashboardColors.textMuted, fontSize: 11, fontWeight: FontWeight.bold))),
                                      SizedBox(width: 32),
                                    ],
                                  ),
                                ),
                                const SizedBox(height: 4),

                                // Table Rows
                                ListView.separated(
                                  shrinkWrap: true,
                                  physics: const NeverScrollableScrollPhysics(),
                                  itemCount: _selectedParts.length,
                                  separatorBuilder: (_, __) => const Divider(color: Color(0x14FFFFFF), height: 10),
                                  itemBuilder: (ctx, idx) {
                                    final part = _selectedParts[idx];
                                    return Row(
                                      children: [
                                        // Item Name & Source Tag
                                        Expanded(
                                          flex: 4,
                                          child: Column(
                                            crossAxisAlignment: CrossAxisAlignment.start,
                                            children: [
                                              Row(
                                                children: [
                                                  Expanded(
                                                    child: Text(
                                                      part.name,
                                                      style: const TextStyle(color: Colors.white, fontSize: 12.5, fontWeight: FontWeight.w600),
                                                      maxLines: 1,
                                                      overflow: TextOverflow.ellipsis,
                                                    ),
                                                  ),
                                                ],
                                              ),
                                              const SizedBox(height: 2),
                                              Row(
                                                children: [
                                                  Container(
                                                    padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                                                    decoration: BoxDecoration(
                                                      color: part.isInventory
                                                          ? DashboardColors.neonBlue.withValues(alpha: 0.15)
                                                          : DashboardColors.neonOrange.withValues(alpha: 0.15),
                                                      borderRadius: BorderRadius.circular(4),
                                                    ),
                                                    child: Text(
                                                      part.isInventory ? 'INVENTORY (Stock: ${part.availableStock})' : 'EXTERNAL SPARE',
                                                      style: TextStyle(
                                                        color: part.isInventory ? DashboardColors.neonBlue : DashboardColors.neonOrange,
                                                        fontSize: 9.5,
                                                        fontWeight: FontWeight.bold,
                                                      ),
                                                    ),
                                                  ),
                                                ],
                                              ),
                                            ],
                                          ),
                                        ),

                                        // Quantity Stepper
                                        Expanded(
                                          flex: 2,
                                          child: Container(
                                            decoration: BoxDecoration(
                                              color: Colors.black.withValues(alpha: 0.4),
                                              borderRadius: BorderRadius.circular(6),
                                              border: Border.all(color: const Color(0x2AFFFFFF)),
                                            ),
                                            child: Row(
                                              mainAxisAlignment: MainAxisAlignment.center,
                                              children: [
                                                IconButton(
                                                  padding: EdgeInsets.zero,
                                                  constraints: const BoxConstraints(minWidth: 24, minHeight: 24),
                                                  icon: const Icon(Icons.remove_rounded, size: 14, color: Colors.white70),
                                                  onPressed: () => _updateQuantity(idx, -1),
                                                ),
                                                Text(
                                                  '${part.quantity}',
                                                  style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 12),
                                                ),
                                                IconButton(
                                                  padding: EdgeInsets.zero,
                                                  constraints: const BoxConstraints(minWidth: 24, minHeight: 24),
                                                  icon: const Icon(Icons.add_rounded, size: 14, color: DashboardColors.neonGreen),
                                                  onPressed: () => _updateQuantity(idx, 1),
                                                ),
                                              ],
                                            ),
                                          ),
                                        ),

                                        // Editable Unit Rate (₹)
                                        Expanded(
                                          flex: 2,
                                          child: Container(
                                            margin: const EdgeInsets.symmetric(horizontal: 6),
                                            height: 32,
                                            child: TextFormField(
                                              initialValue: part.unitPrice.toStringAsFixed(0),
                                              keyboardType: TextInputType.number,
                                              textAlign: TextAlign.right,
                                              style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.bold),
                                              decoration: InputDecoration(
                                                isDense: true,
                                                contentPadding: const EdgeInsets.symmetric(horizontal: 6, vertical: 8),
                                                border: OutlineInputBorder(borderRadius: BorderRadius.circular(6)),
                                                filled: true,
                                                fillColor: Colors.white.withValues(alpha: 0.05),
                                              ),
                                              onChanged: (v) => _updateUnitPrice(idx, v),
                                            ),
                                          ),
                                        ),

                                        // Line Total
                                        Expanded(
                                          flex: 2,
                                          child: Text(
                                            '₹${part.lineTotal.toStringAsFixed(0)}',
                                            textAlign: TextAlign.right,
                                            style: const TextStyle(
                                              color: DashboardColors.neonBlue,
                                              fontSize: 12.5,
                                              fontWeight: FontWeight.bold,
                                            ),
                                          ),
                                        ),

                                        // Remove Button
                                        IconButton(
                                          icon: const Icon(Icons.delete_outline_rounded, size: 18, color: Colors.redAccent),
                                          onPressed: () => _removePart(idx),
                                          tooltip: 'Remove',
                                        ),
                                      ],
                                    );
                                  },
                                ),
                              ],
                            ),
                        ],
                      ),
                    ),

                    const SizedBox(height: 14),

                    // D. SUMMARY BREAKDOWN CARD
                    Container(
                      padding: const EdgeInsets.all(14),
                      decoration: BoxDecoration(
                        color: const Color(0xFF141C48),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: DashboardColors.neonBlue.withValues(alpha: 0.3)),
                      ),
                      child: Column(
                        children: [
                          _buildSummaryRow('Inventory Spares Total:', '₹${_inventorySparesTotal.toStringAsFixed(0)}'),
                          if (_externalSparesTotal > 0) ...[
                            const SizedBox(height: 4),
                            _buildSummaryRow('External Spares Total:', '₹${_externalSparesTotal.toStringAsFixed(0)}', color: DashboardColors.neonOrange),
                          ],
                          const SizedBox(height: 4),
                          _buildSummaryRow('Service Charge:', '₹${_serviceCharge.toStringAsFixed(0)}'),
                          if (_labour > 0) ...[
                            const SizedBox(height: 4),
                            _buildSummaryRow('Labour Charge:', '₹${_labour.toStringAsFixed(0)}'),
                          ],
                          if (_discount > 0) ...[
                            const SizedBox(height: 4),
                            _buildSummaryRow('Discount:', '-₹${_discount.toStringAsFixed(0)}', color: Colors.orangeAccent),
                          ],
                          const Divider(color: Color(0x26FFFFFF), height: 14),
                          _buildSummaryRow(
                            'Gross Total:',
                            '₹${_grossTotal.toStringAsFixed(0)}',
                            bold: true,
                            fontSize: 14,
                            color: Colors.white,
                          ),
                          if (_advanceReceived > 0) ...[
                            const SizedBox(height: 4),
                            _buildSummaryRow(
                              'Advance Paid by Customer:',
                              '-₹${_advanceReceived.toStringAsFixed(0)}',
                              color: DashboardColors.neonGreen,
                            ),
                          ],
                          const Divider(color: Color(0x33FFFFFF), height: 14),
                          Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              const Text(
                                'NET PAYABLE:',
                                style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14, color: Colors.white),
                              ),
                              Text(
                                '₹${_netPayable.toStringAsFixed(0)}',
                                style: const TextStyle(
                                  fontWeight: FontWeight.w900,
                                  fontSize: 19,
                                  color: DashboardColors.neonGreen,
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),

                    const SizedBox(height: 14),

                    // E. PAYMENT METHOD
                    Row(
                      children: [
                        const Text(
                          'Payment Method: ',
                          style: TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.w600),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: ModeSelector(
                            value: _paymentMode,
                            options: const ['Cash', 'UPI', 'Card'],
                            onChanged: (v) => setState(() => _paymentMode = v),
                          ),
                        ),
                      ],
                    ),

                    if (_errorMessage != null) ...[
                      const SizedBox(height: 10),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                        decoration: BoxDecoration(
                          color: Colors.red.withValues(alpha: 0.15),
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(color: Colors.red.withValues(alpha: 0.4)),
                        ),
                        child: Row(
                          children: [
                            const Icon(Icons.error_outline_rounded, color: Colors.redAccent, size: 18),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                _errorMessage!,
                                style: const TextStyle(color: Colors.redAccent, fontSize: 12),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),

            const SizedBox(height: 14),
            const Divider(color: Color(0x1AFFFFFF)),
            const SizedBox(height: 8),

            // DIALOG ACTIONS
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text('Cancel', style: TextStyle(color: DashboardColors.textMuted)),
                ),
                ElevatedButton.icon(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: DashboardColors.neonGreen,
                    foregroundColor: Colors.black,
                    padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                  ),
                  icon: _isSubmitting
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2, color: Colors.black),
                        )
                      : const Icon(Icons.check_circle_rounded, size: 18),
                  label: Text(
                    _isSubmitting
                        ? 'Creating Bill...'
                        : 'Confirm & Create Bill (₹${_netPayable.toStringAsFixed(0)})',
                    style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
                  ),
                  onPressed: _isSubmitting ? null : _handleConfirmBill,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildBadge(String text, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: color.withValues(alpha: 0.3)),
      ),
      child: Text(
        text,
        style: TextStyle(color: color, fontSize: 10.5, fontWeight: FontWeight.bold),
      ),
    );
  }

  Widget _buildInputField({
    required TextEditingController controller,
    required String label,
    required IconData icon,
    required ValueChanged<String> onChanged,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: const TextStyle(color: DashboardColors.textMuted, fontSize: 11.5, fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 4),
        TextField(
          controller: controller,
          keyboardType: TextInputType.number,
          style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 13),
          decoration: InputDecoration(
            isDense: true,
            prefixIcon: Icon(icon, size: 18, color: DashboardColors.neonBlue),
            filled: true,
            fillColor: Colors.white.withValues(alpha: 0.05),
            contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(10),
              borderSide: const BorderSide(color: DashboardColors.neonBlue, width: 1.5),
            ),
          ),
          onChanged: onChanged,
        ),
      ],
    );
  }

  Widget _buildSummaryRow(
    String label,
    String value, {
    bool bold = false,
    double fontSize = 12.5,
    Color color = Colors.white70,
  }) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(
          label,
          style: TextStyle(
            color: color,
            fontSize: fontSize,
            fontWeight: bold ? FontWeight.bold : FontWeight.normal,
          ),
        ),
        Text(
          value,
          style: TextStyle(
            color: color,
            fontSize: fontSize,
            fontWeight: bold ? FontWeight.bold : FontWeight.w600,
          ),
        ),
      ],
    );
  }
}
