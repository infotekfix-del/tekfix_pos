import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';
import '../main.dart' show printInvoice;
import '../pos/pos_models.dart';
import '../pos/pos_service.dart';
import '../pos/staff_pos_screen.dart';
import '../theme/tek_tokens.dart';
import 'repair_models.dart';
import 'repair_service.dart';

class StaffRepairsScreen extends StatefulWidget {
  final String shopId;
  final String staffId;
  final String staffName;

  const StaffRepairsScreen({
    super.key,
    required this.shopId,
    required this.staffId,
    required this.staffName,
  });

  @override
  State<StaffRepairsScreen> createState() => _StaffRepairsScreenState();
}

class _StaffRepairsScreenState extends State<StaffRepairsScreen> {
  final TextEditingController _searchController = TextEditingController();
  String _searchQuery = '';
  String _selectedFilter = 'Active'; // Default to Active jobs
  String _sortBy = 'newest'; // 'newest', 'delivery', 'balance'

  final List<String> _filters = [
    'Active',
    'All',
    'Ready',
    'Waiting for Parts',
    'In Progress',
    'Diagnosing',
    'Received',
    'Delivered',
  ];

  late Stream<List<RepairJob>> _repairsStream;

  @override
  void initState() {
    super.initState();
    _initStream();
  }

  void _initStream() {
    _repairsStream = RepairService.instance.streamRepairs(widget.shopId);
  }

