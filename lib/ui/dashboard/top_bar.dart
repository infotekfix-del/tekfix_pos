import 'package:flutter/material.dart';
import 'dashboard_tokens.dart';

/// Pixel-faithful top navigation bar for TekFix ERP.
/// Contains rounded search field (Ctrl + K), notification bell with red count badge,
/// and user avatar with "Tekfix" and dropdown.
class TekTopBar extends StatelessWidget {
  final VoidCallback? onSearchTap;
  final VoidCallback? onNotificationsTap;
  final VoidCallback? onProfileTap;
  final VoidCallback? onSignOut;
  final VoidCallback? onMenuTap;
  final int unreadNotificationsCount;
  final String userName;
  final String shopName;
  final bool showMenuButton;

  const TekTopBar({
    super.key,
    this.onSearchTap,
    this.onNotificationsTap,
    this.onProfileTap,
    this.onSignOut,
    this.onMenuTap,
    this.unreadNotificationsCount = 0,
    this.userName = 'Tekfix',
    this.shopName = 'Irumbuzhi, Kerala',
    this.showMenuButton = false,
  });

  @override
  Widget build(BuildContext context) {
    final screenWidth = MediaQuery.of(context).size.width;
    final isCompact = screenWidth < 500;
    final isUltraCompact = screenWidth < 400;

    return Container(
      height: 68,
      padding: EdgeInsets.symmetric(horizontal: isCompact ? 12 : 20),
      decoration: const BoxDecoration(
        color: Color(0x990B1030),
        border: Border(
          bottom: BorderSide(
            color: Color(0x1FFFFFFF),
            width: 1.0,
          ),
        ),
      ),
      child: Row(
        children: [
          // Mobile Menu Button (if visible)
          if (showMenuButton) ...[
            IconButton(
              tooltip: 'Open Menu',
              icon: const Icon(Icons.menu_rounded, color: Colors.white, size: 24),
              onPressed: onMenuTap,
            ),
            const SizedBox(width: 8),
          ],

          // Search Field (Rounded, with Ctrl + K)
          Expanded(
            child: Align(
              alignment: Alignment.centerLeft,
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 420),
                child: Material(
                  color: Colors.transparent,
                  child: InkWell(
                    borderRadius: BorderRadius.circular(22),
                    onTap: onSearchTap,
                    child: Container(
                      height: 42,
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      decoration: BoxDecoration(
                        color: const Color(0x1F1E293B),
                        borderRadius: BorderRadius.circular(22),
                        border: Border.all(
                          color: const Color(0x2BFFFFFF),
                          width: 1.0,
                        ),
                      ),
                      child: Row(
                        children: [
                          const Icon(
                            Icons.search_rounded,
                            size: 19,
                            color: Color(0xFF94A3B8),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Text(
                              'Search anything...',
                              style: DashboardTypography.inter(
                                fontSize: 13,
                                color: const Color(0xFF94A3B8),
                              ),
                            ),
                          ),
                          if (!isCompact)
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
                              decoration: BoxDecoration(
                                color: const Color(0x2EFFFFFF),
                                borderRadius: BorderRadius.circular(6),
                              ),
                              child: Text(
                                'Ctrl + K',
                                style: DashboardTypography.inter(
                                  fontSize: 10.5,
                                  fontWeight: FontWeight.w600,
                                  color: const Color(0xFFCBD5E1),
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),

          const SizedBox(width: 16),

          // Notification Bell with Red Count Badge
          Material(
            color: Colors.transparent,
            child: InkWell(
              borderRadius: BorderRadius.circular(12),
              onTap: onNotificationsTap,
              child: Container(
                width: 42,
                height: 42,
                decoration: BoxDecoration(
                  color: const Color(0x1F1E293B),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                    color: const Color(0x24FFFFFF),
                    width: 1.0,
                  ),
                ),
                child: Stack(
                  alignment: Alignment.center,
                  clipBehavior: Clip.none,
                  children: [
                    const Icon(
                      Icons.notifications_none_rounded,
                      color: Colors.white,
                      size: 21,
                    ),
                    if (unreadNotificationsCount > 0)
                      Positioned(
                        top: 7,
                        right: 7,
                        child: Container(
                          padding: const EdgeInsets.all(3),
                          decoration: const BoxDecoration(
                            color: DashboardColors.neonPink,
                            shape: BoxShape.circle,
                          ),
                          constraints: const BoxConstraints(
                            minWidth: 9,
                            minHeight: 9,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),

          const SizedBox(width: 16),

          // User Avatar & Name Dropdown
          PopupMenuButton<String>(
            tooltip: 'Profile Options',
            color: const Color(0xFF11183E),
            elevation: 8,
            offset: const Offset(0, 52),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(16),
              side: const BorderSide(color: Color(0x2BFFFFFF)),
            ),
            onSelected: (val) {
              if (val == 'signout') {
                onSignOut?.call();
              } else {
                onProfileTap?.call();
              }
            },
            itemBuilder: (context) => [
              PopupMenuItem<String>(
                enabled: false,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      userName,
                      style: DashboardTypography.inter(
                        fontSize: 14,
                        fontWeight: FontWeight.bold,
                        color: Colors.white,
                      ),
                    ),
                    Text(
                      shopName,
                      style: DashboardTypography.inter(
                        fontSize: 11,
                        color: DashboardColors.neonBlue,
                      ),
                    ),
                    const Divider(color: Color(0x1FFFFFFF)),
                  ],
                ),
              ),
              PopupMenuItem<String>(
                value: 'profile',
                child: Row(
                  children: [
                    const Icon(Icons.person_outline_rounded, size: 18, color: Colors.white70),
                    const SizedBox(width: 10),
                    Text('Business Profile', style: DashboardTypography.inter(fontSize: 13)),
                  ],
                ),
              ),
              PopupMenuItem<String>(
                value: 'signout',
                child: Row(
                  children: [
                    const Icon(Icons.logout_rounded, size: 18, color: DashboardColors.neonPink),
                    const SizedBox(width: 10),
                    Text('Sign Out', style: DashboardTypography.inter(fontSize: 13, color: DashboardColors.neonPink)),
                  ],
                ),
              ),
            ],
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              decoration: BoxDecoration(
                color: const Color(0x1F1E293B),
                borderRadius: BorderRadius.circular(22),
                border: Border.all(
                  color: const Color(0x24FFFFFF),
                  width: 1.0,
                ),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 32,
                    height: 32,
                    decoration: BoxDecoration(
                      gradient: DashboardColors.activePillGradient,
                      shape: BoxShape.circle,
                      boxShadow: [
                        BoxShadow(
                          color: DashboardColors.neonBlue.withValues(alpha: 0.35),
                          blurRadius: 8,
                        ),
                      ],
                    ),
                    child: Center(
                      child: Text(
                        userName.isNotEmpty ? userName[0].toUpperCase() : 'T',
                        style: DashboardTypography.poppins(
                          fontSize: 14,
                          fontWeight: FontWeight.bold,
                          color: Colors.white,
                        ),
                      ),
                    ),
                  ),
                  if (!isUltraCompact) ...[
                    const SizedBox(width: 8),
                    ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 90),
                      child: Text(
                        userName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: DashboardTypography.inter(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          color: Colors.white,
                        ),
                      ),
                    ),
                    const SizedBox(width: 4),
                    const Icon(
                      Icons.keyboard_arrow_down_rounded,
                      color: Color(0xFF94A3B8),
                      size: 18,
                    ),
                  ],
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
