import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:url_launcher/url_launcher.dart';
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
  bool _isUpdating = false;

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

  Future<void> _showUpdateModal(RepairJob job) async {
    String selectedStatus = job.status;
    final notesController = TextEditingController(text: job.notes);
    String? localError;

    final statuses = [
      'Received',
      'Diagnosing',
      'Waiting for Parts',
      'In Progress',
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
        builder: (ctx, setModalState) {
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
                  // Drag handle
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

                  // Header
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'Update Repair Job #${job.id}',
                              style: TekTypography.titleMedium.copyWith(fontSize: 18),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              '${job.customerName} • ${job.brandModel}',
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
                  const SizedBox(height: 18),

                  // Status Selector Dropdown
                  const Text(
                    'Repair Status (സ്റ്റാറ്റസ് തിരഞ്ഞെടുക്കുക)',
                    style: TextStyle(
                      color: TekColors.textPrimary,
                      fontWeight: FontWeight.bold,
                      fontSize: 13,
                      fontFamilyFallback: TekTypography.malayalamFallback,
                    ),
                  ),
                  const SizedBox(height: 8),

                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: statuses.map((st) {
                      final isSelected = selectedStatus == st;
                      final col = _getStatusColor(st);
                      return ChoiceChip(
                        label: Text(
                          st,
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: isSelected ? FontWeight.bold : FontWeight.w500,
                            color: isSelected ? Colors.white : TekColors.textSecondary,
                          ),
                        ),
                        selected: isSelected,
                        selectedColor: col,
                        backgroundColor: TekColors.bgSecondary,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(10),
                          side: BorderSide(
                            color: isSelected ? col : TekColors.border,
                          ),
                        ),
                        onSelected: (val) {
                          if (val) {
                            HapticFeedback.selectionClick();
                            setModalState(() => selectedStatus = st);
                          }
                        },
                      );
                    }).toList(),
                  ),

                  const SizedBox(height: 18),

                  // Technician Notes Input
                  const Text(
                    'Technician Notes (സർവീസ് വിവരങ്ങൾ / കുറിപ്പുകൾ)',
                    style: TextStyle(
                      color: TekColors.textPrimary,
                      fontWeight: FontWeight.bold,
                      fontSize: 13,
                      fontFamilyFallback: TekTypography.malayalamFallback,
                    ),
                  ),
                  const SizedBox(height: 8),

                  TextField(
                    controller: notesController,
                    maxLines: 3,
                    style: const TextStyle(color: TekColors.textPrimary, fontSize: 14),
                    decoration: InputDecoration(
                      hintText: 'ഉദാ: സ്ക്രീൻ മാറ്റി, ബാറ്ററി ചെക്ക് ചെയ്തു, ടെസ്റ്റിംഗ് കഴിഞ്ഞു...',
                      hintStyle: const TextStyle(
                        color: TekColors.textMuted,
                        fontSize: 13,
                        fontFamilyFallback: TekTypography.malayalamFallback,
                      ),
                      filled: true,
                      fillColor: TekColors.bgSecondary,
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(14),
                        borderSide: const BorderSide(color: TekColors.border),
                      ),
                      enabledBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(14),
                        borderSide: const BorderSide(color: TekColors.border),
                      ),
                      focusedBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(14),
                        borderSide: const BorderSide(color: TekColors.primary, width: 1.5),
                      ),
                    ),
                  ),

                  if (localError != null) ...[
                    const SizedBox(height: 10),
                    Text(
                      localError!,
                      style: const TextStyle(color: TekColors.error, fontSize: 12),
                    ),
                  ],

                  // Status History Preview
                  if (job.statusHistory.isNotEmpty) ...[
                    const SizedBox(height: 16),
                    const Text(
                      'Recent Status History (മുൻകാല മാറ്റങ്ങൾ)',
                      style: TextStyle(
                        color: TekColors.textSecondary,
                        fontSize: 12,
                        fontWeight: FontWeight.bold,
                        fontFamilyFallback: TekTypography.malayalamFallback,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Container(
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: TekColors.bgSecondary,
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: TekColors.border),
                      ),
                      child: Column(
                        children: job.statusHistory.reversed.take(3).map((h) {
                          final hDate = h['date'] != null
                              ? DateTime.tryParse('${h['date']}')
                              : null;
                          final dateStr = hDate != null
                              ? DateFormat('dd MMM, hh:mm a').format(hDate)
                              : '';
                          return Padding(
                            padding: const EdgeInsets.symmetric(vertical: 3),
                            child: Row(
                              children: [
                                const Icon(Icons.circle, size: 6, color: TekColors.secondary),
                                const SizedBox(width: 6),
                                Text(
                                  '${h['status']}',
                                  style: const TextStyle(
                                    fontSize: 11,
                                    fontWeight: FontWeight.bold,
                                    color: TekColors.textPrimary,
                                  ),
                                ),
                                const SizedBox(width: 6),
                                Expanded(
                                  child: Text(
                                    'by ${h['user'] ?? "Staff"}',
                                    style: const TextStyle(fontSize: 10, color: TekColors.textMuted),
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                                Text(
                                  dateStr,
                                  style: const TextStyle(fontSize: 10, color: TekColors.textSecondary),
                                ),
                              ],
                            ),
                          );
                        }).toList(),
                      ),
                    ),
                  ],

                  const SizedBox(height: 20),

                  // Confirm Update Button
                  GestureDetector(
                    onTap: _isUpdating
                        ? null
                        : () async {
                            HapticFeedback.heavyImpact();
                            setModalState(() => _isUpdating = true);
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
                                  content: Text(
                                    'Job #${job.id} updated to "$selectedStatus" (Synced with Owner database)',
                                  ),
                                  backgroundColor: TekColors.success,
                                  behavior: SnackBarBehavior.floating,
                                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                                ),
                              );
                            } catch (e) {
                              setModalState(() {
                                _isUpdating = false;
                                localError = 'Update failed: $e';
                              });
                            }
                          },
                    child: Container(
                      height: 52,
                      decoration: BoxDecoration(
                        gradient: TekColors.primaryGradient,
                        borderRadius: BorderRadius.circular(16),
                        boxShadow: TekColors.primaryGlow,
                      ),
                      child: Center(
                        child: _isUpdating
                            ? const SizedBox(
                                width: 22,
                                height: 22,
                                child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2),
                              )
                            : const Text(
                                'Save & Sync with Owner (മാറ്റങ്ങൾ സേവ് ചെയ്യുക)',
                                style: TextStyle(
                                  fontSize: 14,
                                  fontWeight: FontWeight.bold,
                                  color: Colors.white,
                                  fontFamilyFallback: TekTypography.malayalamFallback,
                                ),
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
        return const Color(0xFF64748B);
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
                        job.productType,
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

          // Primary Action: Update Status & Notes Button
          GestureDetector(
            onTap: () => _showUpdateModal(job),
            child: Container(
              height: 42,
              decoration: BoxDecoration(
                gradient: TekColors.primaryGradient,
                borderRadius: BorderRadius.circular(12),
                boxShadow: TekColors.primaryGlow,
              ),
              child: const Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.edit_note_rounded, size: 18, color: Colors.white),
                  SizedBox(width: 8),
                  Text(
                    'Update Status & Notes (സ്റ്റാറ്റസ് തിരുത്തുക)',
                    style: TextStyle(
                      fontSize: 12.5,
                      fontWeight: FontWeight.bold,
                      color: Colors.white,
                      fontFamilyFallback: TekTypography.malayalamFallback,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
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
