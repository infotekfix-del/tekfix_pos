import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../main.dart' show Db, rs;
import '../theme/tek_tokens.dart';

/// Interactive Global Search Dialog accessible via Ctrl+K or search bar
class TekGlobalSearchDialog extends StatefulWidget {
  final Function(int moduleIndex)? onNavigateModule;

  const TekGlobalSearchDialog({super.key, this.onNavigateModule});

  static Future<void> show(BuildContext context, {Function(int moduleIndex)? onNavigate}) {
    HapticFeedback.lightImpact();
    return showDialog(
      context: context,
      barrierColor: Colors.black.withValues(alpha: 0.75),
      builder: (ctx) => TekGlobalSearchDialog(onNavigateModule: onNavigate),
    );
  }

  @override
  State<TekGlobalSearchDialog> createState() => _TekGlobalSearchDialogState();
}

class _TekGlobalSearchDialogState extends State<TekGlobalSearchDialog> {
  final _searchCtrl = TextEditingController();
  String _query = '';

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final query = _query.trim().toLowerCase();

    // 1. Search in Items / Stock
    final matchedItems = <Map<String, dynamic>>[];
    if (query.isNotEmpty) {
      for (final v in Db.items.values) {
        if (v is Map) {
          final name = '${v['name'] ?? ''}'.toLowerCase();
          final barcode = '${v['barcode'] ?? ''}'.toLowerCase();
          final category = '${v['category'] ?? ''}'.toLowerCase();
          if (name.contains(query) || barcode.contains(query) || category.contains(query)) {
            matchedItems.add(Map<String, dynamic>.from(v));
            if (matchedItems.length >= 5) break;
          }
        }
      }
    }

    // 2. Search in Parties / Customers
    final matchedParties = <Map<String, dynamic>>[];
    if (query.isNotEmpty) {
      for (final v in Db.parties.values) {
        if (v is Map) {
          final name = '${v['name'] ?? ''}'.toLowerCase();
          final phone = '${v['phone'] ?? ''}'.toLowerCase();
          if (name.contains(query) || phone.contains(query)) {
            matchedParties.add(Map<String, dynamic>.from(v));
            if (matchedParties.length >= 5) break;
          }
        }
      }
    }

    // 3. Search in Invoices
    final matchedSales = <Map<String, dynamic>>[];
    if (query.isNotEmpty) {
      for (var i = Db.sales.length - 1; i >= 0 && matchedSales.length < 5; i--) {
        final v = Db.sales.getAt(i);
        if (v is Map) {
          final inv = '${v['invoice'] ?? ''}'.toLowerCase();
          final cust = '${v['customerName'] ?? ''}'.toLowerCase();
          if (inv.contains(query) || cust.contains(query)) {
            matchedSales.add(Map<String, dynamic>.from(v));
          }
        }
      }
    }

    // 4. Quick Nav Modules
    final navItems = [
      {'title': 'Dashboard / Home', 'icon': Icons.dashboard_rounded, 'index': 0},
      {'title': 'Sales / POS', 'icon': Icons.point_of_sale_rounded, 'index': 1},
      {'title': 'Items / Stock', 'icon': Icons.inventory_2_rounded, 'index': 2},
      {'title': 'Services / Repairs', 'icon': Icons.build_circle_rounded, 'index': 3},
      {'title': 'Cash & Bank', 'icon': Icons.account_balance_rounded, 'index': 6},
      {'title': 'Staff Orders', 'icon': Icons.shopping_basket_rounded, 'index': 13},
      {'title': 'Attendance Approvals', 'icon': Icons.fact_check_rounded, 'index': 9},
      {'title': 'Payment Reminders', 'icon': Icons.notification_important_rounded, 'index': 14},
      {'title': 'Settings & System', 'icon': Icons.settings_suggest_rounded, 'index': 19},
    ];

