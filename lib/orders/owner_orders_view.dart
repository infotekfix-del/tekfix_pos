import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import '../auth/auth_controller.dart';
import '../main.dart' show Db, kPrimary, toast;
import '../theme/tek_tokens.dart';
import '../ui/tek_feedback.dart';
import 'order_models.dart';
import 'order_service.dart';

class OwnerOrdersView extends StatefulWidget {
  final String shopId;

  const OwnerOrdersView({super.key, required this.shopId});

  @override
  State<OwnerOrdersView> createState() => _OwnerOrdersViewState();
}

class _OwnerOrdersViewState extends State<OwnerOrdersView> {
  final TextEditingController _searchCtrl = TextEditingController();
  String _searchQuery = '';
  String _selectedStatusFilter = 'All';
  String _selectedStaffFilter = 'All';

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  // Owner update order status with instant Firestore sync & audit trail
  Future<void> _updateStatus(StaffOrder order, StaffOrderStatus newStatus) async {
    final auth = AuthController.instance;
    final ownerName = auth.name.isNotEmpty ? auth.name : 'Owner';

    try {
      await OrderService.instance.updateOrderStatus(
        shopId: widget.shopId,
        orderId: order.orderId,
        newStatus: newStatus,
        ownerName: ownerName,
      );
      if (mounted) {
        TekFeedback.showSuccess(context, '${order.orderId} സ്റ്റാറ്റസ് ${newStatus.label} ആക്കി മാറ്റി');
      }
    } catch (e) {
      if (mounted) {
        TekFeedback.showError(context, 'സ്റ്റാറ്റസ് മാറ്റാൻ സാധിച്ചില്ല: $e');
      }
    }
  }

