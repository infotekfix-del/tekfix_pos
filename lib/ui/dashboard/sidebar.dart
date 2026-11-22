import 'package:flutter/material.dart';
import '../../auth/auth_controller.dart';
import 'dashboard_tokens.dart';

/// Left sidebar (v2): grouped sections (Sales, Inventory & Service, Finance,
/// People, System), subtle active state with an accent bar, badge counts.
class TekSidebar extends StatelessWidget {
  final String activeItem;
  final ValueChanged<String>? onItemSelected;
  final int pendingAttendanceCount;
  final int pendingOrdersCount;
  final int overdueRemindersCount;

  const TekSidebar({
    super.key,
    this.activeItem = 'Dashboard',
    this.onItemSelected,
    this.pendingAttendanceCount = 0,
    this.pendingOrdersCount = 0,
    this.overdueRemindersCount = 0,
  });

  bool _isActive(String label) {
    if (label == 'Settings & Print') {
      return activeItem == 'Settings & Print' || activeItem == 'System Settings';
    }
    return activeItem == label;
  }

  Widget _item(String label, IconData icon,
      {int badgeCount = 0, Color badgeColor = DashboardColors.neonOrange}) {
    return _buildNavItem(
      label: label,
      icon: icon,
      isActive: _isActive(label),
      badgeCount: badgeCount,
      badgeColor: badgeColor,
      onTap: () => onItemSelected?.call(label),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isOwner = AuthController.instance.isOwner;
    return Container(
      width: 248,
      decoration: const BoxDecoration(
        color: Color(0xFF0E131D),
        border: Border(
          right: BorderSide(color: DashboardColors.border, width: 1),
        ),
      ),
      child: Column(
        children: [
          // 1. Logo & Brand Header
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 22, 20, 18),
            child: Row(
              children: [
                Container(
                  width: 36,
                  height: 36,
                  decoration: BoxDecoration(
                    color: DashboardColors.primaryBlue,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: const Center(
                    child: Icon(
                      Icons.bolt_rounded,
                      color: Colors.white,
                      size: 22,
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        'TekFix ERP',
                        style: DashboardTypography.inter(
                          fontSize: 16,
                          fontWeight: FontWeight.w700,
                          letterSpacing: -0.2,
                        ),
                      ),
                      const SizedBox(height: 1),
                      Text(
                        'Smarter Business Together',
                        style: DashboardTypography.inter(
                          fontSize: 11.5,
                          fontWeight: FontWeight.w400,
                          color: DashboardColors.textMuted,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),

          // 2. Navigation, grouped by what the shop does
          Expanded(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
              children: [
                _item('Dashboard', Icons.dashboard_rounded),

                _buildSectionHeader('SALES'),
                _item('Sale / POS', Icons.point_of_sale_rounded),
                _item('Daily Sales & EOD', Icons.receipt_long_rounded),
                // Phase 13.3.0 OWNER-ONLY RECHARGE POLICY
                if (isOwner) _item('Quick Recharge', Icons.flash_on_rounded),
                _item('Customer Returns', Icons.assignment_return_rounded),

                _buildSectionHeader('INVENTORY & SERVICE'),
                _item('Items / Stock', Icons.inventory_2_rounded),
                _item('Purchase Bills', Icons.description_rounded),
                _item('Services / Repairs', Icons.build_circle_rounded),
                _item('After-Sales Follow-ups', Icons.mark_chat_read_rounded),

                _buildSectionHeader('FINANCE'),
                _item(
                  'Payment Reminders',
                  Icons.notification_important_rounded,
                  badgeCount: overdueRemindersCount,
                  badgeColor: DashboardColors.neonPink,
                ),
                _item('Expenses', Icons.payments_rounded),
                _item('Daily Rent Ledger', Icons.calendar_today_rounded),
                _item('Owner Salary & Drawings', Icons.account_circle_rounded),

                _buildSectionHeader('PEOPLE'),
                _item('Customer Management', Icons.groups_rounded),
                // Offers to customers by WhatsApp (owner only; opens the CRM
                // offers screen registered as 'Customer Offers (WhatsApp)').
                if (isOwner)
                  _item('Customer Offers (WhatsApp)', Icons.campaign_rounded),
                _item(
                  'Staff Management',
                  Icons.badge_rounded,
                  badgeCount: pendingAttendanceCount,
                ),
                // Staff screens that were only in the old menu (owner only).
                if (isOwner) ...[
                  _item('Attendance Approvals', Icons.fact_check_rounded,
                      badgeCount: pendingAttendanceCount),
                  _item('Staff Live Tracking', Icons.monitor_heart_rounded),
                  _item('Staff Logins', Icons.manage_accounts_rounded),
                  _item('Staff Orders', Icons.shopping_basket_rounded),
                ],

                _buildSectionHeader('SYSTEM'),
                _item('Settings & Print', Icons.settings_rounded),
                _item('Backup & Sync', Icons.cloud_sync_rounded),
                _item('Audit / Change History', Icons.history_rounded),
                _item('App Updates & Releases', Icons.system_update_rounded),
                // Trusted Devices menu removed (owner decision 2026-11-18): device gate is off server-side.
              ],
            ),
          ),

          // 3. Footer
          Container(
            padding: const EdgeInsets.fromLTRB(20, 12, 20, 16),
            decoration: const BoxDecoration(
              border: Border(
                top: BorderSide(color: DashboardColors.border, width: 1),
              ),
            ),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    'Powered by Tekfix Digital',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: DashboardTypography.inter(
                      fontSize: 11.5,
                      fontWeight: FontWeight.w500,
                      color: DashboardColors.textMuted,
                    ),
                  ),
                ),
                Text(
                  'Since 2025',
                  style: DashboardTypography.inter(
                    fontSize: 11,
                    color: DashboardColors.textDarkMuted,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSectionHeader(String title) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 18, 12, 6),
      child: Text(
        title,
        style: DashboardTypography.inter(
          fontSize: 11,
          fontWeight: FontWeight.w600,
          color: DashboardColors.textDarkMuted,
          letterSpacing: 0.9,
        ),
      ),
    );
  }

  Widget _buildNavItem({
    required String label,
    required IconData icon,
    required bool isActive,
    required VoidCallback onTap,
    int badgeCount = 0,
    Color badgeColor = DashboardColors.neonOrange,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 1),
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(8),
        child: InkWell(
          borderRadius: BorderRadius.circular(8),
          hoverColor: const Color(0xFF171E2E),
          onTap: onTap,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 150),
            height: 40,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            decoration: BoxDecoration(
              color: isActive ? DashboardColors.accentBg : Colors.transparent,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Row(
              children: [
                // Active indicator bar
                AnimatedContainer(
                  duration: const Duration(milliseconds: 150),
                  width: 3,
                  height: isActive ? 18 : 0,
                  margin: const EdgeInsets.only(right: 9),
                  decoration: BoxDecoration(
                    color: DashboardColors.neonBlue,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
                Icon(
                  icon,
                  size: 18,
                  color: isActive
                      ? DashboardColors.neonBlue
                      : DashboardColors.textMuted,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: DashboardTypography.inter(
                      fontSize: 13.5,
                      fontWeight: isActive ? FontWeight.w600 : FontWeight.w500,
                      color: isActive
                          ? DashboardColors.textWhite
                          : const Color(0xFFB4BAC4),
                    ),
                  ),
                ),
                if (badgeCount > 0)
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                    decoration: BoxDecoration(
                      color: badgeColor.withValues(alpha: 0.16),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Text(
                      badgeCount > 99 ? '99+' : badgeCount.toString(),
                      style: DashboardTypography.inter(
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                        color: badgeColor,
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