    final matchedNav = navItems.where((m) {
      if (query.isEmpty) return true;
      return (m['title'] as String).toLowerCase().contains(query);
    }).take(query.isEmpty ? 5 : 8).toList();

    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 580, maxHeight: 560),
        child: Material(
          color: TekColors.cardBg,
          borderRadius: BorderRadius.circular(20),
          elevation: 24,
          child: Container(
            decoration: BoxDecoration(
              color: TekColors.cardBg,
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: TekColors.border, width: 1.5),
              boxShadow: TekColors.cardShadow,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // Search Input Header
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
                  decoration: const BoxDecoration(
                    border: Border(bottom: BorderSide(color: TekColors.border)),
                  ),
                  child: Row(
                    children: [
                      const Icon(Icons.search_rounded, color: TekColors.electricCyan, size: 22),
                      const SizedBox(width: 12),
                      Expanded(
                        child: TextField(
                          controller: _searchCtrl,
                          autofocus: true,
                          style: const TextStyle(
                            color: TekColors.textPrimary,
                            fontSize: 16,
                            fontFamilyFallback: TekTypography.malayalamFallback,
                          ),
                          decoration: const InputDecoration(
                            hintText: 'Search items, customers, invoices, or screens...',
                            hintStyle: TextStyle(color: TekColors.textMuted, fontSize: 14.5),
                            border: InputBorder.none,
                            enabledBorder: InputBorder.none,
                            focusedBorder: InputBorder.none,
                            filled: false,
                            contentPadding: EdgeInsets.zero,
                          ),
                          onChanged: (val) => setState(() => _query = val),
                        ),
                      ),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
                        decoration: BoxDecoration(
                          color: TekColors.sidebarBg,
                          borderRadius: BorderRadius.circular(6),
                          border: Border.all(color: TekColors.border),
                        ),
                        child: const Text(
                          'ESC',
                          style: TextStyle(
                            color: TekColors.textSecondary,
                            fontSize: 11,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),

                // Search Results List
                Expanded(
                  child: ListView(
                    padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 12),
                    children: [
                      // Items results
                      if (matchedItems.isNotEmpty) ...[
                        _buildSectionHeader('ITEMS & STOCK (${matchedItems.length})'),
                        for (final item in matchedItems)
                          _buildResultTile(
                            icon: Icons.inventory_2_rounded,
                            iconColor: TekColors.primaryBlue,
                            title: '${item['name'] ?? 'Item'}',
                            subtitle: 'Stock: ${item['stock'] ?? 0} | Price: ${rs(item['salePrice'] ?? 0)}',
                            onTap: () {
                              Navigator.pop(context);
                              widget.onNavigateModule?.call(2); // ItemsView
                            },
                          ),
                      ],

                      // Customers results
                      if (matchedParties.isNotEmpty) ...[
                        _buildSectionHeader('CUSTOMERS / PARTIES (${matchedParties.length})'),
                        for (final party in matchedParties)
                          _buildResultTile(
                            icon: Icons.person_rounded,
                            iconColor: TekColors.success,
                            title: '${party['name'] ?? 'Customer'}',
                            subtitle: 'Phone: ${party['phone'] ?? 'N/A'} | Balance: ${rs(party['balance'] ?? 0)}',
                            onTap: () {
                              Navigator.pop(context);
                              widget.onNavigateModule?.call(5); // PartiesView
                            },
                          ),
                      ],

                      // Invoices results
                      if (matchedSales.isNotEmpty) ...[
                        _buildSectionHeader('INVOICES (${matchedSales.length})'),
                        for (final sale in matchedSales)
                          _buildResultTile(
                            icon: Icons.receipt_long_rounded,
                            iconColor: TekColors.premiumPurple,
                            title: '${sale['invoice']} • ${sale['customerName']}',
                            subtitle: 'Total: ${rs(sale['total'] ?? 0)} | ${sale['items'] is List ? (sale['items'] as List).length : 0} items',
                            onTap: () {
                              Navigator.pop(context);
                              widget.onNavigateModule?.call(7); // ReportsView
                            },
                          ),
                      ],

                      // Quick Nav / Screens
                      _buildSectionHeader(query.isEmpty ? 'QUICK NAVIGATION' : 'MATCHING MODULES'),
                      for (final m in matchedNav)
                        _buildResultTile(
                          icon: m['icon'] as IconData,
                          iconColor: TekColors.electricCyan,
                          title: m['title'] as String,
                          subtitle: 'Jump to screen',
                          onTap: () {
                            Navigator.pop(context);
                            widget.onNavigateModule?.call(m['index'] as int);
                          },
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildSectionHeader(String title) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 12, 8, 6),
      child: Text(
        title,
        style: const TextStyle(
          color: TekColors.textMuted,
          fontSize: 10.5,
          fontWeight: FontWeight.bold,
          letterSpacing: 0.8,
        ),
      ),
    );
  }

  Widget _buildResultTile({
    required IconData icon,
    required Color iconColor,
    required String title,
    required String subtitle,
    required VoidCallback onTap,
  }) {
    return Material(
      color: Colors.transparent,
      borderRadius: BorderRadius.circular(10),
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          child: Row(
            children: [
              Container(
                padding: const EdgeInsets.all(7),
                decoration: BoxDecoration(
                  color: iconColor.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Icon(icon, size: 16, color: iconColor),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: const TextStyle(
                        color: TekColors.textPrimary,
                        fontSize: 13.5,
                        fontWeight: FontWeight.w600,
                        fontFamilyFallback: TekTypography.malayalamFallback,
                      ),
                    ),
                    Text(
                      subtitle,
                      style: const TextStyle(
                        color: TekColors.textSecondary,
                        fontSize: 11.5,
                        fontFamilyFallback: TekTypography.malayalamFallback,
                      ),
                    ),
                  ],
                ),
              ),
              const Icon(Icons.arrow_forward_ios_rounded, size: 12, color: TekColors.textMuted),
            ],
          ),
        ),
      ),
    );
  }
}
