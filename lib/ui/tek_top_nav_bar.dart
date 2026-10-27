import 'dart:async';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';
import '../auth/auth_controller.dart';
import '../sync/sync_engine.dart';
import '../theme/tek_tokens.dart';
import '../notifications/notification_service.dart';
import '../notifications/tek_notification_panel.dart';
import 'tek_global_search_dialog.dart';
import 'tek_feedback.dart';

/// Enterprise Top Navigation Header with Search, Live Sync Status, Notifications, and Profile
class TekTopNavBar extends StatefulWidget {
  final bool isSidebarCollapsed;
  final VoidCallback onToggleSidebar;
  final Function(int moduleIndex)? onNavigateModule;

  const TekTopNavBar({
    super.key,
    required this.isSidebarCollapsed,
    required this.onToggleSidebar,
    this.onNavigateModule,
  });

  @override
  State<TekTopNavBar> createState() => _TekTopNavBarState();
}

class _TekTopNavBarState extends State<TekTopNavBar> {
  late DateTime _currentTime;
  Timer? _clockTimer;

  @override
  void initState() {
    super.initState();
    _currentTime = DateTime.now();
    _clockTimer = Timer.periodic(const Duration(seconds: 30), (_) {
      if (mounted) setState(() => _currentTime = DateTime.now());
    });
  }

