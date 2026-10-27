import 'package:flutter/material.dart';
import 'dashboard_tokens.dart';

/// Pixel-faithful fixed left sidebar for TekFix ERP.
/// Features TEKFIX ERP logo, tagline, active gradient pill,
/// categorized sections, notification badges, and the footer card.
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

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 260,
      decoration: const BoxDecoration(
        color: Color(0xFF0C1236),
        border: Border(
          right: BorderSide(
            color: Color(0x1FFFFFFF),
            width: 1.2,
          ),
        ),
      ),
      child: Column(
        children: [
          // 1. Logo & Brand Header
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 24, 20, 20),
            child: Row(
              children: [
                Container(
                  width: 44,
                  height: 44,
                  decoration: BoxDecoration(
                    gradient: DashboardColors.activePillGradient,
                    borderRadius: BorderRadius.circular(14),
                    boxShadow: [
                      BoxShadow(
                        color: DashboardColors.neonBlue.withValues(alpha: 0.35),
                        blurRadius: 16,
                        offset: const Offset(0, 4),
                      ),
                    ],
                  ),
                  child: const Center(
                    child: Icon(
                      Icons.storefront_rounded,
                      color: Colors.white,
                      size: 24,
                    ),
                  ),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        'TEKFIX ERP',
                        style: DashboardTypography.poppins(
                          fontSize: 16,
                          fontWeight: FontWeight.w800,
                          letterSpacing: 0.8,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        'Smarter Business Together',
                        style: DashboardTypography.inter(
                          fontSize: 10.5,
                          fontWeight: FontWeight.w500,
                          color: DashboardColors.neonBlue,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),

          const Divider(
            height: 1,
            thickness: 1,
            color: Color(0x14FFFFFF),
            indent: 16,
            endIndent: 16,
          ),

          // 2. Navigation Menu Items
          Expanded(
            child: ListView(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
              children: [
                // Primary Core Navigation
                _buildNavItem(
                  label: 'Dashboard',
                  icon: Icons.dashboard_rounded,
                  isActive: activeItem == 'Dashboard',
                  onTap: () => onItemSelected?.call('Dashboard'),
                ),
                _buildNavItem(
                  label: 'Sale / POS',
                  icon: Icons.point_of_sale_rounded,
                  isActive: activeItem == 'Sale / POS',
                  onTap: () => onItemSelected?.call('Sale / POS'),
                ),
                _buildNavItem(
                  label: 'Items / Stock',
                  icon: Icons.inventory_2_rounded,
                  isActive: activeItem == 'Items / Stock',
                  onTap: () => onItemSelected?.call('Items / Stock'),
                ),
                _buildNavItem(
                  label: 'Services / Repairs',
                  icon: Icons.build_circle_rounded,
                  isActive: activeItem == 'Services / Repairs',
                  onTap: () => onItemSelected?.call('Services / Repairs'),
                ),
                _buildNavItem(
                  label: 'Customer Returns',
                  icon: Icons.assignment_return_rounded,
                  isActive: activeItem == 'Customer Returns',
                  onTap: () => onItemSelected?.call('Customer Returns'),
                ),
                _buildNavItem(
                  label: 'Purchase Bills',
                  icon: Icons.receipt_long_rounded,
                  isActive: activeItem == 'Purchase Bills',
                  onTap: () => onItemSelected?.call('Purchase Bills'),
                ),

                const SizedBox(height: 18),

                // Section 1: FINANCE & ACCOUNTS
                _buildSectionHeader('FINANCE & ACCOUNTS'),
                const SizedBox(height: 6),
                _buildNavItem(
                  label: 'Staff Management',
                  icon: Icons.people_alt_rounded,
                  isActive: activeItem == 'Staff Management',
                  badgeCount: pendingAttendanceCount,
                  onTap: () => onItemSelected?.call('Staff Management'),
                ),
                _buildNavItem(
                  label: 'Customer Management',
                  icon: Icons.groups_rounded,
                  isActive: activeItem == 'Customer Management',
                  onTap: () => onItemSelected?.call('Customer Management'),
                ),
                _buildNavItem(
                  label: 'Payment Reminders',
                  icon: Icons.notification_important_rounded,
                  isActive: activeItem == 'Payment Reminders',
                  badgeCount: overdueRemindersCount,
                  badgeColor: DashboardColors.neonPink,
                  onTap: () => onItemSelected?.call('Payment Reminders'),
                ),
                _buildNavItem(
                  label: 'After-Sales Follow-ups',
                  icon: Icons.mark_chat_read_rounded,
                  isActive: activeItem == 'After-Sales Follow-ups',
                  onTap: () => onItemSelected?.call('After-Sales Follow-ups'),
                ),
                _buildNavItem(
                  label: 'Settings & Print',
                  icon: Icons.receipt_long_rounded,
                  isActive: activeItem == 'Settings & Print',
                  onTap: () => onItemSelected?.call('Settings & Print'),
                ),

                const SizedBox(height: 18),

                // Section 2: SETTINGS & SYSTEM
                _buildSectionHeader('SETTINGS & SYSTEM'),
                const SizedBox(height: 6),
                _buildNavItem(
                  label: 'App Updates & Releases',
                  icon: Icons.system_update_rounded,
                  isActive: activeItem == 'App Updates & Releases',
                  onTap: () => onItemSelected?.call('App Updates & Releases'),
                ),
                _buildNavItem(
                  label: 'Backup & Sync',
                  icon: Icons.cloud_sync_rounded,
                  isActive: activeItem == 'Backup & Sync',
                  onTap: () => onItemSelected?.call('Backup & Sync'),
                ),
                _buildNavItem(
                  label: 'Audit / Change History',
                  icon: Icons.history_rounded,
                  isActive: activeItem == 'Audit / Change History',
                  onTap: () => onItemSelected?.call('Audit / Change History'),
                ),
                _buildNavItem(
                  label: 'Settings & Print',
                  icon: Icons.settings_suggest_rounded,
                  isActive: activeItem == 'System Settings',
                  onTap: () => onItemSelected?.call('System Settings'),
                ),
              ],
            ),
          ),

          // 3. Bottom Card: "Powered by Tekfix Digital, Since 2025"
          Padding(
            padding: const EdgeInsets.all(16),
            child: Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: const Color(0x1A1B2A55),
                borderRadius: BorderRadius.circular(16),
                border: Border.all(
                  color: const Color(0x2600D4FF),
                  width: 1,
                ),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.25),
                    blurRadius: 12,
                    offset: const Offset(0, 4),
                  ),
                ],
              ),
              child: Row(
                children: [
                  Container(
                    width: 32,
                    height: 32,
                    decoration: BoxDecoration(
                      color: DashboardColors.neonBlue.withValues(alpha: 0.15),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: const Center(
                      child: Icon(
                        Icons.bolt_rounded,
                        color: DashboardColors.neonBlue,
                        size: 18,
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          'Powered by Tekfix Digital',
                          style: DashboardTypography.inter(
                            fontSize: 11.5,
                            fontWeight: FontWeight.w700,
                            color: Colors.white,
                          ),
                        ),
                        const SizedBox(height: 1),
                        Text(
                          'Since 2025',
                          style: DashboardTypography.inter(
                            fontSize: 10,
                            fontWeight: FontWeight.w500,
                            color: DashboardColors.textMuted,
                          ),
                        ),
                      ],
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

  Widget _buildSectionHeader(String title) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      child: Text(
        title,
        style: DashboardTypography.inter(
          fontSize: 10.5,
          fontWeight: FontWeight.w800,
          color: const Color(0xFF6B7A99),
          letterSpacing: 1.1,
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
      padding: const EdgeInsets.symmetric(vertical: 2.5),
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(14),
        child: InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: onTap,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 180),
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            decoration: BoxDecoration(
              gradient: isActive ? DashboardColors.activePillGradient : null,
              color: isActive ? null : Colors.transparent,
              borderRadius: BorderRadius.circular(14),
              boxShadow: isActive
                  ? [
                      BoxShadow(
                        color: DashboardColors.primaryBlue.withValues(alpha: 0.45),
                        blurRadius: 14,
                        offset: const Offset(0, 4),
                      ),
                    ]
                  : null,
            ),
            child: Row(
              children: [
                Icon(
                  icon,
                  size: 19,
                  color: isActive ? Colors.white : const Color(0xFF8E9CB8),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    label,
                    style: DashboardTypography.inter(
                      fontSize: 13,
                      fontWeight: isActive ? FontWeight.w700 : FontWeight.w500,
                      color: isActive ? Colors.white : const Color(0xFFCBD5E1),
                    ),
                  ),
                ),
                if (badgeCount > 0)
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                    decoration: BoxDecoration(
                      color: badgeColor,
                      borderRadius: BorderRadius.circular(10),
                      boxShadow: [
                        BoxShadow(
                          color: badgeColor.withValues(alpha: 0.4),
                          blurRadius: 6,
                        ),
                      ],
                    ),
                    child: Text(
                      badgeCount.toString(),
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 10,
                        fontWeight: FontWeight.bold,
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