  @override
  void didUpdateWidget(StaffRepairsScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.shopId != widget.shopId) {
      _initStream();
    }
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _makePhoneCall(String phone) async {
    final clean = phone.replaceAll(RegExp(r'[^0-9+]'), '');
    if (clean.isEmpty) return;
    final uri = Uri.parse('tel:$clean');
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri);
    }
  }

  Future<void> _sendWhatsAppMessage(RepairJob job) async {
    final clean = job.phone.replaceAll(RegExp(r'[^0-9]'), '');
    if (clean.isEmpty) return;
    final phone = clean.startsWith('91') ? clean : '91$clean';
    final text = 'നമസ്കാരം ${job.customerName},\n'
        'TEKFIX-ൽ നൽകിയ നിങ്ങളുടെ ${job.brandModel} (Job ID: ${job.id}) സർവീസ് സ്റ്റാറ്റസ്: *${job.status}*.\n'
        'ബാക്കി തുക: ₹${job.balance.toStringAsFixed(0)}.\n'
        'കൂടുതൽ വിവരങ്ങൾക്ക് വിളിക്കുക.';
    final uri = Uri.parse('https://wa.me/$phone?text=${Uri.encodeComponent(text)}');
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    }
  }

  Color _getStatusColor(String status) {
    switch (status) {
      case 'Ready':
        return TekColors.success;
      case 'Waiting for Parts':
        return TekColors.warning;
      case 'In Progress':
        return TekColors.primary;
      case 'Diagnosing':
        return TekColors.secondary;
      case 'Received':
        return TekColors.info;
      case 'Delivered':
        return const Color(0xFF0D9488); // Teal / Emerald for Delivered
      case 'Cancelled':
        return TekColors.error;
      default:
        return TekColors.primary;
    }
  }

  IconData _getProductIcon(String type) {
    final lower = type.toLowerCase();
    if (lower.contains('laptop') || lower.contains('macbook')) {
      return Icons.laptop_mac_rounded;
    } else if (lower.contains('tablet') || lower.contains('ipad')) {
      return Icons.tablet_mac_rounded;
    } else if (lower.contains('watch')) {
      return Icons.watch_rounded;
    }
    return Icons.smartphone_rounded;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: TekColors.bgMain,
      appBar: AppBar(
        backgroundColor: TekColors.bgMain,
        elevation: 0,
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Repairs & Service Jobs',
              style: TekTypography.titleMedium.copyWith(fontSize: 18),
            ),
            const Text(
              'റിപ്പയർ ജോലികൾ • Live Sync',
              style: TextStyle(
                fontSize: 11,
                color: TekColors.textSecondary,
                fontFamilyFallback: TekTypography.malayalamFallback,
              ),
            ),
          ],
        ),
        actions: [
          // Sort Menu
          PopupMenuButton<String>(
            tooltip: 'Sort Repairs',
            icon: const Icon(Icons.sort_rounded, color: TekColors.secondary),
            color: TekColors.bgCard,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(14),
              side: const BorderSide(color: TekColors.border),
            ),
            onSelected: (val) => setState(() => _sortBy = val),
            itemBuilder: (ctx) => [
              _buildPopupItem('newest', 'Newest Jobs (ഏറ്റവും പുതിയവ)'),
              _buildPopupItem('delivery', 'Expected Delivery (ഡെലിവറി തീയതി)'),
              _buildPopupItem('balance', 'Highest Balance Due (കൂടിയ ബാക്കി)'),
            ],
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: StreamBuilder<List<RepairJob>>(
        stream: _repairsStream,
        builder: (context, snapshot) {
          final allJobs = snapshot.data ?? [];

          // Compute Counts
          final activeCount = allJobs.where((j) => j.isActive).length;
          final readyCount = allJobs.where((j) => j.isReady).length;
          final waitingCount = allJobs.where((j) => j.isWaitingForParts).length;
          final overdueCount = allJobs.where((j) => j.isOverdue).length;

          // Filter Jobs
          final filteredJobs = allJobs.where((j) {
            // Tab filter
            if (_selectedFilter == 'Active' && !j.isActive) return false;
            if (_selectedFilter != 'Active' && _selectedFilter != 'All' && j.status != _selectedFilter) {
              return false;
            }

            // Search query
            if (_searchQuery.isNotEmpty) {
              final q = _searchQuery.toLowerCase();
              final matchId = j.id.toLowerCase().contains(q);
              final matchName = j.customerName.toLowerCase().contains(q);
              final matchPhone = j.phone.toLowerCase().contains(q);
              final matchModel = j.brandModel.toLowerCase().contains(q);
              final matchSerial = j.serial.toLowerCase().contains(q);
              final matchComplaint = j.complaint.toLowerCase().contains(q);
              return matchId || matchName || matchPhone || matchModel || matchSerial || matchComplaint;
            }
            return true;
          }).toList();

          // Sort Jobs
          if (_sortBy == 'newest') {
            filteredJobs.sort((a, b) => (b.createdAt ?? DateTime(0)).compareTo(a.createdAt ?? DateTime(0)));
          } else if (_sortBy == 'delivery') {
            filteredJobs.sort((a, b) => a.expectedDelivery.compareTo(b.expectedDelivery));
          } else if (_sortBy == 'balance') {
            filteredJobs.sort((a, b) => b.balance.compareTo(a.balance));
          }

          return Column(
            children: [
              // Top Metric Overview Cards
              _buildMetricsBar(
                activeCount: activeCount,
                readyCount: readyCount,
                waitingCount: waitingCount,
                overdueCount: overdueCount,
              ),

              // Search Box
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
                child: TextField(
                  controller: _searchController,
                  style: const TextStyle(color: TekColors.textPrimary, fontSize: 14),
                  onChanged: (val) => setState(() => _searchQuery = val.trim()),
                  decoration: InputDecoration(
                    hintText: 'Search Job ID, Customer, Phone, Model, IMEI...',
                    hintStyle: const TextStyle(color: TekColors.textMuted, fontSize: 13),
                    prefixIcon: const Icon(Icons.search_rounded, color: TekColors.secondary, size: 20),
                    suffixIcon: _searchQuery.isNotEmpty
                        ? IconButton(
                            icon: const Icon(Icons.clear_rounded, size: 18, color: TekColors.textSecondary),
                            onPressed: () {
                              _searchController.clear();
                              setState(() => _searchQuery = '');
                            },
                          )
                        : null,
                    filled: true,
                    fillColor: TekColors.bgSecondary,
                    contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(16),
                      borderSide: const BorderSide(color: TekColors.border),
                    ),
                    enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(16),
                      borderSide: const BorderSide(color: TekColors.border),
                    ),
                    focusedBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(16),
                      borderSide: const BorderSide(color: TekColors.primary, width: 1.5),
                    ),
                  ),
                ),
              ),

              // Horizontal Filter Chips
              SizedBox(
                height: 44,
                child: ListView.separated(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  itemCount: _filters.length,
                  separatorBuilder: (_, __) => const SizedBox(width: 8),
                  itemBuilder: (ctx, idx) {
                    final f = _filters[idx];
                    final isSelected = _selectedFilter == f;
                    return ChoiceChip(
                      label: Text(
                        f,
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: isSelected ? FontWeight.bold : FontWeight.w500,
                          color: isSelected ? Colors.white : TekColors.textSecondary,
                        ),
                      ),
                      selected: isSelected,
                      selectedColor: TekColors.primary,
                      backgroundColor: TekColors.bgSecondary,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                        side: BorderSide(
                          color: isSelected ? TekColors.primary : TekColors.border,
                        ),
                      ),
                      onSelected: (val) {
                        if (val) {
                          HapticFeedback.selectionClick();
                          setState(() => _selectedFilter = f);
                        }
                      },
                    );
                  },
                ),
              ),

              const SizedBox(height: 8),

              // Repair Job List
              Expanded(
                child: snapshot.connectionState == ConnectionState.waiting && allJobs.isEmpty
                    ? const Center(
                        child: CircularProgressIndicator(color: TekColors.primary),
                      )
                    : filteredJobs.isEmpty
                        ? _buildEmptyState()
                        : ListView.separated(
                            cacheExtent: 300,
                            padding: const EdgeInsets.fromLTRB(16, 6, 16, 85),
                            physics: const BouncingScrollPhysics(),
                            itemCount: filteredJobs.length,
                            separatorBuilder: (_, __) => const SizedBox(height: 12),
                            itemBuilder: (context, index) {
                              final job = filteredJobs[index];
                              return _buildRepairCard(job);
                            },
                          ),
              ),
            ],
          );
        },
      ),
    );
  }

  PopupMenuItem<String> _buildPopupItem(String value, String text) {
    final isSelected = _sortBy == value;
    return PopupMenuItem(
      value: value,
      child: Row(
        children: [
          Icon(
            isSelected ? Icons.check_circle_rounded : Icons.radio_button_unchecked_rounded,
            size: 16,
            color: isSelected ? TekColors.secondary : TekColors.textMuted,
          ),
          const SizedBox(width: 10),
          Text(
            text,
            style: TextStyle(
              fontSize: 12.5,
              fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
              color: isSelected ? TekColors.textPrimary : TekColors.textSecondary,
              fontFamilyFallback: TekTypography.malayalamFallback,
            ),
          ),
        ],
      ),
    );
  }

  // 1. Metric Overview Bar
  Widget _buildMetricsBar({
    required int activeCount,
    required int readyCount,
    required int waitingCount,
    required int overdueCount,
  }) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
      child: Row(
        children: [
          Expanded(
            child: _buildMetricTile(
              label: 'Active',
              count: '$activeCount',
              color: TekColors.primary,
              icon: Icons.handyman_rounded,
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: _buildMetricTile(
              label: 'Waiting Parts',
              count: '$waitingCount',
              color: TekColors.warning,
              icon: Icons.inventory_2_rounded,
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: _buildMetricTile(
              label: 'Ready',
              count: '$readyCount',
              color: TekColors.success,
              icon: Icons.check_circle_rounded,
            ),
          ),
          if (overdueCount > 0) ...[
            const SizedBox(width: 8),
            Expanded(
              child: _buildMetricTile(
                label: 'Overdue',
                count: '$overdueCount',
                color: TekColors.error,
                icon: Icons.alarm_rounded,
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildMetricTile({
    required String label,
    required String count,
    required Color color,
    required IconData icon,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 10),
      decoration: BoxDecoration(
        color: TekColors.bgSecondary,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: color.withValues(alpha: 0.3)),
      ),
      child: Column(
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon, size: 14, color: color),
              const SizedBox(width: 4),
              Text(
                count,
                style: TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.bold,
                  color: color,
                ),
              ),
            ],
          ),
          const SizedBox(height: 2),
          Text(
            label,
            style: const TextStyle(fontSize: 10, color: TekColors.textSecondary),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ],
      ),
    );
  }

  // 2. Comprehensive Repair Job Card
  Widget _buildRepairCard(RepairJob job) {
    final statusColor = _getStatusColor(job.status);
    final productIcon = _getProductIcon(job.productType);

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: TekColors.bgCard,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color: job.isReady
              ? TekColors.success.withValues(alpha: 0.6)
              : (job.isOverdue ? TekColors.error.withValues(alpha: 0.5) : TekColors.border),
          width: job.isReady || job.isOverdue ? 1.5 : 1.1,
        ),
        boxShadow: TekColors.cardShadow,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Top Row: Job ID badge, Status pill, and Copy action
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(7),
                    decoration: BoxDecoration(
                      gradient: TekColors.primaryGradient,
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Icon(productIcon, size: 18, color: Colors.white),
                  ),
                  const SizedBox(width: 10),
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Text(
                            job.id,
                            style: const TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.bold,
                              color: TekColors.textPrimary,
                              letterSpacing: 0.5,
                            ),
                          ),
                          const SizedBox(width: 4),
                          GestureDetector(
                            onTap: () {
                              Clipboard.setData(ClipboardData(text: job.id));
                              HapticFeedback.lightImpact();
                              ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(
                                  content: Text('Job ID copied to clipboard'),
                                  duration: Duration(seconds: 1),
                                  behavior: SnackBarBehavior.floating,
                                ),
                              );
                            },
                            child: const Icon(Icons.copy_rounded, size: 14, color: TekColors.textMuted),
                          ),
                        ],
                      ),
                      Text(
                        '${job.productType}${job.formattedCreatedAt.isNotEmpty ? ' • ${job.formattedCreatedAt}' : ''}',
                        style: const TextStyle(fontSize: 10.5, color: TekColors.textSecondary),
                      ),
                    ],
                  ),
                ],
              ),

              // Status Pill with Glowing Dot
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(
                  color: statusColor.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: statusColor.withValues(alpha: 0.5)),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      width: 7,
                      height: 7,
                      decoration: BoxDecoration(
                        color: statusColor,
                        shape: BoxShape.circle,
                        boxShadow: [
                          BoxShadow(
                            color: statusColor.withValues(alpha: 0.8),
                            blurRadius: 4,
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 6),
                    Text(
                      job.status,
                      style: TextStyle(
                        fontSize: 11.5,
                        fontWeight: FontWeight.bold,
                        color: statusColor,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),

          const SizedBox(height: 12),

          // Customer details & Device Model
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      job.customerName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.bold,
                        color: TekColors.textPrimary,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      job.brandModel,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 12.5,
                        fontWeight: FontWeight.w600,
                        color: TekColors.secondary,
                      ),
                    ),
                    if (job.serial.isNotEmpty) ...[
                      const SizedBox(height: 2),
                      Text(
                        'IMEI / Serial: ${job.serial}',
                        style: const TextStyle(fontSize: 10.5, color: TekColors.textMuted),
                      ),
                    ],
                  ],
                ),
              ),

              // Call & WhatsApp quick action circle buttons
              Row(
                children: [
                  IconButton(
                    tooltip: 'Call Customer',
                    icon: const Icon(Icons.phone_rounded, color: TekColors.info, size: 20),
                    style: IconButton.styleFrom(
                      backgroundColor: TekColors.info.withValues(alpha: 0.12),
                      shape: const CircleBorder(),
                    ),
                    onPressed: () => _makePhoneCall(job.phone),
                  ),
                  const SizedBox(width: 4),
                  IconButton(
                    tooltip: 'WhatsApp Update',
                    icon: const Icon(Icons.chat_bubble_rounded, color: Color(0xFF22C55E), size: 19),
                    style: IconButton.styleFrom(
                      backgroundColor: const Color(0xFF22C55E).withValues(alpha: 0.12),
                      shape: const CircleBorder(),
                    ),
                    onPressed: () => _sendWhatsAppMessage(job),
                  ),
                ],
              ),
            ],
          ),

          const SizedBox(height: 12),

          // Reported Problem (Complaint) Box
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: TekColors.bgSecondary,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: TekColors.border),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Icon(Icons.report_problem_rounded, size: 16, color: TekColors.warning),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'Reported Problem (തകരാർ):',
                        style: TextStyle(
                          fontSize: 10.5,
                          fontWeight: FontWeight.bold,
                          color: TekColors.textSecondary,
                          fontFamilyFallback: TekTypography.malayalamFallback,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        job.complaint.isNotEmpty ? job.complaint : 'No specific problem reported',
                        style: const TextStyle(
                          fontSize: 12,
                          color: TekColors.textPrimary,
                          height: 1.3,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),

          const SizedBox(height: 12),

          // Financial Summary Row: Estimated Cost, Advance, Balance Due
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(
              color: TekColors.bgSecondary.withValues(alpha: 0.6),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: TekColors.border),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                _buildAmountColumn('Estimated Cost', '₹${job.estimatedCost.toStringAsFixed(0)}', TekColors.textPrimary),
                Container(width: 1, height: 26, color: TekColors.border),
                _buildAmountColumn('Advance Paid', '₹${job.advance.toStringAsFixed(0)}', TekColors.info),
                Container(width: 1, height: 26, color: TekColors.border),
                _buildAmountColumn(
                  'Balance Due',
                  '₹${job.balance.toStringAsFixed(0)}',
                  job.balance > 0 ? TekColors.warning : TekColors.success,
                  isBold: true,
                ),
              ],
            ),
          ),

          const SizedBox(height: 10),

          // Delivery Date & Technician Row
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              // Delivery date pill
              Row(
                children: [
                  Icon(
                    job.isOverdue ? Icons.error_outline_rounded : Icons.event_available_rounded,
                    size: 14,
                    color: job.isOverdue ? TekColors.error : TekColors.textSecondary,
                  ),
                  const SizedBox(width: 6),
                  Text(
                    job.expectedDelivery.isNotEmpty
                        ? 'Delivery: ${job.expectedDelivery}'
                        : 'No delivery date set',
                    style: TextStyle(
                      fontSize: 11.5,
                      fontWeight: job.isOverdue ? FontWeight.bold : FontWeight.normal,
                      color: job.isOverdue ? TekColors.error : TekColors.textSecondary,
                    ),
                  ),
                  if (job.isOverdue) ...[
                    const SizedBox(width: 6),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1.5),
                      decoration: BoxDecoration(
                        color: TekColors.error.withValues(alpha: 0.2),
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: const Text(
                        'OVERDUE',
                        style: TextStyle(fontSize: 8.5, fontWeight: FontWeight.bold, color: TekColors.error),
                      ),
                    ),
                  ],
                ],
              ),

              // Technician label
              if (job.technician.isNotEmpty)
                Text(
                  'Tech: ${job.technician}',
                  style: const TextStyle(fontSize: 11, color: TekColors.textMuted),
                ),
            ],
          ),

          // Technician Notes Preview (if any)
          if (job.notes.isNotEmpty) ...[
            const SizedBox(height: 8),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Icon(Icons.sticky_note_2_rounded, size: 14, color: TekColors.secondary),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    'Notes: ${job.notes}',
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 11, color: TekColors.textSecondary, fontStyle: FontStyle.italic),
                  ),
                ),
              ],
            ),
          ],

          const SizedBox(height: 14),

          // Premium Inline Actions: Sale to Customer & Update Status
          LayoutBuilder(
            builder: (context, constraints) {
              final isBilled = _isJobBilled(job);
              final isWide = constraints.maxWidth >= 380;

              final saleOrInvoiceBtn = isBilled
                  ? OutlinedButton.icon(
                      style: OutlinedButton.styleFrom(
                        side: const BorderSide(color: Color(0xFF0D9488), width: 1.5),
                        backgroundColor: const Color(0xFF0D9488).withValues(alpha: 0.1),
                        foregroundColor: const Color(0xFF0D9488),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
                        minimumSize: const Size(0, 44),
                      ),
                      onPressed: () => _showInvoiceDetails(job),
                      icon: const Icon(Icons.receipt_rounded, size: 18),
                      label: Text(
                        'View Invoice${job.invoice != null ? " (#${job.invoice})" : ""}',
                        style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
                        overflow: TextOverflow.ellipsis,
                      ),
                    )
                  : ElevatedButton.icon(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: TekColors.primary,
                        foregroundColor: Colors.white,
                        elevation: 2,
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
                        minimumSize: const Size(0, 44),
                      ),
                      onPressed: () => _openServiceCheckout(job),
                      icon: const Icon(Icons.shopping_cart_rounded, size: 18, color: Colors.white),
                      label: const Text(
                        'Sale to Customer',
                        style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13, color: Colors.white),
                        overflow: TextOverflow.ellipsis,
                      ),
                    );

              final statusBtn = OutlinedButton.icon(
                style: OutlinedButton.styleFrom(
                  side: const BorderSide(color: TekColors.secondary, width: 1.3),
                  foregroundColor: TekColors.secondary,
                  backgroundColor: TekColors.secondary.withValues(alpha: 0.08),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
                  minimumSize: const Size(0, 44),
                ),
                onPressed: () => _showCompactStatusUpdateSheet(job),
                icon: const Icon(Icons.sync_alt_rounded, size: 18),
                label: const Text(
                  'Update Status',
                  style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
                  overflow: TextOverflow.ellipsis,
                ),
              );

              if (isWide) {
                return Row(
                  children: [
                    Expanded(flex: 3, child: saleOrInvoiceBtn),
                    const SizedBox(width: 10),
                    Expanded(flex: 2, child: statusBtn),
                  ],
                );
              } else {
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    saleOrInvoiceBtn,
                    const SizedBox(height: 8),
                    statusBtn,
                  ],
                );
              }
            },
          ),
        ],
      ),
    );
  }

  bool _isJobBilled(RepairJob job) {
    if (job.billCreated || (job.invoice != null && job.invoice!.isNotEmpty)) {
      return true;
    }
    return PosService.instance.isJobBilled(job.id);
  }

  Future<void> _openServiceCheckout(RepairJob job) async {
    final serviceChargeCtrl = TextEditingController(
      text: job.estimatedCost > 0 ? job.estimatedCost.toStringAsFixed(0) : '0',
    );
    final discountCtrl = TextEditingController(text: '0');
    final List<PosCartItem> extraItems = [];
    String paymentMode = 'Cash';
    bool isSubmitting = false;
    String? localError;

    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheet) {
          final serviceCharge = double.tryParse(serviceChargeCtrl.text) ?? 0.0;
          final extraSubtotal = extraItems.fold(0.0, (sum, i) => sum + i.lineTotal);
          final discount = double.tryParse(discountCtrl.text) ?? 0.0;
          final grossTotal = (serviceCharge + extraSubtotal - discount).clamp(0.0, double.infinity);
          final advanceApplied = (job.advance > 0)
              ? (grossTotal < job.advance ? grossTotal : job.advance)
              : 0.0;
          final netBalanceDue = (grossTotal - advanceApplied).clamp(0.0, double.infinity);

          return Container(
            padding: EdgeInsets.only(
              bottom: MediaQuery.of(ctx).viewInsets.bottom + 20,
              top: 20,
              left: 20,
              right: 20,
            ),
            decoration: const BoxDecoration(
              color: TekColors.bgCard,
              borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
              border: Border(top: BorderSide(color: TekColors.border, width: 1.5)),
            ),
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Center(
                    child: Container(
                      width: 44,
                      height: 4,
                      decoration: BoxDecoration(
                        color: TekColors.border,
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'Sale to Customer • Job #${job.id}',
                              style: TekTypography.titleMedium.copyWith(fontSize: 18),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              '${job.customerName} (${job.phone}) • ${job.brandModel}',
                              style: const TextStyle(color: TekColors.textSecondary, fontSize: 13),
                            ),
                          ],
                        ),
                      ),
                      IconButton(
                        icon: const Icon(Icons.close_rounded, color: TekColors.textSecondary),
                        onPressed: () => Navigator.pop(ctx),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),

                  // Service charge line item
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: TekColors.bgSecondary,
                      borderRadius: BorderRadius.circular(14),
                      border: Border.all(color: TekColors.border),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            const Icon(Icons.build_circle_rounded, color: TekColors.primary, size: 20),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                'Service: ${job.brandModel} (#${job.id})',
                                style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13.5, color: TekColors.textPrimary),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 10),
                        Row(
                          children: [
                            const Text('Service Charge ₹', style: TextStyle(color: TekColors.textSecondary, fontSize: 13)),
                            const SizedBox(width: 12),
                            Expanded(
                              child: TextField(
                                controller: serviceChargeCtrl,
                                keyboardType: TextInputType.number,
                                style: const TextStyle(fontWeight: FontWeight.bold, color: TekColors.textPrimary),
                                decoration: InputDecoration(
                                  isDense: true,
                                  contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: const BorderSide(color: TekColors.border)),
                                  filled: true,
                                  fillColor: TekColors.bgCard,
                                ),
                                onChanged: (_) => setSheet(() {}),
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 12),

                  // Extra accessories / parts list
                  if (extraItems.isNotEmpty) ...[
                    const Text('Additional Products / Accessories:', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12.5, color: TekColors.textSecondary)),
                    const SizedBox(height: 6),
                    ...extraItems.map((item) => Container(
                      margin: const EdgeInsets.only(bottom: 6),
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                      decoration: BoxDecoration(
                        color: TekColors.bgSecondary,
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(color: TekColors.border),
                      ),
                      child: Row(
                        children: [
                          Expanded(
                            child: Text(
                              '${item.item.name} (x${item.qty})',
                              style: const TextStyle(fontSize: 12.5, color: TekColors.textPrimary),
                            ),
                          ),
                          Text('₹${item.lineTotal.toStringAsFixed(0)}', style: const TextStyle(fontWeight: FontWeight.bold, color: TekColors.secondary)),
                          const SizedBox(width: 8),
                          GestureDetector(
                            onTap: () {
                              setSheet(() => extraItems.remove(item));
                            },
                            child: const Icon(Icons.remove_circle_outline_rounded, size: 18, color: TekColors.error),
                          ),
                        ],
                      ),
                    )),
                    const SizedBox(height: 6),
                  ],

                  // Add Products button
                  OutlinedButton.icon(
                    style: OutlinedButton.styleFrom(
                      side: const BorderSide(color: TekColors.secondary),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                      padding: const EdgeInsets.symmetric(vertical: 10),
                    ),
                    onPressed: () async {
                      final catalog = PosService.instance.getCatalogItems();
                      final PosItem? picked = await showDialog<PosItem>(
                        context: context,
                        builder: (dCtx) => _ProductPickerDialog(items: catalog),
                      );
                      if (picked != null) {
                        setSheet(() {
                          final existing = extraItems.indexWhere((e) => e.item.id == picked.id);
                          if (existing >= 0) {
                            extraItems[existing].qty++;
                          } else {
                            extraItems.add(PosCartItem(
                              item: picked,
                              qty: 1,
                              unitPrice: picked.sellingPrice,
                            ));
                          }
                        });
                      }
                    },
                    icon: const Icon(Icons.add_shopping_cart_rounded, size: 16, color: TekColors.secondary),
                    label: const Text('+ Add Products / Accessories / Parts', style: TextStyle(color: TekColors.secondary, fontSize: 12.5)),
                  ),
                  const SizedBox(height: 14),

                  // Advance paid banner if any
                  if (job.advance > 0) ...[
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                      decoration: BoxDecoration(
                        color: TekColors.info.withValues(alpha: 0.12),
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(color: TekColors.info.withValues(alpha: 0.4)),
                      ),
                      child: Row(
                        children: [
                          const Icon(Icons.check_circle_outline_rounded, color: TekColors.info, size: 18),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              'Advance Paid: ₹${job.advance.toStringAsFixed(0)} (Automatically deducted from bill)',
                              style: const TextStyle(color: TekColors.info, fontWeight: FontWeight.w600, fontSize: 12),
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 12),
                  ],

                  // Summary breakdown
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: TekColors.bgSecondary,
                      borderRadius: BorderRadius.circular(14),
                      border: Border.all(color: TekColors.border),
                    ),
                    child: Column(
                      children: [
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            const Text('Gross Total:', style: TextStyle(color: TekColors.textSecondary, fontSize: 12.5)),
                            Text('₹${grossTotal.toStringAsFixed(2)}', style: const TextStyle(color: TekColors.textPrimary, fontWeight: FontWeight.w600)),
                          ],
                        ),
                        if (advanceApplied > 0) ...[
                          const SizedBox(height: 4),
                          Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              const Text('Advance Credited:', style: TextStyle(color: TekColors.info, fontSize: 12.5)),
                              Text('-₹${advanceApplied.toStringAsFixed(2)}', style: const TextStyle(color: TekColors.info, fontWeight: FontWeight.bold)),
                            ],
                          ),
                        ],
                        const Divider(height: 16, color: TekColors.border),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            const Text('Balance Due to Collect:', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14, color: TekColors.textPrimary)),
                            Text('₹${netBalanceDue.toStringAsFixed(2)}', style: const TextStyle(fontWeight: FontWeight.bold, color: TekColors.success, fontSize: 17)),
                          ],
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 14),

                  // Payment mode selector
                  const Text('Payment Mode (പണം അടയ്ക്കുന്ന രീതി):', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12.5, color: TekColors.textPrimary)),
                  const SizedBox(height: 6),
                  SegmentedButton<String>(
                    segments: const [
                      ButtonSegment(value: 'Cash', label: Text('Cash')),
                      ButtonSegment(value: 'UPI', label: Text('UPI')),
                      ButtonSegment(value: 'Card', label: Text('Card')),
                    ],
                    selected: {paymentMode},
                    onSelectionChanged: (v) => setSheet(() => paymentMode = v.first),
                  ),
                  const SizedBox(height: 16),

                  if (localError != null) ...[
                    Text(localError!, style: const TextStyle(color: TekColors.error, fontSize: 12)),
                    const SizedBox(height: 10),
                  ],

                  // Complete Sale button
                  GestureDetector(
                    onTap: isSubmitting
                        ? null
                        : () async {
                            HapticFeedback.heavyImpact();
                            setSheet(() => isSubmitting = true);
                            try {
                              // Verify double billing
                              if (_isJobBilled(job)) {
                                throw Exception('ഈ Job-ന് ബിൽ ഇതിനകം സൃഷ്ടിച്ചിട്ടുണ്ട് (Already billed).');
                              }

                              final cart = <PosCartItem>[
                                PosCartItem(
                                  item: PosItem(
                                    id: 'service_${job.id}',
                                    name: 'Service: ${job.brandModel} (#${job.id})',
                                    category: 'Services',
                                    sellingPrice: serviceCharge,
                                    minPrice: 0.0,
                                    stock: 9999,
                                  ),
                                  qty: 1,
                                  unitPrice: serviceCharge,
                                ),
                                ...extraItems,
                              ];

                              final payment = PosPayment(
                                mode: paymentMode,
                                totalAmount: netBalanceDue,
                                cashAmount: paymentMode == 'Cash' ? netBalanceDue : 0.0,
                                upiAmount: paymentMode == 'UPI' ? netBalanceDue : 0.0,
                                cardAmount: paymentMode == 'Card' ? netBalanceDue : 0.0,
                                cashReceived: netBalanceDue,
                                changeDue: 0.0,
                              );

                              final invoice = await PosService.instance.completeSale(
                                shopId: widget.shopId,
                                staffId: widget.staffId,
                                staffName: widget.staffName,
                                cartItems: cart,
                                payment: payment,
                                subtotal: serviceCharge + extraSubtotal,
                                discount: discount,
                                total: grossTotal,
                                customerName: job.customerName,
                                customerPhone: job.phone,
                                serviceJobId: job.id,
                                serviceJobKey: job.key,
                                serviceAdvanceApplied: advanceApplied,
                              );

                              if (!mounted) return;
                              if (ctx.mounted) Navigator.pop(ctx);

                              // Show success dialog with Print & WhatsApp
                              _showPostSaleSuccessDialog(invoice, job);
                            } catch (e) {
                              setSheet(() {
                                isSubmitting = false;
                                localError = 'Billing failed: $e';
                              });
                            }
                          },
                    child: Container(
                      height: 48,
                      decoration: BoxDecoration(
                        gradient: isSubmitting ? null : TekColors.primaryGradient,
                        color: isSubmitting ? Colors.grey : null,
                        borderRadius: BorderRadius.circular(14),
                        boxShadow: TekColors.primaryGlow,
                      ),
                      child: Center(
                        child: isSubmitting
                            ? const SizedBox(width: 22, height: 22, child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2))
                            : const Row(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  Icon(Icons.receipt_long_rounded, color: Colors.white, size: 18),
                                  SizedBox(width: 8),
                                  Text(
                                    'Complete Sale & Generate Invoice',
                                    style: TextStyle(fontWeight: FontWeight.bold, color: Colors.white, fontSize: 14),
                                  ),
                                ],
                              ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 8),

                  // Or Open in Full POS
                  TextButton.icon(
                    onPressed: () {
                      Navigator.pop(ctx);
                      Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (_) => StaffPosScreen(
                            shopId: widget.shopId,
                            staffId: widget.staffId,
                            staffName: widget.staffName,
                            onNavigateToAttendance: () => Navigator.pop(context),
                            serviceJob: job,
                          ),
                        ),
                      );
                    },
                    icon: const Icon(Icons.open_in_new_rounded, size: 16, color: TekColors.secondary),
                    label: const Text('Open in Full Store POS Screen', style: TextStyle(color: TekColors.secondary, fontSize: 13)),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  void _showPostSaleSuccessDialog(PosInvoice invoice, RepairJob job) {
    showDialog(
      context: context,
      builder: (dCtx) => AlertDialog(
        backgroundColor: TekColors.bgCard,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20), side: const BorderSide(color: TekColors.border)),
        icon: const Icon(Icons.check_circle_rounded, color: TekColors.success, size: 48),
        title: const Text('Invoice Generated Successfully', style: TextStyle(color: TekColors.textPrimary, fontWeight: FontWeight.bold)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Invoice: #${invoice.invoiceId}', style: const TextStyle(fontWeight: FontWeight.bold, color: TekColors.secondary)),
            const SizedBox(height: 4),
            Text('Customer: ${job.customerName}', style: const TextStyle(color: TekColors.textPrimary)),
            Text('Device: ${job.brandModel}', style: const TextStyle(color: TekColors.textSecondary, fontSize: 13)),
            const SizedBox(height: 6),
            Text('Total Billed: ₹${invoice.total.toStringAsFixed(2)}', style: const TextStyle(fontWeight: FontWeight.bold, color: TekColors.success)),
          ],
        ),
        actions: [
          OutlinedButton.icon(
            style: OutlinedButton.styleFrom(side: const BorderSide(color: Color(0xFF22C55E))),
            onPressed: () {
              final text = 'നമസ്കാരം ${job.customerName},\n'
                  'TEKFIX സർവീസ് ഇൻവോയ്സ് (#${invoice.invoiceId}):\n'
                  'ഡിവൈസ്: ${job.brandModel}\n'
                  'ആകെ തുക: ₹${invoice.total.toStringAsFixed(2)}\n'
                  'നന്ദി!';
              final clean = job.phone.replaceAll(RegExp(r'[^0-9]'), '');
              final phone = clean.startsWith('91') ? clean : '91$clean';
              launchUrl(Uri.parse('https://wa.me/$phone?text=${Uri.encodeComponent(text)}'), mode: LaunchMode.externalApplication);
            },
            icon: const Icon(Icons.chat_bubble_rounded, size: 16, color: Color(0xFF22C55E)),
            label: const Text('WhatsApp Receipt', style: TextStyle(color: Color(0xFF22C55E))),
          ),
          FilledButton.icon(
            style: FilledButton.styleFrom(backgroundColor: TekColors.primary),
            onPressed: () async {
              Navigator.pop(dCtx);
              final sale = PosService.instance.getLinkedSale(invoice.invoiceId, job.id);
              if (sale != null) {
                await printInvoice(context, sale, a4: true);
              }
            },
            icon: const Icon(Icons.print_rounded, size: 16),
            label: const Text('Print Invoice'),
          ),
        ],
      ),
    );
  }

  Future<void> _showInvoiceDetails(RepairJob job) async {
    final sale = PosService.instance.getLinkedSale(job.invoice, job.id);
    final invId = job.invoice ?? sale?['invoice'] ?? 'N/A';
    final items = (sale?['items'] as List?) ?? [];
    final totalVal = sale != null ? (sale['total'] ?? job.finalAmount) : (job.finalAmount > 0 ? job.finalAmount : job.estimatedCost);
    final double total = (totalVal is num) ? totalVal.toDouble() : 0.0;
    final cash = sale != null ? (sale['cash'] ?? 0.0) : 0.0;
    final upi = sale != null ? (sale['upi'] ?? 0.0) : 0.0;
    final card = sale != null ? (sale['card'] ?? 0.0) : 0.0;
    final pMode = (cash as num) > 0 ? 'Cash' : ((upi as num) > 0 ? 'UPI' : ((card as num) > 0 ? 'Card' : 'Paid'));

    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => Container(
        padding: const EdgeInsets.all(20),
        decoration: const BoxDecoration(
          color: TekColors.bgCard,
          borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
          border: Border(top: BorderSide(color: TekColors.border, width: 1.5)),
        ),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Center(
                child: Container(
                  width: 44,
                  height: 4,
                  decoration: BoxDecoration(color: TekColors.border, borderRadius: BorderRadius.circular(2)),
                ),
              ),
              const SizedBox(height: 16),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.all(8),
                        decoration: BoxDecoration(
                          color: TekColors.success.withValues(alpha: 0.15),
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: const Icon(Icons.check_circle_rounded, color: TekColors.success, size: 22),
                      ),
                      const SizedBox(width: 10),
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('Invoice #$invId', style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 17, color: TekColors.textPrimary)),
                          Text('Linked to Job #${job.id}', style: const TextStyle(fontSize: 12, color: TekColors.textSecondary)),
                        ],
                      ),
                    ],
                  ),
                  IconButton(
                    icon: const Icon(Icons.close_rounded, color: TekColors.textSecondary),
                    onPressed: () => Navigator.pop(ctx),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: TekColors.bgSecondary,
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(color: TekColors.border),
                ),
                child: Column(
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        const Text('Customer:', style: TextStyle(color: TekColors.textSecondary, fontSize: 12.5)),
                        Text('${job.customerName} (${job.phone})', style: const TextStyle(fontWeight: FontWeight.bold, color: TekColors.textPrimary)),
                      ],
                    ),
                    const SizedBox(height: 6),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        const Text('Device Model:', style: TextStyle(color: TekColors.textSecondary, fontSize: 12.5)),
                        Text(job.brandModel, style: const TextStyle(fontWeight: FontWeight.w600, color: TekColors.secondary)),
                      ],
                    ),
                    const SizedBox(height: 6),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        const Text('Payment Mode:', style: TextStyle(color: TekColors.textSecondary, fontSize: 12.5)),
                        Text(pMode, style: const TextStyle(fontWeight: FontWeight.bold, color: TekColors.success)),
                      ],
                    ),
                    const Divider(height: 16, color: TekColors.border),
                    if (items.isNotEmpty) ...[
                      ...items.map((it) => Padding(
                        padding: const EdgeInsets.symmetric(vertical: 2),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Text('${it['name']} (x${it['qty'] ?? 1})', style: const TextStyle(fontSize: 12, color: TekColors.textPrimary)),
                            Text('₹${it['price'] ?? it['lineTotal'] ?? 0}', style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: TekColors.textPrimary)),
                          ],
                        ),
                      )),
                      const Divider(height: 16, color: TekColors.border),
                    ],
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        const Text('Total Paid:', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14, color: TekColors.textPrimary)),
                        Text('₹${total.toStringAsFixed(2)}', style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16, color: TekColors.success)),
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      style: OutlinedButton.styleFrom(
                        side: const BorderSide(color: Color(0xFF22C55E)),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                        padding: const EdgeInsets.symmetric(vertical: 12),
                      ),
                      onPressed: () {
                        final text = 'നമസ്കാരം ${job.customerName},\n'
                            'TEKFIX സർവീസ് ഇൻവോയ്സ് (#$invId):\n'
                            'ഡിവൈസ്: ${job.brandModel}\n'
                            'ആകെ തുക: ₹${total.toStringAsFixed(2)} (PAID)\n'
                            'നന്ദി!';
                        final clean = job.phone.replaceAll(RegExp(r'[^0-9]'), '');
                        final phone = clean.startsWith('91') ? clean : '91$clean';
                        launchUrl(Uri.parse('https://wa.me/$phone?text=${Uri.encodeComponent(text)}'), mode: LaunchMode.externalApplication);
                      },
                      icon: const Icon(Icons.chat_bubble_rounded, size: 16, color: Color(0xFF22C55E)),
                      label: const Text('WhatsApp Receipt', style: TextStyle(color: Color(0xFF22C55E), fontSize: 12.5)),
                    ),
                  ),
                  if (sale != null) ...[
                    const SizedBox(width: 10),
                    Expanded(
                      child: FilledButton.icon(
                        style: FilledButton.styleFrom(
                          backgroundColor: TekColors.primary,
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                          padding: const EdgeInsets.symmetric(vertical: 12),
                        ),
                        onPressed: () async {
                          await printInvoice(context, sale, a4: true);
                        },
                        icon: const Icon(Icons.print_rounded, size: 16),
                        label: const Text('Print Invoice', style: TextStyle(fontSize: 12.5)),
                      ),
                    ),
                  ],
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _showCompactStatusUpdateSheet(RepairJob job) async {
    String selectedStatus = job.status;
    final notesController = TextEditingController(text: job.notes);
    String? localError;
    bool isSaving = false;

    final statuses = [
      'Received',
      'Diagnosing',
      'In Progress',
      'Waiting for Parts',
      'Ready',
      'Delivered',
      'Cancelled',
    ];

    try {
      await showModalBottomSheet(
        context: context,
        isScrollControlled: true,
        backgroundColor: Colors.transparent,
        builder: (ctx) => StatefulBuilder(
          builder: (ctx, setSheet) {
            return Container(
              padding: EdgeInsets.only(
                bottom: MediaQuery.of(ctx).viewInsets.bottom + 20,
                top: 20,
                left: 20,
                right: 20,
              ),
              decoration: const BoxDecoration(
                color: TekColors.bgCard,
                borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
                border: Border(top: BorderSide(color: TekColors.border, width: 1.5)),
              ),
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Center(
                      child: Container(
                        width: 44,
                        height: 4,
                        decoration: BoxDecoration(color: TekColors.border, borderRadius: BorderRadius.circular(2)),
                      ),
                    ),
                    const SizedBox(height: 16),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text('Update Job Status • #${job.id}', style: TekTypography.titleMedium.copyWith(fontSize: 18)),
                              const SizedBox(height: 2),
                              Text('${job.customerName} • ${job.brandModel}', style: const TextStyle(color: TekColors.textSecondary, fontSize: 13)),
                            ],
                          ),
                        ),
                        IconButton(
                          icon: const Icon(Icons.close_rounded, color: TekColors.textSecondary),
                          onPressed: () => Navigator.pop(ctx),
                        ),
                      ],
                    ),
                    const SizedBox(height: 14),

                    // Current status indicator
                    Row(
                      children: [
                        const Text('Current Status: ', style: TextStyle(color: TekColors.textSecondary, fontSize: 12.5)),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                          decoration: BoxDecoration(
                            color: _getStatusColor(job.status).withValues(alpha: 0.15),
                            borderRadius: BorderRadius.circular(8),
                            border: Border.all(color: _getStatusColor(job.status).withValues(alpha: 0.4)),
                          ),
                          child: Text(
                            job.status,
                            style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12, color: _getStatusColor(job.status)),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 14),

                    // Status Choices
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: statuses.map((st) {
                        final isSel = selectedStatus == st;
                        final col = _getStatusColor(st);
                        return ChoiceChip(
                          label: Text(
                            st,
                            style: TextStyle(
                              fontSize: 12,
                              fontWeight: isSel ? FontWeight.bold : FontWeight.w500,
                              color: isSel ? Colors.white : TekColors.textPrimary,
                            ),
                          ),
                          selected: isSel,
                          selectedColor: col,
                          backgroundColor: TekColors.bgSecondary,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(10),
                            side: BorderSide(color: isSel ? col : TekColors.border),
                          ),
                          onSelected: (val) {
                            if (val) {
                              HapticFeedback.selectionClick();
                              setSheet(() => selectedStatus = st);
                            }
                          },
                        );
                      }).toList(),
                    ),
                    const SizedBox(height: 16),

                    // Technician Notes
                    const Text('Technician Notes (ഓപ്ഷണൽ കുറിപ്പുകൾ):', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12.5, color: TekColors.textPrimary)),
                    const SizedBox(height: 6),
                    TextField(
                      controller: notesController,
                      maxLines: 2,
                      style: const TextStyle(color: TekColors.textPrimary, fontSize: 13.5),
                      decoration: InputDecoration(
                        hintText: 'ഉദാ: സ്ക്രീൻ മാറ്റി, ടെസ്റ്റിംഗ് പൂർത്തിയായി...',
                        hintStyle: const TextStyle(color: TekColors.textMuted, fontSize: 12.5),
                        filled: true,
                        fillColor: TekColors.bgSecondary,
                        border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: TekColors.border)),
                      ),
                    ),
                    const SizedBox(height: 14),

                    if (localError != null) ...[
                      Text(localError!, style: const TextStyle(color: TekColors.error, fontSize: 12)),
                      const SizedBox(height: 8),
                    ],

                    // Save Button
                    GestureDetector(
                      onTap: isSaving
                          ? null
                          : () async {
                              HapticFeedback.heavyImpact();
                              setSheet(() => isSaving = true);
                              try {
                                await RepairService.instance.updateRepairStatusAndNotes(
                                  shopId: widget.shopId,
                                  jobId: job.id,
                                  hiveKey: job.key,
                                  newStatus: selectedStatus,
                                  notes: notesController.text,
                                  staffName: widget.staffName,
                                  staffId: widget.staffId,
                                );

                                if (!mounted) return;
                                if (ctx.mounted) Navigator.pop(ctx);
                                ScaffoldMessenger.of(context).showSnackBar(
                                  SnackBar(
                                    content: Text('Job #${job.id} updated to "$selectedStatus" (Synced)'),
                                    backgroundColor: TekColors.success,
                                    behavior: SnackBarBehavior.floating,
                                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                                  ),
                                );
                              } catch (e) {
                                setSheet(() {
                                  isSaving = false;
                                  localError = 'Update failed: $e';
                                });
                              }
                            },
                      child: Container(
                        height: 48,
                        decoration: BoxDecoration(
                          gradient: isSaving ? null : TekColors.primaryGradient,
                          color: isSaving ? Colors.grey : null,
                          borderRadius: BorderRadius.circular(14),
                          boxShadow: TekColors.primaryGlow,
                        ),
                        child: Center(
                          child: isSaving
                              ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2))
                              : const Row(
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  children: [
                                    Icon(Icons.check_rounded, color: Colors.white, size: 18),
                                    SizedBox(width: 8),
                                    Text('Save Status Update', style: TextStyle(fontWeight: FontWeight.bold, color: Colors.white, fontSize: 14)),
                                  ],
                                ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        ),
      );
    } finally {
      notesController.dispose();
    }
  }

  Widget _buildAmountColumn(String label, String value, Color color, {bool isBold = false}) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Text(
          label,
          style: const TextStyle(fontSize: 10, color: TekColors.textMuted),
        ),
        const SizedBox(height: 2),
        Text(
          value,
          style: TextStyle(
            fontSize: 13,
            fontWeight: isBold ? FontWeight.bold : FontWeight.w600,
            color: color,
          ),
        ),
      ],
    );
  }

  Widget _buildEmptyState() {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            padding: const EdgeInsets.all(18),
            decoration: BoxDecoration(
              color: TekColors.bgSecondary,
              shape: BoxShape.circle,
              border: Border.all(color: TekColors.border),
            ),
            child: const Icon(Icons.build_circle_outlined, size: 44, color: TekColors.textMuted),
          ),
          const SizedBox(height: 14),
          const Text(
            'റിപ്പയർ ജോലികൾ ഒന്നും കണ്ടെത്തിയില്ല',
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.bold,
              color: TekColors.textPrimary,
              fontFamilyFallback: TekTypography.malayalamFallback,
            ),
          ),
          const SizedBox(height: 4),
          const Text(
            'No matching repair service jobs in this filter',
            style: TextStyle(fontSize: 12, color: TekColors.textSecondary),
          ),
        ],
      ),
    );
  }
}

