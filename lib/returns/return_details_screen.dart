import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';
import 'package:hive_flutter/hive_flutter.dart';
import '../auth/auth_controller.dart';
import '../main.dart' show boxReturns, toast;
import '../ui/dashboard/dashboard_tokens.dart';
import 'return_models.dart';
import 'return_service.dart';

/// Comprehensive Return Case Management Screen.
/// Displays real-time status badges, workflow action buttons, chronological timeline,
/// vendor handover details, status history, and customer delivery confirmation.
class ReturnDetailsScreen extends StatefulWidget {
  final dynamic returnKey;

  const ReturnDetailsScreen({
    super.key,
    required this.returnKey,
  });

  @override
  State<ReturnDetailsScreen> createState() => _ReturnDetailsScreenState();
}

class _ReturnDetailsScreenState extends State<ReturnDetailsScreen> with SingleTickerProviderStateMixin {
  late TabController _tabController;
  final _dateFormat = DateFormat('dd MMM yyyy, hh:mm a');
  final _shortDateFormat = DateFormat('dd MMM yyyy');

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 4, vsync: this);
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  CustomerReturn? _loadReturn() {
    return ReturnService.instance.getReturn(widget.returnKey);
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder(
      valueListenable: Hive.box(boxReturns).listenable(keys: [widget.returnKey]),
      builder: (context, Box box, _) {
        final ret = _loadReturn();
        if (ret == null) {
          return Scaffold(
            backgroundColor: DashboardColors.bgDarkNavyStart,
            appBar: AppBar(backgroundColor: const Color(0xFF0C1236)),
            body: const Center(
              child: Text('Return case not found', style: TextStyle(color: Colors.white)),
            ),
          );
        }

        final auth = context.watch<AuthController>();
        final isOwner = auth.isOwner;
        final thresholdDays = ReturnService.instance.getFollowupThresholdDays();
        final isFollowupOverdue = ret.isFollowUpOverdue(thresholdDays);

        return Scaffold(
          backgroundColor: DashboardColors.bgDarkNavyStart,
          appBar: _buildAppBar(ret),
          body: Container(
            decoration: const BoxDecoration(
              gradient: DashboardColors.backgroundGradient,
            ),
            child: Column(
              children: [
                // 1. Follow-up Overdue Alert (if applicable)
                if (isFollowupOverdue) _buildOverdueAlertBanner(ret, thresholdDays),

                // 2. Case Overview Header
                _buildCaseHeader(ret, isOwner),

                // 3. Quick Action Buttons Bar
                _buildActionBar(ret, auth),

                // 4. Tab Bar (Overview, Vendor & Handover, Resolution, Chronological Timeline)
                Container(
                  color: const Color(0xFF0C1236),
                  child: TabBar(
                    controller: _tabController,
                    indicatorColor: DashboardColors.neonBlue,
                    indicatorWeight: 3,
                    labelColor: DashboardColors.neonBlue,
                    unselectedLabelColor: DashboardColors.textMuted,
                    labelStyle: DashboardTypography.poppins(fontSize: 13, fontWeight: FontWeight.w600),
                    tabs: [
                      const Tab(icon: Icon(Icons.info_outline_rounded, size: 18), text: 'Case Overview'),
                      Tab(
                        icon: const Icon(Icons.local_shipping_rounded, size: 18),
                        text: ret.handoverRecord != null ? 'Vendor Handover' : 'Vendor Info',
                      ),
                      const Tab(icon: Icon(Icons.build_circle_rounded, size: 18), text: 'Vendor Resolution'),
                      Tab(
                        icon: const Icon(Icons.history_rounded, size: 18),
                        text: 'Timeline (${ret.timeline.length})',
                      ),
                    ],
                  ),
                ),

                // 5. Tab Views
                Expanded(
                  child: TabBarView(
                    controller: _tabController,
                    children: [
                      _buildOverviewTab(ret, isOwner),
                      _buildVendorHandoverTab(ret),
                      _buildResolutionTab(ret),
                      _buildTimelineTab(ret),
                    ],
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  // ---------------------------------------------------------------------------
  // APP BAR
  // ---------------------------------------------------------------------------

  PreferredSizeWidget _buildAppBar(CustomerReturn ret) {
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
              ret.returnId,
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
            ret.productName,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: DashboardTypography.poppins(
              fontSize: 15,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
      actions: [
        if (ret.isCompleted)
          Padding(
            padding: const EdgeInsets.only(right: 16),
            child: Chip(
              backgroundColor: const Color(0x3310B981),
              side: const BorderSide(color: Color(0x6610B981)),
              avatar: const Icon(Icons.check_circle_rounded, color: DashboardColors.neonGreen, size: 16),
              label: Text(
                'Case Completed',
                style: DashboardTypography.inter(fontSize: 11.5, fontWeight: FontWeight.bold, color: DashboardColors.neonGreen),
              ),
            ),
          ),
      ],
    );
  }

  // ---------------------------------------------------------------------------
  // OVERDUE ALERT BANNER
  // ---------------------------------------------------------------------------

  Widget _buildOverdueAlertBanner(CustomerReturn ret, int threshold) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
      decoration: const BoxDecoration(
        gradient: DashboardColors.alertGradient,
      ),
      child: Row(
        children: [
          const Icon(Icons.warning_amber_rounded, color: Colors.white, size: 22),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              'VENDOR FOLLOW-UP REQUIRED: Product has been pending with vendor "${ret.originalVendorName ?? ret.handoverRecord?.vendorName ?? "Vendor"}" for ${ret.daysPendingWithVendor} days (threshold is $threshold days).',
              style: DashboardTypography.inter(
                fontSize: 12.5,
                fontWeight: FontWeight.w700,
                color: Colors.white,
              ),
            ),
          ),
          TextButton(
            style: TextButton.styleFrom(
              backgroundColor: Colors.white.withValues(alpha: 0.2),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            ),
            onPressed: () => _showUpdateVendorStatusDialog(ret),
            child: Text(
              'Log Follow-up',
              style: DashboardTypography.poppins(fontSize: 11.5, fontWeight: FontWeight.bold, color: Colors.white),
            ),
          ),
        ],
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // CASE HEADER & STATUS BADGES
  // ---------------------------------------------------------------------------

  Widget _buildCaseHeader(CustomerReturn ret, bool isOwner) {
    final retColor = CustomerReturnStatus.getColor(ret.customerReturnStatus);
    final warColor = CustomerWarrantyStatus.getColor(ret.customerWarrantyStatus);
    final venColor = VendorStatus.getColor(ret.vendorStatus);

    return Container(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 16),
      decoration: const BoxDecoration(
        color: Color(0x1A1B2A55),
        border: Border(bottom: BorderSide(color: Color(0x1FFFFFFF))),
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
                          ret.customerName,
                          style: DashboardTypography.poppins(
                            fontSize: 18,
                            fontWeight: FontWeight.w700,
                            color: Colors.white,
                          ),
                        ),
                        const SizedBox(width: 8),
                        Text(
                          '•  ${ret.customerPhone}',
                          style: DashboardTypography.inter(fontSize: 14, color: DashboardColors.neonBlue),
                        ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'Original Invoice: ${ret.originalInvoiceNumber}  •  Purchased: ${_shortDateFormat.format(ret.originalPurchaseDate)}  •  Registered: ${_dateFormat.format(ret.createdAt)}',
                      style: DashboardTypography.inter(fontSize: 12, color: DashboardColors.textMuted),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          // 4 Status Badges (Customer Return, Customer Warranty, Vendor Status, Delivery)
          Wrap(
            spacing: 10,
            runSpacing: 8,
            children: [
              _buildStatusChip(
                label: 'Return: ${ret.customerReturnStatus}',
                icon: CustomerReturnStatus.getIcon(ret.customerReturnStatus),
                color: retColor,
              ),
              _buildStatusChip(
                label: 'Warranty: ${ret.customerWarrantyStatus}',
                icon: CustomerWarrantyStatus.getIcon(ret.customerWarrantyStatus),
                color: warColor,
                onTap: isOwner ? () => _showVerifyWarrantyDialog(ret) : null,
              ),
              _buildStatusChip(
                label: 'Vendor: ${ret.vendorStatus}',
                icon: VendorStatus.getIcon(ret.vendorStatus),
                color: venColor,
              ),
              if (ret.isPendingWithVendor)
                _buildStatusChip(
                  label: '${ret.daysPendingWithVendor} Days Pending',
                  icon: Icons.timer_outlined,
                  color: ret.daysPendingWithVendor >= 7 ? DashboardColors.neonPink : DashboardColors.neonOrange,
                ),
              if (ret.isReadyForCustomer && !ret.isCompleted)
                _buildStatusChip(
                  label: 'Ready for Customer Pickup',
                  icon: Icons.storefront_rounded,
                  color: DashboardColors.neonGreen,
                ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildStatusChip({
    required String label,
    required IconData icon,
    required Color color,
    VoidCallback? onTap,
  }) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(20),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.15),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: color.withValues(alpha: 0.6)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, color: color, size: 14),
            const SizedBox(width: 6),
            Text(
              label,
              style: DashboardTypography.inter(
                fontSize: 11.5,
                fontWeight: FontWeight.w700,
                color: color,
              ),
            ),
            if (onTap != null) ...[
              const SizedBox(width: 4),
              Icon(Icons.edit_rounded, color: color, size: 12),
            ],
          ],
        ),
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // QUICK ACTIONS BAR
  // ---------------------------------------------------------------------------

  Widget _buildActionBar(CustomerReturn ret, AuthController auth) {
    final canHandover = ret.vendorStatus == VendorStatus.notHandedOver;
    final canConfirmReceipt = ret.vendorStatus == VendorStatus.handedOverToVendor &&
        ret.handoverRecord?.isReceivedByVendor != true;
    final canUpdateVendor = ret.handoverRecord != null && !ret.isCompleted;
    final canResolve = ret.handoverRecord != null && !ret.isCompleted;
    final canReceiveAtShop = ret.handoverRecord != null &&
        ret.shopReceiptDate == null &&
        ret.vendorStatus != VendorStatus.notHandedOver;
    final canReturnToCustomer = ret.shopReceiptDate != null && !ret.isCompleted;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
      decoration: const BoxDecoration(
        color: Color(0xFF0C1236),
        border: Border(bottom: BorderSide(color: Color(0x14FFFFFF))),
      ),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          children: [
            // 1. Hand Over to Vendor
            if (canHandover) ...[
              FilledButton.icon(
                style: FilledButton.styleFrom(
                  backgroundColor: DashboardColors.primaryBlue,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                ),
                onPressed: () => _showHandoverDialog(ret),
                icon: const Icon(Icons.local_shipping_rounded, size: 16),
                label: Text('HAND OVER TO VENDOR', style: DashboardTypography.poppins(fontSize: 12, fontWeight: FontWeight.w700)),
              ),
              const SizedBox(width: 10),
            ],

            // 2. Vendor Receipt Confirmation
            if (canConfirmReceipt) ...[
              FilledButton.icon(
                style: FilledButton.styleFrom(
                  backgroundColor: const Color(0xFF06B6D4),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                ),
                onPressed: () => _confirmVendorReceipt(ret),
                icon: const Icon(Icons.mark_email_read_rounded, size: 16),
                label: Text('CONFIRM VENDOR RECEIPT', style: DashboardTypography.poppins(fontSize: 12, fontWeight: FontWeight.w700)),
              ),
              const SizedBox(width: 10),
            ],

            // 3. Update Vendor Status (14 Statuses)
            if (canUpdateVendor) ...[
              OutlinedButton.icon(
                style: OutlinedButton.styleFrom(
                  foregroundColor: DashboardColors.neonBlue,
                  side: const BorderSide(color: DashboardColors.neonBlue),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                ),
                onPressed: () => _showUpdateVendorStatusDialog(ret),
                icon: const Icon(Icons.sync_rounded, size: 16),
                label: Text('UPDATE VENDOR STATUS', style: DashboardTypography.poppins(fontSize: 12, fontWeight: FontWeight.w600)),
              ),
              const SizedBox(width: 10),
            ],

            // 4. Resolve Vendor Claim
            if (canResolve) ...[
              OutlinedButton.icon(
                style: OutlinedButton.styleFrom(
                  foregroundColor: DashboardColors.neonPurple,
                  side: const BorderSide(color: DashboardColors.neonPurple),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                ),
                onPressed: () => _showVendorResolutionDialog(ret),
                icon: const Icon(Icons.task_alt_rounded, size: 16),
                label: Text('RESOLVE VENDOR CLAIM', style: DashboardTypography.poppins(fontSize: 12, fontWeight: FontWeight.w600)),
              ),
              const SizedBox(width: 10),
            ],

            // 5. Receive From Vendor at Shop
            if (canReceiveAtShop) ...[
              FilledButton.icon(
                style: FilledButton.styleFrom(
                  backgroundColor: const Color(0xFF10B981),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                ),
                onPressed: () => _showReceiveAtShopDialog(ret),
                icon: const Icon(Icons.store_rounded, size: 16),
                label: Text('RECEIVE FROM VENDOR', style: DashboardTypography.poppins(fontSize: 12, fontWeight: FontWeight.w700)),
              ),
              const SizedBox(width: 10),
            ],

            // 6. Return Product to Customer
            if (canReturnToCustomer) ...[
              FilledButton.icon(
                style: FilledButton.styleFrom(
                  backgroundColor: const Color(0xFF22C55E),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                ),
                onPressed: () => _showReturnToCustomerDialog(ret),
                icon: const Icon(Icons.assignment_turned_in_rounded, size: 16),
                label: Text('RETURN PRODUCT TO CUSTOMER', style: DashboardTypography.poppins(fontSize: 12, fontWeight: FontWeight.w700)),
              ),
              const SizedBox(width: 10),
            ],

            // 7. Owner Warranty Override
            if (auth.isOwner && !ret.isCompleted) ...[
              TextButton.icon(
                style: TextButton.styleFrom(
                  foregroundColor: DashboardColors.neonOrange,
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                ),
                onPressed: () => _showVerifyWarrantyDialog(ret),
                icon: const Icon(Icons.shield_outlined, size: 16),
                label: Text('Warranty Decision', style: DashboardTypography.inter(fontSize: 12, fontWeight: FontWeight.w600)),
              ),
            ],
          ],
        ),
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // TAB 1: OVERVIEW TAB
  // ---------------------------------------------------------------------------

  Widget _buildOverviewTab(CustomerReturn ret, bool isOwner) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Product & Return Complaint Card
              Expanded(
                flex: 3,
                child: Container(
                  padding: const EdgeInsets.all(20),
                  decoration: DashboardColors.glassCard(),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _buildSectionHeader('PRODUCT & COMPLAINT DETAILS', Icons.devices_other_rounded, DashboardColors.neonBlue),
                      const SizedBox(height: 16),
                      _buildDetailRow('Product Name', ret.productName, highlight: true),
                      if (ret.productBrand != null || ret.productModel != null)
                        _buildDetailRow('Brand / Model', '${ret.productBrand ?? ''} ${ret.productModel ?? ''}'.trim()),
                      _buildDetailRow('Serial / IMEI', ret.serialNumber?.isNotEmpty == true ? ret.serialNumber! : 'Not Specified', highlight: true),
                      _buildDetailRow('Return Reason', ret.returnReason, valueColor: DashboardColors.neonOrange),
                      _buildDetailRow('Customer Complaint', ret.customerComplaint),
                      _buildDetailRow('Product Condition', ret.productCondition),
                      _buildDetailRow('Accessories Received', ret.accessoriesReceived),
                      if (ret.internalNotes != null && ret.internalNotes!.isNotEmpty)
                        _buildDetailRow('Internal Notes', ret.internalNotes!),
                      _buildDetailRow('Assigned Staff', ret.assignedStaffName ?? 'Unassigned'),
                    ],
                  ),
                ),
              ),

              const SizedBox(width: 20),

              // Customer & Warranty Card
              Expanded(
                flex: 2,
                child: Column(
                  children: [
                    Container(
                      padding: const EdgeInsets.all(20),
                      decoration: DashboardColors.glassCard(),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          _buildSectionHeader('CUSTOMER DETAILS', Icons.person_rounded, DashboardColors.neonPurple),
                          const SizedBox(height: 16),
                          _buildDetailRow('Customer Name', ret.customerName),
                          _buildDetailRow('Customer Phone', ret.customerPhone),
                          _buildDetailRow('Customer ID', ret.customerId ?? 'N/A'),
                          _buildDetailRow('Invoice Number', ret.originalInvoiceNumber),
                          _buildDetailRow('Purchase Date', _shortDateFormat.format(ret.originalPurchaseDate)),
                        ],
                      ),
                    ),
                    const SizedBox(height: 16),
                    Container(
                      padding: const EdgeInsets.all(20),
                      decoration: DashboardColors.glassCard(
                        borderColor: CustomerWarrantyStatus.getColor(ret.customerWarrantyStatus).withValues(alpha: 0.5),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              _buildSectionHeader(
                                'WARRANTY TERMS',
                                Icons.security_rounded,
                                CustomerWarrantyStatus.getColor(ret.customerWarrantyStatus),
                              ),
                              if (isOwner)
                                TextButton(
                                  onPressed: () => _showVerifyWarrantyDialog(ret),
                                  child: Text('Edit', style: DashboardTypography.inter(fontSize: 12, color: DashboardColors.neonBlue)),
                                ),
                            ],
                          ),
                          const SizedBox(height: 14),
                          _buildDetailRow('Specified Term', ret.customerWarrantyPeriod),
                          _buildDetailRow(
                            'Expiry Date',
                            ret.customerWarrantyExpiryDate != null
                                ? _shortDateFormat.format(ret.customerWarrantyExpiryDate!)
                                : 'No Expiry',
                          ),
                          _buildDetailRow(
                            'Current Status',
                            ret.customerWarrantyStatus,
                            valueColor: CustomerWarrantyStatus.getColor(ret.customerWarrantyStatus),
                            highlight: true,
                          ),
                          if (ret.warrantyInspectionNotes != null)
                            _buildDetailRow('Inspection Notes', ret.warrantyInspectionNotes!),
                        ],
                      ),
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
  // TAB 2: VENDOR & HANDOVER TAB
  // ---------------------------------------------------------------------------

  Widget _buildVendorHandoverTab(CustomerReturn ret) {
    final handover = ret.handoverRecord;

    return SingleChildScrollView(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Vendor Information Card
              Expanded(
                child: Container(
                  padding: const EdgeInsets.all(20),
                  decoration: DashboardColors.glassCard(),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _buildSectionHeader('ORIGINAL VENDOR INFORMATION', Icons.store_rounded, DashboardColors.neonBlue),
                      const SizedBox(height: 16),
                      _buildDetailRow('Vendor Name', ret.originalVendorName ?? handover?.vendorName ?? 'Not Assigned'),
                      _buildDetailRow('Vendor Phone', ret.originalVendorPhone ?? handover?.vendorPhone ?? 'N/A'),
                      if (ret.originalVendorInvoice != null)
                        _buildDetailRow('Vendor Invoice', ret.originalVendorInvoice!),
                      if (ret.originalVendorPurchaseDate != null)
                        _buildDetailRow('Original Purchase Date', _shortDateFormat.format(ret.originalVendorPurchaseDate!)),
                      if (ret.originalVendorWarrantyPeriod != null)
                        _buildDetailRow('Vendor Warranty Term', ret.originalVendorWarrantyPeriod!),
                      _buildDetailRow('Vendor Reference Number', ret.originalVendorReference ?? handover?.vendorReferenceNumber ?? 'N/A'),
                    ],
                  ),
                ),
              ),

              const SizedBox(width: 20),

              // Handover Details Card
              Expanded(
                child: Container(
                  padding: const EdgeInsets.all(20),
                  decoration: DashboardColors.glassCard(
                    borderColor: handover != null
                        ? const Color(0x3338BDF8)
                        : DashboardColors.glassBorder,
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          _buildSectionHeader('HANDOVER RECORD', Icons.local_shipping_rounded, const Color(0xFF38BDF8)),
                          if (handover == null)
                            FilledButton.icon(
                              style: FilledButton.styleFrom(
                                backgroundColor: DashboardColors.primaryBlue,
                                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                              ),
                              onPressed: () => _showHandoverDialog(ret),
                              icon: const Icon(Icons.add, size: 14),
                              label: Text('Record Handover', style: DashboardTypography.inter(fontSize: 11)),
                            ),
                        ],
                      ),
                      const SizedBox(height: 16),
                      if (handover != null) ...[
                        _buildDetailRow('Handover Reference', handover.handoverReference, highlight: true),
                        _buildDetailRow('Handover Date & Time', _dateFormat.format(handover.handoverDate)),
                        _buildDetailRow('Vendor Service Centre', handover.vendorServiceCentre),
                        _buildDetailRow('Vendor Docket / Ref #', handover.vendorReferenceNumber),
                        _buildDetailRow('Handed Over By', handover.handedOverByName),
                        _buildDetailRow('Handover Notes', handover.handoverNotes),
                        _buildDetailRow(
                          'Vendor Receipt Status',
                          handover.isReceivedByVendor
                              ? 'Confirmed (${_dateFormat.format(handover.vendorReceivedDate!)})'
                              : 'Pending Vendor Acknowledgment',
                          valueColor: handover.isReceivedByVendor ? DashboardColors.neonGreen : DashboardColors.neonOrange,
                        ),
                      ] else ...[
                        Center(
                          child: Padding(
                            padding: const EdgeInsets.symmetric(vertical: 30),
                            child: Column(
                              children: [
                                const Icon(Icons.hourglass_empty_rounded, size: 40, color: DashboardColors.textMuted),
                                const SizedBox(height: 10),
                                Text(
                                  'Product has not been handed over to vendor yet.',
                                  style: DashboardTypography.inter(fontSize: 13, color: DashboardColors.textMuted),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ],
          ),

          const SizedBox(height: 24),

          // Vendor Status History Trail
          Container(
            padding: const EdgeInsets.all(20),
            decoration: DashboardColors.glassCard(),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _buildSectionHeader('VENDOR STATUS TRANSITION HISTORY', Icons.history_edu_rounded, DashboardColors.neonPurple),
                const SizedBox(height: 16),
                if (ret.vendorStatusHistory.isEmpty)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 20),
                    child: Text(
                      'No status transitions recorded yet.',
                      style: DashboardTypography.inter(fontSize: 13, color: DashboardColors.textMuted),
                    ),
                  )
                else
                  ListView.separated(
                    shrinkWrap: true,
                    physics: const NeverScrollableScrollPhysics(),
                    itemCount: ret.vendorStatusHistory.length,
                    separatorBuilder: (_, __) => const Divider(height: 20, color: Color(0x14FFFFFF)),
                    itemBuilder: (context, idx) {
                      final item = ret.vendorStatusHistory[idx];
                      final color = VendorStatus.getColor(item.newStatus);
                      return Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Container(
                            width: 10,
                            height: 10,
                            margin: const EdgeInsets.only(top: 5),
                            decoration: BoxDecoration(shape: BoxShape.circle, color: color),
                          ),
                          const SizedBox(width: 14),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(
                                  children: [
                                    Text(
                                      item.newStatus,
                                      style: DashboardTypography.poppins(
                                        fontSize: 13,
                                        fontWeight: FontWeight.w700,
                                        color: color,
                                      ),
                                    ),
                                    const SizedBox(width: 8),
                                    Text(
                                      'from "${item.previousStatus}"',
                                      style: DashboardTypography.inter(fontSize: 11, color: DashboardColors.textMuted),
                                    ),
                                    const Spacer(),
                                    Text(
                                      _dateFormat.format(item.timestamp),
                                      style: DashboardTypography.inter(fontSize: 11, color: DashboardColors.textMuted),
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 3),
                                Text(
                                  item.notes.isNotEmpty ? item.notes : 'No notes provided.',
                                  style: DashboardTypography.inter(fontSize: 12, color: DashboardColors.textLight),
                                ),
                                const SizedBox(height: 2),
                                Text(
                                  'Updated by: ${item.updatedByName}${item.vendorReferenceNumber != null ? " • Ref: ${item.vendorReferenceNumber}" : ""}',
                                  style: DashboardTypography.inter(fontSize: 10.5, color: DashboardColors.textMuted),
                                ),
                              ],
                            ),
                          ),
                        ],
                      );
                    },
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // TAB 3: VENDOR RESOLUTION TAB
  // ---------------------------------------------------------------------------

  Widget _buildResolutionTab(CustomerReturn ret) {
    final res = ret.vendorResolution;

    return SingleChildScrollView(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Resolution Summary
              Expanded(
                flex: 3,
                child: Container(
                  padding: const EdgeInsets.all(20),
                  decoration: DashboardColors.glassCard(
                    borderColor: res != null ? const Color(0x3310B981) : DashboardColors.glassBorder,
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          _buildSectionHeader('VENDOR RESOLUTION OUTCOME', Icons.verified_rounded, DashboardColors.neonGreen),
                          if (res == null && ret.handoverRecord != null)
                            FilledButton.icon(
                              style: FilledButton.styleFrom(
                                backgroundColor: DashboardColors.neonPurple,
                                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                              ),
                              onPressed: () => _showVendorResolutionDialog(ret),
                              icon: const Icon(Icons.add_task_rounded, size: 14),
                              label: Text('Record Outcome', style: DashboardTypography.inter(fontSize: 11.5, fontWeight: FontWeight.bold)),
                            ),
                        ],
                      ),
                      const SizedBox(height: 16),
                      if (res != null) ...[
                        _buildDetailRow('Vendor Decision', res.decision, highlight: true, valueColor: DashboardColors.neonGreen),
                        _buildDetailRow('Decision Date', _dateFormat.format(res.decisionDate)),
                        if (res.repairDetails != null)
                          _buildDetailRow('Repair Details', res.repairDetails!),
                        if (res.isReplacement) ...[
                          const SizedBox(height: 8),
                          Container(
                            padding: const EdgeInsets.all(12),
                            decoration: BoxDecoration(
                              color: const Color(0x1F10B981),
                              borderRadius: BorderRadius.circular(10),
                              border: Border.all(color: const Color(0x3310B981)),
                            ),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  'Replacement Unit Information',
                                  style: DashboardTypography.poppins(fontSize: 12.5, fontWeight: FontWeight.bold, color: DashboardColors.neonGreen),
                                ),
                                const SizedBox(height: 6),
                                _buildDetailRow('Replacement Product', res.replacementProduct ?? 'Same Model'),
                                _buildDetailRow('New Serial / IMEI', res.replacementSerialNumber ?? 'N/A', highlight: true),
                                if (res.replacementReceivedDate != null)
                                  _buildDetailRow('Replacement Received Date', _dateFormat.format(res.replacementReceivedDate!)),
                              ],
                            ),
                          ),
                          const SizedBox(height: 8),
                        ],
                        if (res.claimRejectionReason != null)
                          _buildDetailRow('Claim Rejection Reason', res.claimRejectionReason!, valueColor: DashboardColors.neonPink),
                        _buildDetailRow('Vendor Charges', '₹${res.vendorCharges.toStringAsFixed(2)}'),
                        _buildDetailRow('Vendor Credit / Refund', '₹${res.vendorCreditRefund.toStringAsFixed(2)}'),
                        if (res.vendorNotes != null)
                          _buildDetailRow('Vendor Notes', res.vendorNotes!),
                        _buildDetailRow('Recorded By', res.resolvedByName ?? 'Staff'),
                      ] else ...[
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: 30),
                          child: Center(
                            child: Column(
                              children: [
                                const Icon(Icons.pending_actions_rounded, size: 40, color: DashboardColors.textMuted),
                                const SizedBox(height: 10),
                                Text(
                                  'Vendor resolution pending. Awaiting repair completion or replacement approval.',
                                  style: DashboardTypography.inter(fontSize: 13, color: DashboardColors.textMuted),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ),

              const SizedBox(width: 20),

              // Shop Receipt & Inspection Card
              Expanded(
                flex: 2,
                child: Container(
                  padding: const EdgeInsets.all(20),
                  decoration: DashboardColors.glassCard(),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _buildSectionHeader('SHOP RECEIPT & CUSTOMER PICKUP', Icons.store_rounded, const Color(0xFF06B6D4)),
                      const SizedBox(height: 16),
                      if (ret.shopReceiptDate != null) ...[
                        _buildDetailRow('Date Received at Shop', _dateFormat.format(ret.shopReceiptDate!), highlight: true),
                        _buildDetailRow('Received By', ret.shopReceivedByName ?? 'Staff'),
                        _buildDetailRow('Shop Inspection Notes', ret.shopInspectionNotes ?? 'No notes'),
                        _buildDetailRow(
                          'Ready for Customer',
                          ret.isReadyForCustomer ? 'Yes - Quality Check Passed' : 'Pending Final QC',
                          valueColor: ret.isReadyForCustomer ? DashboardColors.neonGreen : DashboardColors.neonOrange,
                        ),
                      ] else ...[
                        Text(
                          'Product has not arrived back at shop from vendor yet.',
                          style: DashboardTypography.inter(fontSize: 12.5, color: DashboardColors.textMuted),
                        ),
                        const SizedBox(height: 14),
                        if (ret.handoverRecord != null)
                          FilledButton.icon(
                            style: FilledButton.styleFrom(
                              backgroundColor: const Color(0xFF10B981),
                              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                            ),
                            onPressed: () => _showReceiveAtShopDialog(ret),
                            icon: const Icon(Icons.store_rounded, size: 16),
                            label: Text('Receive Product at Shop', style: DashboardTypography.inter(fontSize: 12, fontWeight: FontWeight.bold)),
                          ),
                      ],

                      const SizedBox(height: 20),
                      const Divider(height: 1, color: Color(0x14FFFFFF)),
                      const SizedBox(height: 20),

                      // Final Customer Delivery Confirmation
                      _buildSectionHeader('CUSTOMER DELIVERY', Icons.assignment_turned_in_rounded, const Color(0xFF22C55E)),
                      const SizedBox(height: 14),
                      if (ret.customerDeliveryRecord != null) ...[
                        _buildDetailRow('Delivered Date', _dateFormat.format(ret.customerDeliveryRecord!.deliveryDate), highlight: true),
                        _buildDetailRow('Delivered By', ret.customerDeliveryRecord!.deliveredByName),
                        _buildDetailRow('Customer Confirmation', ret.customerDeliveryRecord!.customerConfirmation),
                        if (ret.customerDeliveryRecord!.deliveryNotes != null)
                          _buildDetailRow('Delivery Notes', ret.customerDeliveryRecord!.deliveryNotes!),
                        if (ret.customerDeliveryRecord!.deliveredProductDetails != null)
                          _buildDetailRow('Delivered Unit Details', ret.customerDeliveryRecord!.deliveredProductDetails!),
                      ] else ...[
                        Text(
                          ret.shopReceiptDate != null
                              ? 'Product is at shop awaiting customer handover.'
                              : 'Pending vendor resolution and shop arrival.',
                          style: DashboardTypography.inter(fontSize: 12, color: DashboardColors.textMuted),
                        ),
                        if (ret.shopReceiptDate != null) ...[
                          const SizedBox(height: 14),
                          FilledButton.icon(
                            style: FilledButton.styleFrom(
                              backgroundColor: const Color(0xFF22C55E),
                              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                            ),
                            onPressed: () => _showReturnToCustomerDialog(ret),
                            icon: const Icon(Icons.assignment_turned_in_rounded, size: 16),
                            label: Text('Return to Customer', style: DashboardTypography.inter(fontSize: 12, fontWeight: FontWeight.bold)),
                          ),
                        ],
                      ],
                    ],
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // TAB 4: CHRONOLOGICAL TIMELINE TAB
  // ---------------------------------------------------------------------------

  Widget _buildTimelineTab(CustomerReturn ret) {
    if (ret.timeline.isEmpty) {
      return Center(
        child: Text('No timeline events recorded.', style: DashboardTypography.inter(color: DashboardColors.textMuted)),
      );
    }

    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.timeline_rounded, color: DashboardColors.neonBlue, size: 22),
              const SizedBox(width: 10),
              Text(
                'Complete Chronological Return & Vendor Timeline',
                style: DashboardTypography.poppins(
                  fontSize: 15,
                  fontWeight: FontWeight.w700,
                  color: Colors.white,
                ),
              ),
              const Spacer(),
              Text(
                '${ret.timeline.length} verified events',
                style: DashboardTypography.inter(fontSize: 12, color: DashboardColors.textMuted),
              ),
            ],
          ),
          const SizedBox(height: 20),
          ListView.builder(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            itemCount: ret.timeline.length,
            itemBuilder: (context, idx) {
              final ev = ret.timeline[idx];
              final isLast = idx == ret.timeline.length - 1;

              return IntrinsicHeight(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Date & Time Column
                    SizedBox(
                      width: 140,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.end,
                        children: [
                          Text(
                            _shortDateFormat.format(ev.timestamp),
                            style: DashboardTypography.inter(
                              fontSize: 12,
                              fontWeight: FontWeight.bold,
                              color: Colors.white,
                            ),
                          ),
                          Text(
                            DateFormat('hh:mm a').format(ev.timestamp),
                            style: DashboardTypography.inter(
                              fontSize: 11,
                              color: DashboardColors.neonBlue,
                            ),
                          ),
                        ],
                      ),
                    ),

                    const SizedBox(width: 16),

                    // Dot & Connecting Line
                    Column(
                      children: [
                        Container(
                          width: 14,
                          height: 14,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: DashboardColors.neonBlue,
                            boxShadow: [
                              BoxShadow(
                                color: DashboardColors.neonBlue.withValues(alpha: 0.5),
                                blurRadius: 8,
                              ),
                            ],
                          ),
                        ),
                        if (!isLast)
                          Expanded(
                            child: Container(
                              width: 2,
                              color: const Color(0x3300D4FF),
                            ),
                          ),
                      ],
                    ),

                    const SizedBox(width: 16),

                    // Event Content Card
                    Expanded(
                      child: Padding(
                        padding: const EdgeInsets.only(bottom: 24),
                        child: Container(
                          padding: const EdgeInsets.all(16),
                          decoration: DashboardColors.glassCard(
                            radius: 14,
                            fillColor: const Color(0x1F1E293B),
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                children: [
                                  Text(
                                    ev.title,
                                    style: DashboardTypography.poppins(
                                      fontSize: 14,
                                      fontWeight: FontWeight.bold,
                                      color: Colors.white,
                                    ),
                                  ),
                                  const Spacer(),
                                  Container(
                                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                                    decoration: BoxDecoration(
                                      color: const Color(0x26FFFFFF),
                                      borderRadius: BorderRadius.circular(6),
                                    ),
                                    child: Text(
                                      ev.actorRole,
                                      style: DashboardTypography.inter(fontSize: 10, color: DashboardColors.textLight),
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 6),
                              Text(
                                ev.description,
                                style: DashboardTypography.inter(fontSize: 12.5, color: DashboardColors.textLight),
                              ),
                              if (ev.notes != null && ev.notes!.isNotEmpty) ...[
                                const SizedBox(height: 6),
                                Container(
                                  padding: const EdgeInsets.all(8),
                                  decoration: BoxDecoration(
                                    color: const Color(0x1A000000),
                                    borderRadius: BorderRadius.circular(8),
                                  ),
                                  child: Text(
                                    'Notes: ${ev.notes}',
                                    style: DashboardTypography.inter(
                                      fontSize: 11.5,
                                      color: DashboardColors.textMuted,
                                    ).copyWith(fontStyle: FontStyle.italic),
                                  ),
                                ),
                              ],
                              const SizedBox(height: 8),
                              Text(
                                'Recorded by: ${ev.actorName}',
                                style: DashboardTypography.inter(fontSize: 11, color: DashboardColors.textMuted),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              );
            },
          ),
        ],
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // WORKFLOW ACTION MODALS
  // ---------------------------------------------------------------------------

  // Handover Dialog (Requirement 6)
  void _showHandoverDialog(CustomerReturn ret) {
    final auth = context.read<AuthController>();
    final vendorNameCtrl = TextEditingController(text: ret.originalVendorName ?? '');
    final vendorPhoneCtrl = TextEditingController(text: ret.originalVendorPhone ?? '');
    final serviceCentreCtrl = TextEditingController(text: 'Authorized Service Centre');
    final vendorRefCtrl = TextEditingController();
    final handoverNotesCtrl = TextEditingController();
    bool submitting = false;

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setD) => AlertDialog(
          backgroundColor: const Color(0xFF0F172A),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(20),
            side: const BorderSide(color: Color(0x3338BDF8)),
          ),
          title: Row(
            children: [
              const Icon(Icons.local_shipping_rounded, color: Color(0xFF38BDF8)),
              const SizedBox(width: 10),
              Text(
                'Hand Over Product to Vendor',
                style: DashboardTypography.poppins(fontSize: 16, fontWeight: FontWeight.bold, color: Colors.white),
              ),
            ],
          ),
          content: SizedBox(
            width: 520,
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Records physical dispatch to vendor with unique handover reference (e.g. VHO-2026-XXXX).',
                    style: DashboardTypography.inter(fontSize: 12, color: DashboardColors.textMuted),
                  ),
                  const SizedBox(height: 16),
                  _buildFormInput('Vendor Name *', vendorNameCtrl, 'Enter Vendor Name'),
                  const SizedBox(height: 12),
                  _buildFormInput('Vendor Phone Number', vendorPhoneCtrl, 'Vendor Contact Number'),
                  const SizedBox(height: 12),
                  _buildFormInput('Vendor Service Centre Location *', serviceCentreCtrl, 'e.g. Cochin Service Hub'),
                  const SizedBox(height: 12),
                  _buildFormInput('Vendor Docket / Reference # *', vendorRefCtrl, 'Vendor acknowledgement / tracking #'),
                  const SizedBox(height: 12),
                  _buildFormInput('Handover Notes', handoverNotesCtrl, 'Any specific instructions or remarks', maxLines: 2),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: submitting ? null : () => Navigator.pop(ctx),
              child: Text('Cancel', style: DashboardTypography.inter(color: Colors.white70)),
            ),
            FilledButton(
              style: FilledButton.styleFrom(backgroundColor: DashboardColors.primaryBlue),
              onPressed: submitting
                  ? null
                  : () async {
                      if (vendorNameCtrl.text.trim().isEmpty ||
                          vendorRefCtrl.text.trim().isEmpty ||
                          serviceCentreCtrl.text.trim().isEmpty) {
                        toast(context, 'Please fill in vendor name, service centre, and reference #', error: true);
                        return;
                      }

                      setD(() => submitting = true);
                      try {
                        await ReturnService.instance.handoverToVendor(
                          returnKey: ret.key,
                          vendorKey: ret.originalVendorKey,
                          vendorName: vendorNameCtrl.text.trim(),
                          vendorPhone: vendorPhoneCtrl.text.trim(),
                          vendorReferenceNumber: vendorRefCtrl.text.trim(),
                          vendorServiceCentre: serviceCentreCtrl.text.trim(),
                          actorId: auth.uid,
                          actorName: auth.name.isNotEmpty ? auth.name : 'Staff',
                          actorRole: auth.isOwner ? 'Owner' : 'Staff',
                          handoverNotes: handoverNotesCtrl.text.trim().isNotEmpty
                              ? handoverNotesCtrl.text.trim()
                              : 'Handed over for inspection/repair',
                        );
                        if (ctx.mounted) {
                          Navigator.pop(ctx);
                          toast(context, 'Handover Recorded Successfully');
                        }
                      } catch (e) {
                        setD(() => submitting = false);
                        if (ctx.mounted) toast(context, 'Failed: $e', error: true);
                      }
                    },
              child: submitting
                  ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2))
                  : Text('Confirm Handover', style: DashboardTypography.inter(fontWeight: FontWeight.bold)),
            ),
          ],
        ),
      ),
    );
  }

  // Confirm Vendor Receipt
  Future<void> _confirmVendorReceipt(CustomerReturn ret) async {
    final auth = context.read<AuthController>();
    final notesCtrl = TextEditingController();

    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF0F172A),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
        title: const Text('Confirm Vendor Receipt', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Has the vendor confirmed receipt of this unit at their service center?',
              style: TextStyle(color: Colors.white70, fontSize: 13),
            ),
            const SizedBox(height: 14),
            TextField(
              controller: notesCtrl,
              style: const TextStyle(color: Colors.white),
              decoration: const InputDecoration(
                hintText: 'Optional vendor receipt notes...',
                hintStyle: TextStyle(color: Colors.white38),
                filled: true,
                fillColor: Color(0x1AFFFFFF),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: const Color(0xFF06B6D4)),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Confirm Receipt'),
          ),
        ],
      ),
    );

    if (ok == true) {
      try {
        await ReturnService.instance.confirmVendorReceipt(
          returnKey: ret.key,
          actorId: auth.uid,
          actorName: auth.name.isNotEmpty ? auth.name : 'Staff',
          actorRole: auth.isOwner ? 'Owner' : 'Staff',
          notes: notesCtrl.text.trim().isNotEmpty ? notesCtrl.text.trim() : 'Vendor confirmed receipt',
        );
        if (mounted) toast(context, 'Vendor Receipt Confirmed');
      } catch (e) {
        if (mounted) toast(context, 'Failed: $e', error: true);
      }
    }
  }

  // Update Vendor Status (14 Statuses)
  void _showUpdateVendorStatusDialog(CustomerReturn ret) {
    final auth = context.read<AuthController>();
    String selectedStatus = ret.vendorStatus;
    final notesCtrl = TextEditingController();
    final vendorRefCtrl = TextEditingController(text: ret.originalVendorReference ?? '');
    bool submitting = false;

    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setD) => AlertDialog(
          backgroundColor: const Color(0xFF0F172A),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
          title: Row(
            children: [
              const Icon(Icons.sync_rounded, color: DashboardColors.neonBlue),
              const SizedBox(width: 10),
              Text(
                'Update Vendor Status',
                style: DashboardTypography.poppins(fontSize: 16, fontWeight: FontWeight.bold, color: Colors.white),
              ),
            ],
          ),
          content: SizedBox(
            width: 480,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Select from the official 14 vendor workflow tracking statuses. All transitions are logged with user and timestamp.',
                  style: DashboardTypography.inter(fontSize: 11.5, color: DashboardColors.textMuted),
                ),
                const SizedBox(height: 16),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 14),
                  decoration: BoxDecoration(
                    color: const Color(0x26000000),
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: const Color(0x33FFFFFF)),
                  ),
                  child: DropdownButtonHideUnderline(
                    child: DropdownButton<String>(
                      isExpanded: true,
                      dropdownColor: const Color(0xFF1E293B),
                      value: selectedStatus,
                      items: VendorStatus.all.map((s) {
                        return DropdownMenuItem(
                          value: s,
                          child: Text(s, style: DashboardTypography.inter(color: Colors.white, fontSize: 13)),
                        );
                      }).toList(),
                      onChanged: (val) {
                        if (val != null) setD(() => selectedStatus = val);
                      },
                    ),
                  ),
                ),
                const SizedBox(height: 14),
                _buildFormInput('Vendor Reference #', vendorRefCtrl, 'Updated docket or ticket #'),
                const SizedBox(height: 12),
                _buildFormInput('Status Notes / Follow-up Details *', notesCtrl, 'e.g. Spoke with service engineer, awaiting part...', maxLines: 3),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: submitting ? null : () => Navigator.pop(ctx),
              child: Text('Cancel', style: DashboardTypography.inter(color: Colors.white70)),
            ),
            FilledButton(
              style: FilledButton.styleFrom(backgroundColor: DashboardColors.primaryBlue),
              onPressed: submitting
                  ? null
                  : () async {
                      if (notesCtrl.text.trim().isEmpty) {
                        toast(context, 'Please enter status notes or follow-up details', error: true);
                        return;
                      }

                      setD(() => submitting = true);
                      try {
                        await ReturnService.instance.updateVendorStatus(
                          returnKey: ret.key,
                          newStatus: selectedStatus,
                          actorId: auth.uid,
                          actorName: auth.name.isNotEmpty ? auth.name : 'Staff',
                          actorRole: auth.isOwner ? 'Owner' : 'Staff',
                          vendorReferenceNumber: vendorRefCtrl.text.trim(),
                          notes: notesCtrl.text.trim(),
                        );
                        if (ctx.mounted) {
                          Navigator.pop(ctx);
                          toast(context, 'Status Updated: $selectedStatus');
                        }
                      } catch (e) {
                        setD(() => submitting = false);
                        if (ctx.mounted) toast(context, 'Failed: $e', error: true);
                      }
                    },
              child: submitting
                  ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2))
                  : Text('Save Status Update', style: DashboardTypography.inter(fontWeight: FontWeight.bold)),
            ),
          ],
        ),
      ),
    );
  }

  // Resolve Vendor Claim (Repaired / Replacement / Rejected)
  void _showVendorResolutionDialog(CustomerReturn ret) {
    final auth = context.read<AuthController>();
    String decision = VendorResolutionType.repaired;
    final repairCtrl = TextEditingController();
    final replacementProdCtrl = TextEditingController(text: ret.productName);
    final replacementSerialCtrl = TextEditingController();
    final chargesCtrl = TextEditingController(text: '0');
    final creditCtrl = TextEditingController(text: '0');
    final rejectionReasonCtrl = TextEditingController();
    final notesCtrl = TextEditingController();
    bool submitting = false;

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setD) {
          final isReplacement = decision == VendorResolutionType.replacementApproved ||
              decision == VendorResolutionType.replacementDispatched ||
              decision == VendorResolutionType.replacementReceived;
          final isRejected = decision == VendorResolutionType.claimRejected;

          return AlertDialog(
            backgroundColor: const Color(0xFF0F172A),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
            title: Row(
              children: [
                const Icon(Icons.task_alt_rounded, color: DashboardColors.neonPurple),
                const SizedBox(width: 10),
                Text(
                  'Record Vendor Claim Resolution',
                  style: DashboardTypography.poppins(fontSize: 16, fontWeight: FontWeight.bold, color: Colors.white),
                ),
              ],
            ),
            content: SizedBox(
              width: 540,
              child: SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Record the final repair, replacement or rejection outcome provided by the vendor.',
                      style: DashboardTypography.inter(fontSize: 12, color: DashboardColors.textMuted),
                    ),
                    const SizedBox(height: 16),
                    Text('Vendor Outcome Decision *', style: DashboardTypography.inter(fontSize: 12, color: DashboardColors.textLight)),
                    const SizedBox(height: 6),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 14),
                      decoration: BoxDecoration(
                        color: const Color(0x26000000),
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(color: const Color(0x33FFFFFF)),
                      ),
                      child: DropdownButtonHideUnderline(
                        child: DropdownButton<String>(
                          isExpanded: true,
                          dropdownColor: const Color(0xFF1E293B),
                          value: decision,
                          items: VendorResolutionType.all.map((d) {
                            return DropdownMenuItem(
                              value: d,
                              child: Text(d, style: DashboardTypography.inter(color: Colors.white, fontSize: 13.5)),
                            );
                          }).toList(),
                          onChanged: (val) {
                            if (val != null) setD(() => decision = val);
                          },
                        ),
                      ),
                    ),
                    const SizedBox(height: 14),

                    if (decision == VendorResolutionType.repaired) ...[
                      _buildFormInput('Repair Details *', repairCtrl, 'e.g. Replaced display IC, updated firmware...', maxLines: 2),
                    ],

                    if (isReplacement) ...[
                      _buildFormInput('Replacement Product Model *', replacementProdCtrl, 'Model name'),
                      const SizedBox(height: 12),
                      _buildFormInput('New Serial Number / IMEI *', replacementSerialCtrl, 'Enter replacement unit IMEI/Serial'),
                    ],

                    if (isRejected) ...[
                      _buildFormInput('Claim Rejection Reason *', rejectionReasonCtrl, 'e.g. Physical water damage detected, customer abuse...', maxLines: 2),
                    ],

                    const SizedBox(height: 12),
                    Row(
                      children: [
                        Expanded(
                          child: _buildFormInput('Vendor Charges (₹)', chargesCtrl, '0.00', keyboardType: TextInputType.number),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: _buildFormInput('Vendor Credit / Refund (₹)', creditCtrl, '0.00', keyboardType: TextInputType.number),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    _buildFormInput('Vendor Resolution Notes', notesCtrl, 'Any extra remarks...'),
                  ],
                ),
              ),
            ),
            actions: [
              TextButton(
                onPressed: submitting ? null : () => Navigator.pop(ctx),
                child: Text('Cancel', style: DashboardTypography.inter(color: Colors.white70)),
              ),
              FilledButton(
                style: FilledButton.styleFrom(backgroundColor: DashboardColors.neonPurple),
                onPressed: submitting
                    ? null
                    : () async {
                        setD(() => submitting = true);
                        try {
                          await ReturnService.instance.resolveVendorClaim(
                            returnKey: ret.key,
                            decision: decision,
                            actorId: auth.uid,
                            actorName: auth.name.isNotEmpty ? auth.name : 'Staff',
                            actorRole: auth.isOwner ? 'Owner' : 'Staff',
                            repairDetails: repairCtrl.text.trim().isNotEmpty ? repairCtrl.text.trim() : null,
                            isReplacement: isReplacement,
                            replacementProduct: isReplacement ? replacementProdCtrl.text.trim() : null,
                            replacementSerialNumber: isReplacement ? replacementSerialCtrl.text.trim() : null,
                            replacementReceivedDate: isReplacement ? DateTime.now() : null,
                            vendorCharges: double.tryParse(chargesCtrl.text.trim()) ?? 0.0,
                            vendorCreditRefund: double.tryParse(creditCtrl.text.trim()) ?? 0.0,
                            vendorNotes: notesCtrl.text.trim().isNotEmpty ? notesCtrl.text.trim() : null,
                            claimRejectionReason: isRejected ? rejectionReasonCtrl.text.trim() : null,
                          );
                          if (ctx.mounted) {
                            Navigator.pop(ctx);
                            toast(context, 'Resolution Saved: $decision');
                          }
                        } catch (e) {
                          setD(() => submitting = false);
                          if (ctx.mounted) toast(context, 'Failed: $e', error: true);
                        }
                      },
                child: submitting
                    ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2))
                    : Text('Save Resolution', style: DashboardTypography.inter(fontWeight: FontWeight.bold)),
              ),
            ],
          );
        },
      ),
    );
  }

  // Receive Product at Shop
  void _showReceiveAtShopDialog(CustomerReturn ret) {
    final auth = context.read<AuthController>();
    final inspectionCtrl = TextEditingController(text: 'Received and inspected. Working properly.');
    bool isReadyForCustomer = true;
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
              const Icon(Icons.store_rounded, color: Color(0xFF10B981)),
              const SizedBox(width: 10),
              Text(
                'Receive Product at Shop',
                style: DashboardTypography.poppins(fontSize: 16, fontWeight: FontWeight.bold, color: Colors.white),
              ),
            ],
          ),
          content: SizedBox(
            width: 480,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Confirm physical arrival of the repaired/replacement product at shop from vendor.',
                  style: DashboardTypography.inter(fontSize: 12, color: DashboardColors.textMuted),
                ),
                const SizedBox(height: 16),
                _buildFormInput('Quality Check & Inspection Notes *', inspectionCtrl, 'Inspection remarks', maxLines: 3),
                const SizedBox(height: 14),
                CheckboxListTile(
                  contentPadding: EdgeInsets.zero,
                  value: isReadyForCustomer,
                  activeColor: DashboardColors.neonGreen,
                  title: Text(
                    'Mark as "Ready for Customer Pickup"',
                    style: DashboardTypography.inter(fontSize: 13, fontWeight: FontWeight.w600, color: Colors.white),
                  ),
                  subtitle: Text(
                    'Customer return status will update to Ready for Customer',
                    style: DashboardTypography.inter(fontSize: 11, color: DashboardColors.textMuted),
                  ),
                  onChanged: (val) => setD(() => isReadyForCustomer = val ?? true),
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
              style: FilledButton.styleFrom(backgroundColor: const Color(0xFF10B981)),
              onPressed: submitting
                  ? null
                  : () async {
                      setD(() => submitting = true);
                      try {
                        await ReturnService.instance.receiveAtShop(
                          returnKey: ret.key,
                          actorId: auth.uid,
                          actorName: auth.name.isNotEmpty ? auth.name : 'Staff',
                          actorRole: auth.isOwner ? 'Owner' : 'Staff',
                          inspectionNotes: inspectionCtrl.text.trim(),
                          isReadyForCustomer: isReadyForCustomer,
                        );
                        if (ctx.mounted) {
                          Navigator.pop(ctx);
                          toast(context, 'Product Received at Shop');
                        }
                      } catch (e) {
                        setD(() => submitting = false);
                        if (ctx.mounted) toast(context, 'Failed: $e', error: true);
                      }
                    },
              child: submitting
                  ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2))
                  : Text('Confirm Receipt', style: DashboardTypography.inter(fontWeight: FontWeight.bold)),
            ),
          ],
        ),
      ),
    );
  }

  // Return Product to Customer (Requirement 11)
  void _showReturnToCustomerDialog(CustomerReturn ret) {
    final auth = context.read<AuthController>();
    final confirmationCtrl = TextEditingController(text: 'Customer verified and tested working on delivery');
    final deliveryNotesCtrl = TextEditingController();
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
              const Icon(Icons.assignment_turned_in_rounded, color: Color(0xFF22C55E)),
              const SizedBox(width: 10),
              Text(
                'Return Product to Customer',
                style: DashboardTypography.poppins(fontSize: 16, fontWeight: FontWeight.bold, color: Colors.white),
              ),
            ],
          ),
          content: SizedBox(
            width: 480,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Records customer handover, sets status to "RETURNED TO CUSTOMER", and completes the return case.',
                  style: DashboardTypography.inter(fontSize: 12, color: DashboardColors.textMuted),
                ),
                const SizedBox(height: 16),
                _buildFormInput('Customer Confirmation *', confirmationCtrl, 'e.g. Tested and signed, OTP verified...'),
                const SizedBox(height: 12),
                _buildFormInput('Delivery Notes', deliveryNotesCtrl, 'Any delivery notes or handover details...', maxLines: 2),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: submitting ? null : () => Navigator.pop(ctx),
              child: Text('Cancel', style: DashboardTypography.inter(color: Colors.white70)),
            ),
            FilledButton(
              style: FilledButton.styleFrom(backgroundColor: const Color(0xFF22C55E)),
              onPressed: submitting
                  ? null
                  : () async {
                      if (confirmationCtrl.text.trim().isEmpty) {
                        toast(context, 'Please enter customer confirmation', error: true);
                        return;
                      }

                      setD(() => submitting = true);
                      try {
                        await ReturnService.instance.returnToCustomer(
                          returnKey: ret.key,
                          actorId: auth.uid,
                          actorName: auth.name.isNotEmpty ? auth.name : 'Staff',
                          actorRole: auth.isOwner ? 'Owner' : 'Staff',
                          customerConfirmation: confirmationCtrl.text.trim(),
                          deliveryNotes: deliveryNotesCtrl.text.trim().isNotEmpty ? deliveryNotesCtrl.text.trim() : null,
                        );
                        if (ctx.mounted) {
                          Navigator.pop(ctx);
                          toast(context, 'Return Case Successfully Completed!');
                        }
                      } catch (e) {
                        setD(() => submitting = false);
                        if (ctx.mounted) toast(context, 'Failed: $e', error: true);
                      }
                    },
              child: submitting
                  ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2))
                  : Text('Complete Case', style: DashboardTypography.inter(fontWeight: FontWeight.bold)),
            ),
          ],
        ),
      ),
    );
  }

  // Verify Warranty Modal (Requirement 3 & 14)
  void _showVerifyWarrantyDialog(CustomerReturn ret) {
    final auth = context.read<AuthController>();
    String selectedWarranty = ret.customerWarrantyStatus;
    final reasonCtrl = TextEditingController();
    bool submitting = false;

    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setD) => AlertDialog(
          backgroundColor: const Color(0xFF0F172A),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
          title: Row(
            children: [
              const Icon(Icons.security_rounded, color: DashboardColors.neonOrange),
              const SizedBox(width: 10),
              Text(
                'Warranty Decision & Approval',
                style: DashboardTypography.poppins(fontSize: 16, fontWeight: FontWeight.bold, color: Colors.white),
              ),
            ],
          ),
          content: SizedBox(
            width: 460,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Authorized Owner/Staff can approve, reject, or adjust customer warranty status with verifiable reasons.',
                  style: DashboardTypography.inter(fontSize: 12, color: DashboardColors.textMuted),
                ),
                const SizedBox(height: 16),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 14),
                  decoration: BoxDecoration(
                    color: const Color(0x26000000),
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: const Color(0x33FFFFFF)),
                  ),
                  child: DropdownButtonHideUnderline(
                    child: DropdownButton<String>(
                      isExpanded: true,
                      dropdownColor: const Color(0xFF1E293B),
                      value: selectedWarranty,
                      items: CustomerWarrantyStatus.all.map((w) {
                        return DropdownMenuItem(
                          value: w,
                          child: Text(w, style: DashboardTypography.inter(color: Colors.white, fontSize: 13)),
                        );
                      }).toList(),
                      onChanged: (val) {
                        if (val != null) setD(() => selectedWarranty = val);
                      },
                    ),
                  ),
                ),
                const SizedBox(height: 14),
                _buildFormInput('Reason / Notes *', reasonCtrl, 'e.g. Approved under goodwill, Invoice verified...', maxLines: 3),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: submitting ? null : () => Navigator.pop(ctx),
              child: Text('Cancel', style: DashboardTypography.inter(color: Colors.white70)),
            ),
            FilledButton(
              style: FilledButton.styleFrom(backgroundColor: DashboardColors.neonOrange),
              onPressed: submitting
                  ? null
                  : () async {
                      if (reasonCtrl.text.trim().isEmpty) {
                        toast(context, 'Please enter a decision reason', error: true);
                        return;
                      }

                      setD(() => submitting = true);
                      try {
                        await ReturnService.instance.verifyWarranty(
                          returnKey: ret.key,
                          newWarrantyStatus: selectedWarranty,
                          reasonNotes: reasonCtrl.text.trim(),
                          actorId: auth.uid,
                          actorName: auth.name.isNotEmpty ? auth.name : 'Staff',
                          actorRole: auth.isOwner ? 'Owner' : 'Staff',
                        );
                        if (ctx.mounted) {
                          Navigator.pop(ctx);
                          toast(context, 'Warranty Updated: $selectedWarranty');
                        }
                      } catch (e) {
                        setD(() => submitting = false);
                        if (ctx.mounted) toast(context, 'Failed: $e', error: true);
                      }
                    },
              child: submitting
                  ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2))
                  : Text('Save Decision', style: DashboardTypography.inter(fontWeight: FontWeight.bold)),
            ),
          ],
        ),
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // HELPERS
  // ---------------------------------------------------------------------------

  Widget _buildSectionHeader(String title, IconData icon, Color color) {
    return Row(
      children: [
        Icon(icon, color: color, size: 18),
        const SizedBox(width: 8),
        Text(
          title,
          style: DashboardTypography.poppins(
            fontSize: 12.5,
            fontWeight: FontWeight.w700,
            letterSpacing: 0.6,
            color: color,
          ),
        ),
      ],
    );
  }

  Widget _buildDetailRow(
    String label,
    String value, {
    bool highlight = false,
    Color? valueColor,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 150,
            child: Text(
              '$label:',
              style: DashboardTypography.inter(fontSize: 12, color: DashboardColors.textMuted),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: DashboardTypography.inter(
                fontSize: 12.5,
                fontWeight: highlight ? FontWeight.w700 : FontWeight.w500,
                color: valueColor ?? (highlight ? DashboardColors.neonBlue : Colors.white),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildFormInput(
    String label,
    TextEditingController ctrl,
    String hint, {
    int maxLines = 1,
    TextInputType? keyboardType,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: DashboardTypography.inter(fontSize: 11.5, fontWeight: FontWeight.w600, color: DashboardColors.textLight)),
        const SizedBox(height: 5),
        TextField(
          controller: ctrl,
          maxLines: maxLines,
          keyboardType: keyboardType,
          style: DashboardTypography.inter(color: Colors.white, fontSize: 13),
          decoration: InputDecoration(
            hintText: hint,
            hintStyle: DashboardTypography.inter(color: DashboardColors.textMuted, fontSize: 12),
            filled: true,
            fillColor: const Color(0x26000000),
            isDense: true,
            contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: const BorderSide(color: Color(0x33FFFFFF))),
            enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: const BorderSide(color: Color(0x33FFFFFF))),
            focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: const BorderSide(color: DashboardColors.neonBlue)),
          ),
        ),
      ],
    );
  }
}
