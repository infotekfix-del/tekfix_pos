import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';
import 'package:hive_flutter/hive_flutter.dart';
import '../auth/auth_controller.dart';
import '../main.dart' show boxReturns, toast;
import '../ui/dashboard/dashboard_tokens.dart';
import 'return_models.dart';
import 'return_service.dart';
import 'customer_returns_screen.dart';
import 'return_details_screen.dart';

/// Main Hub & Owner/Staff Dashboard for Customer Returns, Warranty & Vendor Tracking.
/// Features 10 KPI summary cards, multi-field search, filters, follow-up alerts,
/// and live database reactivity.
class ReturnsDashboardView extends StatefulWidget {
  const ReturnsDashboardView({super.key});

  @override
  State<ReturnsDashboardView> createState() => _ReturnsDashboardViewState();
}

class _ReturnsDashboardViewState extends State<ReturnsDashboardView> {
  final _searchCtrl = TextEditingController();
  final _shortDateFormat = DateFormat('dd MMM yyyy');

  String _searchQuery = '';
  String? _selectedCardFilter;
  String _selectedVendor = 'All Vendors';
  String _selectedReturnStatus = 'All Statuses';
  String _selectedVendorStatus = 'All Vendor Statuses';
  DateTime? _startDate;
  DateTime? _endDate;

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  void _resetFilters() {
    setState(() {
      _searchCtrl.clear();
      _searchQuery = '';
      _selectedCardFilter = null;
      _selectedVendor = 'All Vendors';
      _selectedReturnStatus = 'All Statuses';
      _selectedVendorStatus = 'All Vendor Statuses';
      _startDate = null;
      _endDate = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthController>();
    final isOwner = auth.isOwner;

    return ValueListenableBuilder(
      valueListenable: Hive.box(boxReturns).listenable(),
      builder: (context, Box box, _) {
        final metrics = ReturnService.instance.computeDashboardMetrics();
        final thresholdDays = ReturnService.instance.getFollowupThresholdDays();

        final returns = ReturnService.instance.searchAndFilter(
          query: _searchQuery,
          vendorFilter: _selectedVendor,
          returnStatusFilter: _selectedReturnStatus,
          vendorStatusFilter: _selectedVendorStatus,
          startDate: _startDate,
          endDate: _endDate,
          cardFilterCategory: _selectedCardFilter,
        );

        // Collect unique vendors for dropdown
        final allReturns = ReturnService.instance.getAllReturns();
        final vendorsSet = <String>{'All Vendors'};
        for (final r in allReturns) {
          if (r.originalVendorName != null && r.originalVendorName!.isNotEmpty) {
            vendorsSet.add(r.originalVendorName!);
          }
          if (r.handoverRecord?.vendorName.isNotEmpty == true) {
            vendorsSet.add(r.handoverRecord!.vendorName);
          }
        }

        return Container(
          decoration: const BoxDecoration(
            gradient: DashboardColors.backgroundGradient,
          ),
          child: Column(
            children: [
              // Top Header Bar
              _buildHeaderBar(isOwner, thresholdDays),

              // Scrollable Dashboard Body
              Expanded(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.all(20),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // 10 KPI Dashboard Cards
                      _buildKpiCardsGrid(metrics),

                      const SizedBox(height: 20),

                      // Search & Filter Toolbar
                      _buildSearchAndFilterToolbar(vendorsSet.toList()),

                      const SizedBox(height: 16),

                      // Active Filter Indicator (if any)
                      if (_selectedCardFilter != null ||
                          _selectedVendor != 'All Vendors' ||
                          _selectedReturnStatus != 'All Statuses' ||
                          _selectedVendorStatus != 'All Vendor Statuses' ||
                          _searchQuery.isNotEmpty) ...[
                        _buildActiveFiltersBar(returns.length),
                        const SizedBox(height: 14),
                      ],

                      // Returns Table / List View
                      _buildReturnsTable(returns, thresholdDays),
                    ],
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  // ---------------------------------------------------------------------------
  // HEADER BAR
  // ---------------------------------------------------------------------------

  Widget _buildHeaderBar(bool isOwner, int thresholdDays) {
    return Container(
      padding: const EdgeInsets.fromLTRB(24, 18, 24, 18),
      decoration: const BoxDecoration(
        color: Color(0xFF0C1236),
        border: Border(bottom: BorderSide(color: Color(0x14FFFFFF))),
      ),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              gradient: DashboardColors.activePillGradient,
              borderRadius: BorderRadius.circular(12),
            ),
            child: const Icon(Icons.assignment_return_rounded, color: Colors.white, size: 22),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Customer Return, Warranty & Vendor Tracking',
                  style: DashboardTypography.poppins(
                    fontSize: 18,
                    fontWeight: FontWeight.w700,
                    color: Colors.white,
                  ),
                ),
                Text(
                  'End-to-end lifecycle tracking: Customer return ➔ Warranty check ➔ Vendor handover ➔ Repair/Replacement ➔ Customer delivery',
                  style: DashboardTypography.inter(
                    fontSize: 12,
                    color: DashboardColors.textMuted,
                  ),
                ),
              ],
            ),
          ),
          if (isOwner) ...[
            OutlinedButton.icon(
              style: OutlinedButton.styleFrom(
                foregroundColor: DashboardColors.neonOrange,
                side: const BorderSide(color: DashboardColors.neonOrange),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
              ),
              onPressed: () => _showFollowupSettingsDialog(thresholdDays),
              icon: const Icon(Icons.settings_suggest_rounded, size: 18),
              label: Text(
                'Follow-up: ${thresholdDays}d',
                style: DashboardTypography.inter(fontSize: 12, fontWeight: FontWeight.bold),
              ),
            ),
            const SizedBox(width: 12),
          ],
          FilledButton.icon(
            style: FilledButton.styleFrom(
              backgroundColor: DashboardColors.primaryBlue,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 13),
              elevation: 4,
            ),
            onPressed: () {
              Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const CustomerReturnsScreen()),
              );
            },
            icon: const Icon(Icons.add_rounded, size: 20),
            label: Text(
              'New Customer Return',
              style: DashboardTypography.poppins(
                fontSize: 13,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // 10 KPI DASHBOARD CARDS (REQUIREMENT 13)
  // ---------------------------------------------------------------------------

  Widget _buildKpiCardsGrid(Map<String, int> metrics) {
    final kpis = [
      ('Total Customer Returns', metrics['Total Customer Returns'] ?? 0, Icons.assignment_return_rounded, DashboardColors.neonBlue),
      ('Pending Inspection', metrics['Pending Inspection'] ?? 0, Icons.search_rounded, DashboardColors.neonOrange),
      ('Handed Over to Vendors', metrics['Handed Over to Vendors'] ?? 0, Icons.local_shipping_rounded, const Color(0xFF38BDF8)),
      ('Awaiting Vendor Confirmation', metrics['Awaiting Vendor Confirmation'] ?? 0, Icons.pending_actions_rounded, const Color(0xFF06B6D4)),
      ('Under Repair at Vendor', metrics['Under Repair at Vendor'] ?? 0, Icons.build_circle_rounded, const Color(0xFFEAB308)),
      ('Replacement Awaited', metrics['Replacement Awaited'] ?? 0, Icons.published_with_changes_rounded, DashboardColors.neonPurple),
      ('Vendor Follow-up Required', metrics['Vendor Follow-up Required'] ?? 0, Icons.warning_amber_rounded, DashboardColors.neonPink),
      ('Received from Vendor', metrics['Received from Vendor'] ?? 0, Icons.store_rounded, const Color(0xFF14B8A6)),
      ('Ready for Customer', metrics['Ready for Customer'] ?? 0, Icons.task_alt_rounded, DashboardColors.neonGreen),
      ('Completed Returns', metrics['Completed Returns'] ?? 0, Icons.check_circle_rounded, const Color(0xFF22C55E)),
    ];

    return LayoutBuilder(
      builder: (context, constraints) {
        final isWide = constraints.maxWidth >= 1100;
        final isMedium = constraints.maxWidth >= 700;
        final count = isWide ? 5 : (isMedium ? 3 : 2);

        return GridView.builder(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: count,
            mainAxisExtent: 104,
            crossAxisSpacing: 12,
            mainAxisSpacing: 12,
          ),
          itemCount: kpis.length,
          itemBuilder: (context, idx) {
            final (title, value, icon, color) = kpis[idx];
            final isSelected = _selectedCardFilter == title;

            return InkWell(
              onTap: () {
                setState(() {
                  _selectedCardFilter = isSelected ? null : title;
                });
              },
              borderRadius: BorderRadius.circular(16),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 200),
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                decoration: DashboardColors.glassCard(
                  radius: 16,
                  borderColor: isSelected ? color : null,
                  borderWidth: isSelected ? 2 : 1,
                  glow: isSelected || (title == 'Vendor Follow-up Required' && value > 0),
                  glowColor: color,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Expanded(
                          child: Text(
                            title,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: DashboardTypography.inter(
                              fontSize: 11,
                              fontWeight: isSelected ? FontWeight.bold : FontWeight.w500,
                              color: isSelected ? color : DashboardColors.textLight,
                            ),
                          ),
                        ),
                        Icon(icon, color: color, size: 18),
                      ],
                    ),
                    Row(
                      children: [
                        Text(
                          '$value',
                          style: DashboardTypography.poppins(
                            fontSize: 22,
                            fontWeight: FontWeight.w800,
                            color: Colors.white,
                          ),
                        ),
                        if (isSelected) ...[
                          const SizedBox(width: 6),
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                            decoration: BoxDecoration(
                              color: color.withValues(alpha: 0.2),
                              borderRadius: BorderRadius.circular(4),
                            ),
                            child: Text(
                              'Filtered',
                              style: DashboardTypography.inter(fontSize: 9, fontWeight: FontWeight.bold, color: color),
                            ),
                          ),
                        ],
                      ],
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }

  // ---------------------------------------------------------------------------
  // SEARCH & FILTER TOOLBAR (REQUIREMENT 15)
  // ---------------------------------------------------------------------------

  Widget _buildSearchAndFilterToolbar(List<String> vendors) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: DashboardColors.glassCard(radius: 16),
      child: Column(
        children: [
          Row(
            children: [
              // Multi-field search
              Expanded(
                flex: 4,
                child: Container(
                  height: 44,
                  decoration: BoxDecoration(
                    color: const Color(0x26000000),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: const Color(0x33FFFFFF)),
                  ),
                  child: TextField(
                    controller: _searchCtrl,
                    style: DashboardTypography.inter(color: Colors.white, fontSize: 13.5),
                    decoration: InputDecoration(
                      hintText: 'Search by Return ID, Customer, Phone, Product, IMEI, Invoice, Vendor...',
                      hintStyle: DashboardTypography.inter(color: DashboardColors.textMuted, fontSize: 12),
                      prefixIcon: const Icon(Icons.search_rounded, color: DashboardColors.neonBlue, size: 18),
                      suffixIcon: _searchCtrl.text.isNotEmpty
                          ? IconButton(
                              icon: const Icon(Icons.clear_rounded, color: DashboardColors.textMuted, size: 16),
                              onPressed: () {
                                _searchCtrl.clear();
                                setState(() => _searchQuery = '');
                              },
                            )
                          : null,
                      border: InputBorder.none,
                      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                    ),
                    onChanged: (val) => setState(() => _searchQuery = val),
                  ),
                ),
              ),

              const SizedBox(width: 12),

              // Vendor Dropdown
              Expanded(
                flex: 2,
                child: _buildFilterDropdown(
                  value: _selectedVendor,
                  items: vendors,
                  onChanged: (val) => setState(() => _selectedVendor = val ?? 'All Vendors'),
                ),
              ),

              const SizedBox(width: 12),

              // Return Status Dropdown
              Expanded(
                flex: 2,
                child: _buildFilterDropdown(
                  value: _selectedReturnStatus,
                  items: ['All Statuses', ...CustomerReturnStatus.all],
                  onChanged: (val) => setState(() => _selectedReturnStatus = val ?? 'All Statuses'),
                ),
              ),

              const SizedBox(width: 12),

              // Vendor Status Dropdown
              Expanded(
                flex: 2,
                child: _buildFilterDropdown(
                  value: _selectedVendorStatus,
                  items: ['All Vendor Statuses', ...VendorStatus.all],
                  onChanged: (val) => setState(() => _selectedVendorStatus = val ?? 'All Vendor Statuses'),
                ),
              ),

              const SizedBox(width: 12),

              // Date Range Filter Button
              OutlinedButton.icon(
                style: OutlinedButton.styleFrom(
                  foregroundColor: _startDate != null ? DashboardColors.neonBlue : DashboardColors.textLight,
                  side: BorderSide(
                    color: _startDate != null ? DashboardColors.neonBlue : const Color(0x33FFFFFF),
                  ),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                ),
                onPressed: _pickDateRange,
                icon: const Icon(Icons.calendar_today_rounded, size: 16),
                label: Text(
                  _startDate != null
                      ? '${_shortDateFormat.format(_startDate!)} - ${_shortDateFormat.format(_endDate!)}'
                      : 'Date Range',
                  style: DashboardTypography.inter(fontSize: 12),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildFilterDropdown({
    required String value,
    required List<String> items,
    required ValueChanged<String?> onChanged,
  }) {
    return Container(
      height: 44,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: BoxDecoration(
        color: const Color(0x26000000),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0x33FFFFFF)),
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<String>(
          isExpanded: true,
          dropdownColor: const Color(0xFF1E293B),
          value: items.contains(value) ? value : items.first,
          items: items.map((i) {
            return DropdownMenuItem(
              value: i,
              child: Text(
                i,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: DashboardTypography.inter(color: Colors.white, fontSize: 12.5),
              ),
            );
          }).toList(),
          onChanged: onChanged,
        ),
      ),
    );
  }

  Future<void> _pickDateRange() async {
    final picked = await showDateRangePicker(
      context: context,
      firstDate: DateTime(2020),
      lastDate: DateTime.now().add(const Duration(days: 30)),
      initialDateRange: _startDate != null && _endDate != null
          ? DateTimeRange(start: _startDate!, end: _endDate!)
          : null,
      builder: (context, child) => Theme(
        data: ThemeData.dark().copyWith(
          colorScheme: const ColorScheme.dark(
            primary: DashboardColors.primaryBlue,
            onPrimary: Colors.white,
            surface: Color(0xFF0F172A),
            onSurface: Colors.white,
          ),
        ),
        child: child!,
      ),
    );

    if (picked != null) {
      setState(() {
        _startDate = picked.start;
        _endDate = picked.end;
      });
    }
  }

  Widget _buildActiveFiltersBar(int matchCount) {
    return Row(
      children: [
        Text(
          'Matching Records: $matchCount',
          style: DashboardTypography.inter(fontSize: 12.5, fontWeight: FontWeight.bold, color: Colors.white),
        ),
        const SizedBox(width: 12),
        if (_selectedCardFilter != null)
          _buildActiveChip('Card: $_selectedCardFilter', () => setState(() => _selectedCardFilter = null)),
        if (_selectedVendor != 'All Vendors')
          _buildActiveChip('Vendor: $_selectedVendor', () => setState(() => _selectedVendor = 'All Vendors')),
        if (_selectedReturnStatus != 'All Statuses')
          _buildActiveChip('Status: $_selectedReturnStatus', () => setState(() => _selectedReturnStatus = 'All Statuses')),
        if (_selectedVendorStatus != 'All Vendor Statuses')
          _buildActiveChip('Vendor Status: $_selectedVendorStatus', () => setState(() => _selectedVendorStatus = 'All Vendor Statuses')),
        if (_startDate != null)
          _buildActiveChip('Date: ${_shortDateFormat.format(_startDate!)}', () => setState(() {
                _startDate = null;
                _endDate = null;
              })),
        const Spacer(),
        TextButton(
          onPressed: _resetFilters,
          child: Text('Reset Filters', style: DashboardTypography.inter(fontSize: 12, color: DashboardColors.neonPink)),
        ),
      ],
    );
  }

  Widget _buildActiveChip(String label, VoidCallback onRemove) {
    return Container(
      margin: const EdgeInsets.only(right: 8),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: DashboardColors.primaryBlue.withValues(alpha: 0.2),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: DashboardColors.primaryBlue.withValues(alpha: 0.5)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(label, style: DashboardTypography.inter(fontSize: 11, color: Colors.white)),
          const SizedBox(width: 4),
          InkWell(
            onTap: onRemove,
            child: const Icon(Icons.close_rounded, size: 14, color: Colors.white70),
          ),
        ],
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // RETURNS TABLE & ROWS
  // ---------------------------------------------------------------------------

  Widget _buildReturnsTable(List<CustomerReturn> returns, int thresholdDays) {
    if (returns.isEmpty) {
      return Container(
        width: double.infinity,
        padding: const EdgeInsets.all(48),
        decoration: DashboardColors.glassCard(),
        child: Column(
          children: [
            const Icon(Icons.inbox_rounded, size: 54, color: DashboardColors.textMuted),
            const SizedBox(height: 16),
            Text(
              'No Return Records Found',
              style: DashboardTypography.poppins(fontSize: 16, fontWeight: FontWeight.bold, color: Colors.white),
            ),
            const SizedBox(height: 6),
            Text(
              'No customer returns match the current search filters or database is empty.',
              style: DashboardTypography.inter(fontSize: 13, color: DashboardColors.textMuted),
            ),
          ],
        ),
      );
    }

    return Container(
      decoration: DashboardColors.glassCard(radius: 16),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(16),
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: DataTable(
            horizontalMargin: 20,
            columnSpacing: 22,
            headingRowHeight: 48,
            dataRowMaxHeight: 64,
            headingRowColor: WidgetStateProperty.all(const Color(0xFF0C1236)),
            columns: [
              DataColumn(label: Text('RETURN ID', style: _tableHeaderStyle)),
              DataColumn(label: Text('CUSTOMER', style: _tableHeaderStyle)),
              DataColumn(label: Text('PRODUCT', style: _tableHeaderStyle)),
              DataColumn(label: Text('INVOICE / DATE', style: _tableHeaderStyle)),
              DataColumn(label: Text('RETURN STATUS', style: _tableHeaderStyle)),
              DataColumn(label: Text('WARRANTY', style: _tableHeaderStyle)),
              DataColumn(label: Text('VENDOR STATUS', style: _tableHeaderStyle)),
              DataColumn(label: Text('DAYS PENDING', style: _tableHeaderStyle)),
              DataColumn(label: Text('ACTION', style: _tableHeaderStyle)),
            ],
            rows: returns.map((r) {
              final isOverdue = r.isFollowUpOverdue(thresholdDays);
              final retColor = CustomerReturnStatus.getColor(r.customerReturnStatus);
              final warColor = CustomerWarrantyStatus.getColor(r.customerWarrantyStatus);
              final venColor = VendorStatus.getColor(r.vendorStatus);

              return DataRow(
                color: WidgetStateProperty.resolveWith((states) {
                  if (states.contains(WidgetState.hovered)) {
                    return const Color(0x2B273A6E);
                  }
                  return const Color(0x0AFFFFFF);
                }),
                cells: [
                  // Return ID
                  DataCell(
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                      decoration: BoxDecoration(
                        gradient: DashboardColors.activePillGradient,
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Text(
                        r.returnId,
                        style: DashboardTypography.poppins(fontSize: 12, fontWeight: FontWeight.bold, color: Colors.white),
                      ),
                    ),
                  ),

                  // Customer
                  DataCell(
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Text(r.customerName, style: DashboardTypography.inter(fontSize: 13, fontWeight: FontWeight.w600, color: Colors.white)),
                        Text(r.customerPhone, style: DashboardTypography.inter(fontSize: 11, color: DashboardColors.textMuted)),
                      ],
                    ),
                  ),

                  // Product
                  DataCell(
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Text(r.productName, maxLines: 1, overflow: TextOverflow.ellipsis, style: DashboardTypography.inter(fontSize: 13, fontWeight: FontWeight.w600, color: Colors.white)),
                        Text('IMEI: ${r.serialNumber?.isNotEmpty == true ? r.serialNumber : "N/A"}', style: DashboardTypography.inter(fontSize: 11, color: DashboardColors.neonBlue)),
                      ],
                    ),
                  ),

                  // Invoice / Date
                  DataCell(
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Text(r.originalInvoiceNumber, style: DashboardTypography.inter(fontSize: 12, color: Colors.white)),
                        Text(_shortDateFormat.format(r.createdAt), style: DashboardTypography.inter(fontSize: 11, color: DashboardColors.textMuted)),
                      ],
                    ),
                  ),

                  // Return Status
                  DataCell(
                    _buildTableBadge(r.customerReturnStatus, retColor),
                  ),

                  // Warranty Status
                  DataCell(
                    _buildTableBadge(r.customerWarrantyStatus, warColor),
                  ),

                  // Vendor Status
                  DataCell(
                    _buildTableBadge(r.vendorStatus, venColor),
                  ),

                  // Days Pending
                  DataCell(
                    r.isPendingWithVendor
                        ? Container(
                            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                            decoration: BoxDecoration(
                              color: isOverdue ? DashboardColors.neonPink.withValues(alpha: 0.2) : const Color(0x1AFFFFFF),
                              borderRadius: BorderRadius.circular(6),
                              border: Border.all(
                                color: isOverdue ? DashboardColors.neonPink : const Color(0x33FFFFFF),
                              ),
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                if (isOverdue) ...[
                                  const Icon(Icons.warning_amber_rounded, size: 12, color: DashboardColors.neonPink),
                                  const SizedBox(width: 4),
                                ],
                                Text(
                                  '${r.daysPendingWithVendor} days',
                                  style: DashboardTypography.inter(
                                    fontSize: 11,
                                    fontWeight: FontWeight.bold,
                                    color: isOverdue ? DashboardColors.neonPink : Colors.white70,
                                  ),
                                ),
                              ],
                            ),
                          )
                        : Text('—', style: DashboardTypography.inter(color: DashboardColors.textMuted)),
                  ),

                  // Action
                  DataCell(
                    FilledButton(
                      style: FilledButton.styleFrom(
                        backgroundColor: DashboardColors.primaryBlue,
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                      ),
                      onPressed: () {
                        Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (_) => ReturnDetailsScreen(returnKey: r.key),
                          ),
                        );
                      },
                      child: Text('View Case', style: DashboardTypography.inter(fontSize: 11.5, fontWeight: FontWeight.bold)),
                    ),
                  ),
                ],
              );
            }).toList(),
          ),
        ),
      ),
    );
  }