  // Open WhatsApp Settings Modal
  Future<void> _openWhatsAppSettingsDialog() async {
    final currentConfig = await OrderService.instance.getWhatsAppConfig(widget.shopId);
    final groupUrlCtrl = TextEditingController(text: currentConfig.groupInvitationUrl);
    final apiUrlCtrl = TextEditingController(text: currentConfig.apiUrl);
    final apiTokenCtrl = TextEditingController(text: currentConfig.apiToken);

    if (!mounted) return;

    await showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Row(
          children: [
            Icon(Icons.settings_suggest_rounded, color: Color(0xFF25D366)),
            SizedBox(width: 8),
            Text('WhatsApp Settings (കോൺഫിഗറേഷൻ)'),
          ],
        ),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'സ്റ്റാഫ് സമർപ്പിക്കുന്ന ഓർഡറുകൾ അയക്കാനുള്ള കമ്പനി WhatsApp ഗ്രൂപ്പ് ലിങ്ക് ഇവിടെ നൽകുക.',
                style: TextStyle(fontSize: 12.5),
              ),
              const SizedBox(height: 14),
              TextField(
                controller: groupUrlCtrl,
                decoration: const InputDecoration(
                  labelText: 'WhatsApp Group Invite Link *',
                  hintText: 'https://chat.whatsapp.com/...',
                  prefixIcon: Icon(Icons.link_rounded),
                ),
              ),
              const SizedBox(height: 16),
              const Text(
                'Cloud Webhook / API Settings (Optional):',
                style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: apiUrlCtrl,
                decoration: const InputDecoration(
                  labelText: 'API Webhook URL (Optional)',
                  hintText: 'https://...',
                  prefixIcon: Icon(Icons.webhook_rounded),
                ),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: apiTokenCtrl,
                decoration: const InputDecoration(
                  labelText: 'Bearer Token (Optional)',
                  prefixIcon: Icon(Icons.key_rounded),
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('റദ്ദാക്കുക (Cancel)'),
          ),
          FilledButton(
            onPressed: () async {
              final newConfig = WhatsAppGroupConfig(
                groupInvitationUrl: groupUrlCtrl.text.trim().isNotEmpty
                    ? groupUrlCtrl.text.trim()
                    : currentConfig.groupInvitationUrl,
                apiUrl: apiUrlCtrl.text.trim(),
                apiToken: apiTokenCtrl.text.trim(),
              );
              await OrderService.instance.saveWhatsAppConfig(widget.shopId, newConfig);
              if (ctx.mounted) {
                Navigator.pop(ctx);
                toast(ctx, 'WhatsApp കോൺഫിഗറേഷൻ സേവ് ചെയ്തു');
              }
            },
            child: const Text('സേവ് ചെയ്യുക (Save)'),
          ),
        ],
      ),
    );
  }

  // Open Full Order Details Modal
  void _showOrderDetails(StaffOrder order) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Row(
          children: [
            const Icon(Icons.receipt_long_rounded, color: kPrimary),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                'Order Details: ${order.orderId}',
                style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
              ),
            ),
          ],
        ),
        content: SizedBox(
          width: 550,
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.min,
              children: [
                // Info Header Card
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Colors.grey.shade100,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Column(
                    children: [
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text('Staff: ${order.staffName}',
                              style: const TextStyle(fontWeight: FontWeight.bold)),
                          Text('${order.createdDate} ${order.createdTime}',
                              style: TextStyle(color: Colors.grey.shade700, fontSize: 12)),
                        ],
                      ),
                      const SizedBox(height: 6),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text(
                            'Status: ${order.status.label} (${order.status.labelMl})',
                            style: TextStyle(
                              fontWeight: FontWeight.bold,
                              color: order.status.color,
                            ),
                          ),
                          Text(
                            'Total Units: ${order.totalQuantity} Pcs',
                            style: const TextStyle(fontWeight: FontWeight.bold),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 14),
                const Text(
                  'ഉൽപ്പന്നങ്ങൾ (Products List):',
                  style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
                ),
                const SizedBox(height: 6),
                ...order.products.map(
                  (p) => Container(
                    margin: const EdgeInsets.symmetric(vertical: 4),
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      border: Border.all(color: Colors.grey.shade300),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        CircleAvatar(
                          radius: 14,
                          backgroundColor: p.isCustom
                              ? Colors.orange.shade100
                              : kPrimary.withValues(alpha: 0.1),
                          child: Icon(
                            p.isCustom ? Icons.handyman_outlined : Icons.inventory_2_outlined,
                            size: 16,
                            color: p.isCustom ? Colors.orange.shade800 : kPrimary,
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(p.name,
                                  style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13.5)),
                              if (p.model.isNotEmpty || p.variant.isNotEmpty)
                                Text(
                                  [
                                    if (p.model.isNotEmpty) 'Model: ${p.model}',
                                    if (p.variant.isNotEmpty) 'Variant: ${p.variant}',
                                  ].join(' | '),
                                  style: TextStyle(fontSize: 12, color: Colors.grey.shade700),
                                ),
                              if (p.remarks.isNotEmpty)
                                Text(
                                  'Note: ${p.remarks}',
                                  style: const TextStyle(fontSize: 11.5, fontStyle: FontStyle.italic),
                                ),
                            ],
                          ),
                        ),
                        Text(
                          '${p.quantity} ${p.unit}',
                          style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
                        ),
                      ],
                    ),
                  ),
                ),
                if (order.generalRemarks.isNotEmpty) ...[
                  const SizedBox(height: 12),
                  const Text('General Remarks / Note:',
                      style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
                  const SizedBox(height: 4),
                  Container(
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: Colors.amber.shade50,
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: Colors.amber.shade200),
                    ),
                    child: Text(order.generalRemarks, style: const TextStyle(fontSize: 12.5)),
                  ),
                ],
                const SizedBox(height: 14),
                // Formatted WhatsApp Preview Box
                const Text(
                  'WhatsApp Message Preview:',
                  style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
                ),
                const SizedBox(height: 6),
                Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: Colors.grey.shade900,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    OrderService.instance.formatWhatsAppMessage(order),
                    style: const TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 11,
                      color: Colors.white70,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
        actions: [
          OutlinedButton.icon(
            icon: const Icon(Icons.copy_rounded, size: 16),
            label: const Text('Copy WhatsApp Text'),
            onPressed: () async {
              final msg = OrderService.instance.formatWhatsAppMessage(order);
              await OrderService.instance.copyOrderToClipboard(msg);
              if (ctx.mounted) toast(ctx, 'ഓർഡർ കോപ്പി ചെയ്തു');
            },
          ),
          ElevatedButton.icon(
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF25D366),
              foregroundColor: Colors.white,
            ),
            icon: const Icon(Icons.send_rounded, size: 16),
            label: const Text('Open WhatsApp Group'),
            onPressed: () async {
              final msg = OrderService.instance.formatWhatsAppMessage(order);
              await OrderService.instance.copyOrderToClipboard(msg);
              await OrderService.instance.openWhatsAppGroup(
                'https://chat.whatsapp.com/GD5fTnnLRk9I0mPXdJ80n0?s=cl&p=a&mlu=4&ilr=4',
              );
            },
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('ക്ലോസ് (Close)'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final effectiveShopId = widget.shopId.isNotEmpty
        ? widget.shopId
        : (context.watch<AuthController>().shopId.isNotEmpty
            ? context.watch<AuthController>().shopId
            : Db.setting('shop_id'));

    return Scaffold(
      appBar: AppBar(
        title: const Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Staff Orders Management (സ്റ്റാഫ് ഓർഡറുകൾ)',
              style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
            ),
            Text(
              'Real-Time Unified Cloud Orders & WhatsApp Integration',
              style: TextStyle(fontSize: 11.5, color: Colors.white70),
            ),
          ],
        ),
        actions: [
          IconButton(
            tooltip: 'WhatsApp Settings',
            icon: const Icon(Icons.settings_applications_rounded),
            onPressed: _openWhatsAppSettingsDialog,
          ),
        ],
      ),
      body: StreamBuilder<List<StaffOrder>>(
        stream: OrderService.instance.streamAllOrders(effectiveShopId),
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }

          if (snapshot.hasError) {
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(24.0),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.error_outline_rounded, color: Colors.red, size: 48),
                    const SizedBox(height: 12),
                    Text('ഓർഡറുകൾ ലോഡ് ചെയ്യുന്നതിൽ പിശക്: ${snapshot.error}',
                        textAlign: TextAlign.center,
                        style: const TextStyle(color: Colors.red)),
                  ],
                ),
              ),
            );
          }

          final allOrders = snapshot.data ?? [];

          // Compute KPI Counts
          final totalOrdersCount = allOrders.length;
          final pendingCount = allOrders
              .where((o) =>
                  o.status == StaffOrderStatus.submitted || o.status == StaffOrderStatus.pending)
              .length;
          final confirmedCount = allOrders
              .where((o) =>
                  o.status == StaffOrderStatus.confirmed || o.status == StaffOrderStatus.processing)
              .length;
          final completedCount =
              allOrders.where((o) => o.status == StaffOrderStatus.completed).length;
          final totalUnitsCount =
              allOrders.fold<int>(0, (sum, o) => sum + o.totalQuantity);

          // Extract distinct staff names for filter dropdown
          final distinctStaff = <String>{'All'};
          for (final o in allOrders) {
            if (o.staffName.trim().isNotEmpty) distinctStaff.add(o.staffName.trim());
          }

          // Filter by search, status, and staff
          final filtered = allOrders.where((o) {
            final matchesStatus = _selectedStatusFilter == 'All' ||
                o.status.name.toLowerCase() == _selectedStatusFilter.toLowerCase();
            final matchesStaff =
                _selectedStaffFilter == 'All' || o.staffName.trim() == _selectedStaffFilter;

            final q = _searchQuery.toLowerCase();
            final matchesQuery = q.isEmpty ||
                o.orderId.toLowerCase().contains(q) ||
                o.staffName.toLowerCase().contains(q) ||
                o.products.any((p) => p.name.toLowerCase().contains(q));

            return matchesStatus && matchesStaff && matchesQuery;
          }).toList();

          return Column(
            children: [
              // KPI Stat Cards Row
              Padding(
                padding: const EdgeInsets.fromLTRB(14, 14, 14, 8),
                child: LayoutBuilder(
                  builder: (ctx, constraints) {
                    final isWide = constraints.maxWidth > 700;
                    return Wrap(
                      spacing: 10,
                      runSpacing: 10,
                      children: [
                        _buildKpiCard('Total Orders', '$totalOrdersCount', Icons.shopping_bag_rounded,
                            kPrimary, isWide),
                        _buildKpiCard('Pending Action', '$pendingCount',
                            Icons.pending_actions_rounded, Colors.orange.shade800, isWide),
                        _buildKpiCard('In Processing', '$confirmedCount',
                            Icons.published_with_changes_rounded, Colors.purple.shade700, isWide),
                        _buildKpiCard('Completed', '$completedCount',
                            Icons.check_circle_rounded, Colors.teal.shade700, isWide),
                        _buildKpiCard('Total Units', '$totalUnitsCount',
                            Icons.inventory_2_rounded, Colors.blueGrey.shade800, isWide),
                      ],
                    );
                  },
                ),
              ),

              // Filter & Search Controls Bar
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
                child: Card(
                  elevation: 0.5,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                    child: Wrap(
                      spacing: 12,
                      runSpacing: 8,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        // Search Box
                        SizedBox(
                          width: 240,
                          child: TextField(
                            controller: _searchCtrl,
                            onChanged: (val) => setState(() => _searchQuery = val.trim()),
                            decoration: InputDecoration(
                              hintText: 'Search order, staff, product...',
                              prefixIcon: const Icon(Icons.search_rounded, size: 20),
                              suffixIcon: _searchQuery.isNotEmpty
                                  ? IconButton(
                                      icon: const Icon(Icons.clear_rounded, size: 18),
                                      onPressed: () {
                                        _searchCtrl.clear();
                                        setState(() => _searchQuery = '');
                                      },
                                    )
                                  : null,
                              isDense: true,
                              contentPadding:
                                  const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                              border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
                            ),
                          ),
                        ),

                        // Status Filter Dropdown
                        DropdownButton<String>(
                          value: _selectedStatusFilter,
                          underline: const SizedBox.shrink(),
                          items: [
                            const DropdownMenuItem(value: 'All', child: Text('Status: All')),
                            ...StaffOrderStatus.values.map(
                              (s) => DropdownMenuItem(
                                value: s.name,
                                child: Row(
                                  children: [
                                    CircleAvatar(radius: 4, backgroundColor: s.color),
                                    const SizedBox(width: 6),
                                    Text(s.label),
                                  ],
                                ),
                              ),
                            ),
                          ],
                          onChanged: (v) {
                            if (v != null) setState(() => _selectedStatusFilter = v);
                          },
                        ),

                        // Staff Filter Dropdown
                        DropdownButton<String>(
                          value: _selectedStaffFilter,
                          underline: const SizedBox.shrink(),
                          items: distinctStaff
                              .map(
                                (s) => DropdownMenuItem(
                                  value: s,
                                  child: Text(s == 'All' ? 'Staff: All' : s),
                                ),
                              )
                              .toList(),
                          onChanged: (v) {
                            if (v != null) setState(() => _selectedStaffFilter = v);
                          },
                        ),

                        // Export CSV Button
                        OutlinedButton.icon(
                          icon: const Icon(Icons.file_download_outlined, size: 18),
                          label: const Text('Export CSV Report'),
                          onPressed: () {
                            if (filtered.isEmpty) {
                              toast(context, 'ഡൗൺലോഡ് ചെയ്യാൻ ഓർഡറുകളൊന്നുമില്ല', error: true);
                              return;
                            }
                            final csvContent =
                                OrderService.instance.exportOrdersToCsv(filtered);
                            Clipboard.setData(ClipboardData(text: csvContent));
                            toast(context, 'Orders CSV ക്ലിപ്ബോർഡിലേക്ക് കോപ്പി ചെയ്തു');
                          },
                        ),
                      ],
                    ),
                  ),
                ),
              ),

              // Orders List
              Expanded(
                child: filtered.isEmpty
                    ? Center(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(Icons.inbox_rounded, size: 48, color: Colors.grey.shade400),
                            const SizedBox(height: 10),
                            const Text(
                              'ഓർഡറുകളൊന്നും കണ്ടെത്തിയില്ല\n(No matching orders)',
                              textAlign: TextAlign.center,
                              style: TextStyle(color: Colors.grey),
                            ),
                          ],
                        ),
                      )
                    : ListView.separated(
                        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                        itemCount: filtered.length,
                        separatorBuilder: (_, __) => const SizedBox(height: 8),
                        itemBuilder: (ctx, i) {
                          final o = filtered[i];
                          final isPending = o.status == StaffOrderStatus.pending ||
                              o.status == StaffOrderStatus.submitted;
                          return Container(
                            decoration: BoxDecoration(
                              color: TekColors.cardBg,
                              borderRadius: BorderRadius.circular(14),
                              border: Border.all(
                                color: isPending
                                    ? TekColors.warning.withValues(alpha: 0.45)
                                    : TekColors.border,
                                width: isPending ? 1.4 : 1.0,
                              ),
                              boxShadow: isPending
                                  ? [
                                      BoxShadow(
                                        color: TekColors.warning.withValues(alpha: 0.08),
                                        blurRadius: 12,
                                        offset: const Offset(0, 3),
                                      ),
                                    ]
                                  : TekColors.cardShadow,
                            ),
                            child: Padding(
                              padding: const EdgeInsets.all(14),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                children: [
                                  Row(
                                    children: [
                                      CircleAvatar(
                                        radius: 18,
                                        backgroundColor: o.status.color.withValues(alpha: 0.12),
                                        child: Icon(Icons.receipt_rounded,
                                            color: o.status.color, size: 20),
                                      ),
                                      const SizedBox(width: 10),
                                      Expanded(
                                        child: Column(
                                          crossAxisAlignment: CrossAxisAlignment.start,
                                          children: [
                                            Row(
                                              children: [
                                                Text(
                                                  o.orderId,
                                                  style: const TextStyle(
                                                    fontWeight: FontWeight.bold,
                                                    fontSize: 14.5,
                                                  ),
                                                ),
                                                const SizedBox(width: 8),
                                                Text(
                                                  '• Staff: ${o.staffName}',
                                                  style: TextStyle(
                                                    fontSize: 12.5,
                                                    color: Colors.grey.shade800,
                                                    fontWeight: FontWeight.w600,
                                                  ),
                                                ),
                                              ],
                                            ),
                                            const SizedBox(height: 2),
                                            Text(
                                              '${o.createdDate} at ${o.createdTime} • ${o.totalTypes} Types (${o.totalQuantity} Pcs)',
                                              style: TextStyle(
                                                fontSize: 12,
                                                color: Colors.grey.shade600,
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),
                                      // Status Picker Dropdown
                                      Container(
                                        padding: const EdgeInsets.symmetric(
                                            horizontal: 10, vertical: 2),
                                        decoration: BoxDecoration(
                                          color: o.status.color.withValues(alpha: 0.1),
                                          borderRadius: BorderRadius.circular(8),
                                          border: Border.all(
                                              color: o.status.color.withValues(alpha: 0.3)),
                                        ),
                                        child: DropdownButton<StaffOrderStatus>(
                                          value: o.status,
                                          underline: const SizedBox.shrink(),
                                          isDense: true,
                                          items: StaffOrderStatus.values
                                              .map(
                                                (s) => DropdownMenuItem(
                                                  value: s,
                                                  child: Text(
                                                    '${s.label} (${s.labelMl})',
                                                    style: TextStyle(
                                                      fontSize: 12,
                                                      fontWeight: FontWeight.bold,
                                                      color: s.color,
                                                    ),
                                                  ),
                                                ),
                                              )
                                              .toList(),
                                          onChanged: (newSt) {
                                            if (newSt != null && newSt != o.status) {
                                              _updateStatus(o, newSt);
                                            }
                                          },
                                        ),
                                      ),
                                    ],
                                  ),
                                  const Divider(height: 16),
                                  // Products summary snippet
                                  Wrap(
                                    spacing: 6,
                                    runSpacing: 4,
                                    children: o.products.take(4).map((p) {
                                      return Chip(
                                        materialTapTargetSize:
                                            MaterialTapTargetSize.shrinkWrap,
                                        visualDensity: VisualDensity.compact,
                                        backgroundColor: Colors.grey.shade100,
                                        label: Text(
                                          '${p.name} (${p.quantity} ${p.unit})',
                                          style: const TextStyle(fontSize: 11),
                                        ),
                                      );
                                    }).toList()
                                      ..addAll([
                                        if (o.products.length > 4)
                                          Chip(
                                            materialTapTargetSize:
                                                MaterialTapTargetSize.shrinkWrap,
                                            visualDensity: VisualDensity.compact,
                                            backgroundColor: kPrimary.withValues(alpha: 0.1),
                                            label: Text(
                                              '+${o.products.length - 4} more',
                                              style: const TextStyle(
                                                  fontSize: 11,
                                                  fontWeight: FontWeight.bold,
                                                  color: kPrimary),
                                            ),
                                          ),
                                      ]),
                                  ),
                                  if (o.generalRemarks.isNotEmpty) ...[
                                    const SizedBox(height: 6),
                                    Text(
                                      'Remarks: ${o.generalRemarks}',
                                      style: TextStyle(
                                          fontSize: 11.5,
                                          fontStyle: FontStyle.italic,
                                          color: Colors.grey.shade700),
                                    ),
                                  ],
                                  const SizedBox(height: 8),
                                  Row(
                                    mainAxisAlignment: MainAxisAlignment.end,
                                    children: [
                                      TextButton.icon(
                                        icon: const Icon(Icons.copy_rounded, size: 16),
                                        label: const Text('Copy Message',
                                            style: TextStyle(fontSize: 12)),
                                        onPressed: () async {
                                          final msg = OrderService.instance
                                              .formatWhatsAppMessage(o);
                                          await OrderService.instance
                                              .copyOrderToClipboard(msg);
                                          if (ctx.mounted) {
                                            toast(ctx, 'ഓർഡർ കോപ്പി ചെയ്തു');
                                          }
                                        },
                                      ),
                                      const SizedBox(width: 8),
                                      FilledButton.tonalIcon(
                                        icon: const Icon(Icons.visibility_rounded, size: 16),
                                        label: const Text('View Full Details',
                                            style: TextStyle(fontSize: 12)),
                                        onPressed: () => _showOrderDetails(o),
                                      ),
                                    ],
                                  ),
                                ],
                              ),
                            ),
                          );
                        },
                      ),
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _buildKpiCard(
      String title, String value, IconData icon, Color color, bool isWide) {
    return Container(
      width: isWide ? 175 : 150,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: TekColors.cardBg,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: color.withValues(alpha: 0.35), width: 1.2),
        boxShadow: [
          BoxShadow(
            color: color.withValues(alpha: 0.1),
            blurRadius: 10,
            offset: const Offset(0, 3),
          ),
        ],
      ),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(icon, color: color, size: 20),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  value,
                  style: TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.w900,
                    color: color,
                  ),
                ),
                Text(
                  title,
                  style: const TextStyle(
                    fontSize: 11,
                    color: TekColors.textSecondary,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