  @override
  void dispose() {
    _clockTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthController>();
    final sync = context.watch<SyncEngine>();
    final isOwner = auth.isOwner;

    final dateStr = DateFormat('EEE, dd MMM').format(_currentTime);
    final timeStr = DateFormat('hh:mm a').format(_currentTime);

    return Container(
      height: 64,
      padding: const EdgeInsets.symmetric(horizontal: 16),
      decoration: const BoxDecoration(
        color: TekColors.sidebarBg,
        border: Border(bottom: BorderSide(color: TekColors.border, width: 1.2)),
      ),
      child: Row(
        children: [
          // 1. Sidebar Toggle Button
          IconButton(
            tooltip: widget.isSidebarCollapsed ? 'Expand Sidebar' : 'Collapse Sidebar',
            icon: Icon(
              widget.isSidebarCollapsed ? Icons.menu_rounded : Icons.menu_open_rounded,
              color: TekColors.textPrimary,
              size: 22,
            ),
            onPressed: widget.onToggleSidebar,
          ),
          const SizedBox(width: 12),

          // 2. Global Search Box with Ctrl+K shortcut
          Expanded(
            child: Align(
              alignment: Alignment.centerLeft,
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 380),
                child: Material(
                  color: TekColors.cardBg,
                  borderRadius: BorderRadius.circular(10),
                  child: InkWell(
                    borderRadius: BorderRadius.circular(10),
                    onTap: () => TekGlobalSearchDialog.show(
                      context,
                      onNavigate: widget.onNavigateModule,
                    ),
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(color: TekColors.border),
                      ),
                      child: Row(
                        children: [
                          const Icon(Icons.search_rounded, size: 18, color: TekColors.textMuted),
                          const SizedBox(width: 8),
                          const Expanded(
                            child: Text(
                              'Search anything...',
                              style: TextStyle(color: TekColors.textMuted, fontSize: 13),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                            decoration: BoxDecoration(
                              color: TekColors.sidebarBg,
                              borderRadius: BorderRadius.circular(5),
                              border: Border.all(color: TekColors.border),
                            ),
                            child: const Text(
                              'Ctrl K',
                              style: TextStyle(
                                color: TekColors.textMuted,
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
              ),
            ),
          ),

          const SizedBox(width: 12),

          // 3. Database Sync Status Indicator
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            decoration: BoxDecoration(
              color: TekColors.cardBg,
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: TekColors.border),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 8,
                  height: 8,
                  decoration: BoxDecoration(
                    color: sync.state == SyncState.syncing
                        ? TekColors.electricCyan
                        : (sync.state != SyncState.offline ? TekColors.success : TekColors.warning),
                    shape: BoxShape.circle,
                    boxShadow: [
                      BoxShadow(
                        color: (sync.state == SyncState.syncing ? TekColors.electricCyan : TekColors.success)
                            .withValues(alpha: 0.5),
                        blurRadius: 4,
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 6),
                Text(
                  sync.state == SyncState.syncing
                      ? 'Syncing...'
                      : (sync.state != SyncState.offline ? 'Cloud Synced' : 'Offline Mode'),
                  style: const TextStyle(
                    color: TekColors.textSecondary,
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),

          const SizedBox(width: 12),

          // 4. Current Date & Live Time
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            decoration: BoxDecoration(
              color: TekColors.cardBg,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: TekColors.border),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.access_time_rounded, size: 14, color: TekColors.textMuted),
                const SizedBox(width: 6),
                Text(
                  '$dateStr • $timeStr',
                  style: const TextStyle(
                    color: TekColors.textSecondary,
                    fontSize: 11.5,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ],
            ),
          ),

          const SizedBox(width: 12),

          // 5. Notification Bell with Smart Red Signal Badge
          StreamBuilder<int>(
            stream: NotificationService.instance.streamUnreadCount(auth.shopId, auth.uid),
            builder: (context, snap) {
              final count = snap.data ?? 0;
              return Stack(
                clipBehavior: Clip.none,
                children: [
                  IconButton(
                    tooltip: 'Notifications (അറിയിപ്പുകൾ)',
                    icon: const Icon(
                      Icons.notifications_none_rounded,
                      color: TekColors.textPrimary,
                      size: 22,
                    ),
                    onPressed: () => TekNotificationPanel.show(
                      context,
                      shopId: auth.shopId,
                      staffId: auth.uid,
                      onNavigateModule: widget.onNavigateModule,
                    ),
                  ),
                  if (count > 0)
                    Positioned(
                      top: 6,
                      right: 6,
                      child: TekRedSignalBadge(
                        count: count,
                        pulse: true,
                        size: 17,
                        onTap: () => TekNotificationPanel.show(
                          context,
                          shopId: auth.shopId,
                          staffId: auth.uid,
                          onNavigateModule: widget.onNavigateModule,
                        ),
                      ),
                    ),
                ],
              );
            },
          ),

          const SizedBox(width: 8),

          // 6. User Profile Avatar & Dropdown Menu
          PopupMenuButton<String>(
            color: TekColors.cardBg,
            elevation: 12,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(14),
              side: const BorderSide(color: TekColors.border),
            ),
            offset: const Offset(0, 50),
            tooltip: 'User Profile & Menu',
            itemBuilder: (ctx) => [
              PopupMenuItem(
                enabled: false,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      auth.name,
                      style: const TextStyle(
                        color: TekColors.textPrimary,
                        fontWeight: FontWeight.bold,
                        fontSize: 14,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      auth.email.isNotEmpty ? auth.email : 'Shop ID: ${auth.shopId}',
                      style: const TextStyle(
                        color: TekColors.textMuted,
                        fontSize: 11,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                      decoration: BoxDecoration(
                        gradient: isOwner ? TekColors.primaryGradient : null,
                        color: isOwner ? null : TekColors.elevatedSurface,
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Text(
                        isOwner ? 'OWNER / ADMIN' : 'STAFF MEMBER',
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 9.5,
                          fontWeight: FontWeight.bold,
                          letterSpacing: 0.5,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const PopupMenuDivider(),
              const PopupMenuItem(
                value: 'settings',
                child: Row(
                  children: [
                    Icon(Icons.settings_rounded, size: 16, color: TekColors.textSecondary),
                    SizedBox(width: 10),
                    Text('Settings & Print', style: TextStyle(color: TekColors.textPrimary, fontSize: 13)),
                  ],
                ),
              ),
              const PopupMenuItem(
                value: 'sync',
                child: Row(
                  children: [
                    Icon(Icons.cloud_sync_rounded, size: 16, color: TekColors.textSecondary),
                    SizedBox(width: 10),
                    Text('Backup & Sync', style: TextStyle(color: TekColors.textPrimary, fontSize: 13)),
                  ],
                ),
              ),
              const PopupMenuDivider(),
              const PopupMenuItem(
                value: 'logout',
                child: Row(
                  children: [
                    Icon(Icons.logout_rounded, size: 16, color: TekColors.error),
                    SizedBox(width: 10),
                    Text('Sign Out (പുറത്തുകടക്കുക)', style: TextStyle(color: TekColors.error, fontSize: 13)),
                  ],
                ),
              ),
            ],
            onSelected: (val) {
              if (val == 'logout') {
                auth.signOut();
              } else if (val == 'settings') {
                widget.onNavigateModule?.call(19); // SettingsView
              } else if (val == 'sync') {
                widget.onNavigateModule?.call(17); // BackupSyncView
              }
            },
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: BoxDecoration(
                color: TekColors.cardBg,
                borderRadius: BorderRadius.circular(24),
                border: Border.all(color: TekColors.border),
              ),
              child: Row(
                children: [
                  CircleAvatar(
                    radius: 14,
                    backgroundColor: TekColors.primaryBlue.withValues(alpha: 0.25),
                    child: Text(
                      auth.name.isNotEmpty ? auth.name[0].toUpperCase() : 'U',
                      style: const TextStyle(
                        color: TekColors.electricCyan,
                        fontSize: 12,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    auth.name.split(' ').first,
                    style: const TextStyle(
                      color: TekColors.textPrimary,
                      fontSize: 12.5,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(width: 4),
                  const Icon(Icons.arrow_drop_down_rounded, size: 18, color: TekColors.textSecondary),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