  Widget _buildTableBadge(String text, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: color.withValues(alpha: 0.5)),
      ),
      child: Text(
        text,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: DashboardTypography.inter(
          fontSize: 11,
          fontWeight: FontWeight.w700,
          color: color,
        ),
      ),
    );
  }

  TextStyle get _tableHeaderStyle => DashboardTypography.poppins(
        fontSize: 11.5,
        fontWeight: FontWeight.w700,
        color: DashboardColors.textLight,
        letterSpacing: 0.5,
      );

  // ---------------------------------------------------------------------------
  // OWNER FOLLOW-UP SETTINGS MODAL (REQUIREMENT 8 & 14)
  // ---------------------------------------------------------------------------

  void _showFollowupSettingsDialog(int currentDays) {
    final daysCtrl = TextEditingController(text: '$currentDays');
    bool saving = false;

    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setD) => AlertDialog(
          backgroundColor: const Color(0xFF0F172A),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
          title: Row(
            children: [
              const Icon(Icons.settings_suggest_rounded, color: DashboardColors.neonOrange),
              const SizedBox(width: 10),
              Text(
                'Vendor Follow-up Alert Settings',
                style: DashboardTypography.poppins(fontSize: 16, fontWeight: FontWeight.bold, color: Colors.white),
              ),
            ],
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Configure the reminder threshold in days. If a product remains pending with a vendor longer than this duration, an automated "Vendor Follow-up Required" alert is triggered.',
                style: DashboardTypography.inter(fontSize: 12, color: DashboardColors.textMuted, height: 1.4),
              ),
              const SizedBox(height: 18),
              Text(
                'Overdue Threshold (Days)',
                style: DashboardTypography.inter(fontSize: 12, fontWeight: FontWeight.w600, color: DashboardColors.textLight),
              ),
              const SizedBox(height: 6),
              TextField(
                controller: daysCtrl,
                keyboardType: TextInputType.number,
                style: const TextStyle(color: Colors.white),
                decoration: InputDecoration(
                  filled: true,
                  fillColor: const Color(0x26000000),
                  contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                  suffixText: 'Days',
                  suffixStyle: const TextStyle(color: Colors.white70),
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: saving ? null : () => Navigator.pop(ctx),
              child: Text('Cancel', style: DashboardTypography.inter(color: Colors.white70)),
            ),
            FilledButton(
              style: FilledButton.styleFrom(backgroundColor: DashboardColors.neonOrange),
              onPressed: saving
                  ? null
                  : () async {
                      final val = int.tryParse(daysCtrl.text.trim());
                      if (val == null || val <= 0) {
                        toast(context, 'Please enter a valid number of days (e.g. 7)', error: true);
                        return;
                      }

                      setD(() => saving = true);
                      await ReturnService.instance.setFollowupThresholdDays(val);
                      if (ctx.mounted) Navigator.pop(ctx);
                      if (mounted) {
                        toast(context, 'Vendor Follow-up threshold updated to $val days');
                      }
                    },
              child: saving
                  ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2))
                  : Text('Save Setting', style: DashboardTypography.inter(fontWeight: FontWeight.bold)),
            ),
          ],
        ),
      ),
    );
  }
}