class _ProductPickerDialog extends StatefulWidget {
  final List<PosItem> items;

  const _ProductPickerDialog({required this.items});

  @override
  State<_ProductPickerDialog> createState() => _ProductPickerDialogState();
}

class _ProductPickerDialogState extends State<_ProductPickerDialog> {
  String _query = '';

  @override
  Widget build(BuildContext context) {
    final filtered = widget.items.where((item) {
      if (_query.isEmpty) return true;
      final q = _query.toLowerCase();
      return item.name.toLowerCase().contains(q) ||
          item.category.toLowerCase().contains(q) ||
          item.barcode.toLowerCase().contains(q);
    }).toList();

    return Dialog(
      backgroundColor: TekColors.bgCard,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(20),
        side: const BorderSide(color: TekColors.border),
      ),
      child: Container(
        padding: const EdgeInsets.all(16),
        constraints: const BoxConstraints(maxHeight: 520, maxWidth: 420),
        child: Column(
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text(
                  'Select Product / Accessory',
                  style: TextStyle(
                    fontWeight: FontWeight.bold,
                    fontSize: 16,
                    color: TekColors.textPrimary,
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.close_rounded, color: TekColors.textSecondary),
                  onPressed: () => Navigator.pop(context),
                ),
              ],
            ),
            const SizedBox(height: 10),
            TextField(
              style: const TextStyle(color: TekColors.textPrimary, fontSize: 13),
              decoration: InputDecoration(
                hintText: 'Search items, tempered glass, cables...',
                hintStyle: const TextStyle(color: TekColors.textMuted, fontSize: 12),
                prefixIcon: const Icon(Icons.search_rounded, color: TekColors.secondary, size: 18),
                isDense: true,
                filled: true,
                fillColor: TekColors.bgSecondary,
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: TekColors.border)),
              ),
              onChanged: (v) => setState(() => _query = v.trim()),
            ),
            const SizedBox(height: 12),
            Expanded(
              child: filtered.isEmpty
                  ? const Center(
                      child: Text('No matching items found', style: TextStyle(color: TekColors.textMuted, fontSize: 12)),
                    )
                  : ListView.separated(
                      itemCount: filtered.length,
                      separatorBuilder: (_, __) => const Divider(height: 1, color: TekColors.border),
                      itemBuilder: (ctx, idx) {
                        final item = filtered[idx];
                        return ListTile(
                          contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                          title: Text(
                            item.name,
                            style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13, color: TekColors.textPrimary),
                          ),
                          subtitle: Text(
                            'Stock: ${item.stock} • ${item.category}',
                            style: TextStyle(
                              fontSize: 11,
                              color: item.stock <= 0 ? TekColors.error : TekColors.textSecondary,
                            ),
                          ),
                          trailing: Text(
                            '₹${item.sellingPrice.toStringAsFixed(0)}',
                            style: const TextStyle(fontWeight: FontWeight.bold, color: TekColors.secondary, fontSize: 13),
                          ),
                          onTap: () {
                            Navigator.pop(context, item);
                          },
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }
}
