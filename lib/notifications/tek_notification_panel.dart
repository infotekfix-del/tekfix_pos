import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../theme/tek_tokens.dart';
import 'notification_models.dart';
import 'notification_service.dart';

/// Enterprise slide-in Notification Panel with live alerts, unread filter, and direct action routing
class TekNotificationPanel extends StatefulWidget {
  final String shopId;
  final String staffId;
  final Function(int targetModuleIndex)? onNavigateModule;

  const TekNotificationPanel({
    super.key,
    required this.shopId,
    required this.staffId,
    this.onNavigateModule,
  });

  static Future<void> show(
    BuildContext context, {
    required String shopId,
    required String staffId,
    Function(int targetModuleIndex)? onNavigateModule,
  }) {
    HapticFeedback.lightImpact();
    return showDialog(
      context: context,
      barrierColor: Colors.black.withValues(alpha: 0.65),
      builder: (ctx) => Align(
        alignment: Alignment.centerRight,
        child: TekNotificationPanel(
          shopId: shopId,
          staffId: staffId,
          onNavigateModule: onNavigateModule,
        ),
      ),
    );
  }

  @override
  State<TekNotificationPanel> createState() => _TekNotificationPanelState();
}

class _TekNotificationPanelState extends State<TekNotificationPanel> {
  bool _onlyUnread = false;

  @override
  Widget build(BuildContext context) {
    final height = MediaQuery.of(context).size.height;

    return Container(
      width: 420,
      height: height,
      margin: const EdgeInsets.only(left: 40),
      decoration: BoxDecoration(
        color: TekColors.sidebarBg,
        border: const Border(left: BorderSide(color: TekColors.border, width: 1.5)),
        boxShadow: TekColors.floatingNavShadow,
      ),
      child: Material(
        color: Colors.transparent,
        child: StreamBuilder<List<TekNotification>>(
          stream: NotificationService.instance.streamNotifications(widget.shopId, widget.staffId),
          builder: (context, snap) {
            final allNotifications = snap.data ?? [];
            final unreadCount = allNotifications.where((n) => !n.isRead).length;

            final displayList = _onlyUnread
                ? allNotifications.where((n) => !n.isRead).toList()
                : allNotifications;

            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // Header
                Container(
                  padding: const EdgeInsets.fromLTRB(20, 20, 16, 16),
                  decoration: const BoxDecoration(
                    color: TekColors.cardBg,
                    border: Border(bottom: BorderSide(color: TekColors.border)),
                  ),
                  child: Column(
                    children: [
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Row(
                            children: [
                              Container(
                                padding: const EdgeInsets.all(8),
                                decoration: BoxDecoration(
                                  gradient: TekColors.cyanBlueGradient,
                                  borderRadius: BorderRadius.circular(10),
                                ),
                                child: const Icon(Icons.notifications_active_rounded, color: Colors.white, size: 18),
                              ),
                              const SizedBox(width: 12),
                              const Text(
                                'Notifications (അറിയിപ്പുകൾ)',
                                style: TextStyle(
                                  color: TekColors.textPrimary,
                                  fontSize: 16,
                                  fontWeight: FontWeight.bold,
                                  fontFamilyFallback: TekTypography.malayalamFallback,
                                ),
                              ),
                            ],
                          ),
                          IconButton(
                            icon: const Icon(Icons.close_rounded, color: TekColors.textSecondary, size: 20),
                            onPressed: () => Navigator.pop(context),
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      Row(
                        children: [
                          // Filter tab
                          ChoiceChip(
                            label: Text('All (${allNotifications.length})'),
                            selected: !_onlyUnread,
                            selectedColor: TekColors.primaryBlue.withValues(alpha: 0.25),
                            labelStyle: TextStyle(
                              color: !_onlyUnread ? TekColors.electricCyan : TekColors.textSecondary,
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                            ),
                            side: BorderSide(
                              color: !_onlyUnread ? TekColors.primaryBlue : TekColors.border,
                            ),
                            backgroundColor: TekColors.sidebarBg,
                            onSelected: (val) => setState(() => _onlyUnread = false),
                          ),
                          const SizedBox(width: 8),
                          ChoiceChip(
                            label: Text('Unread ($unreadCount)'),
                            selected: _onlyUnread,
                            selectedColor: TekColors.error.withValues(alpha: 0.2),
                            labelStyle: TextStyle(
                              color: _onlyUnread ? TekColors.error : TekColors.textSecondary,
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                            ),
                            side: BorderSide(
                              color: _onlyUnread ? TekColors.error : TekColors.border,
                            ),
                            backgroundColor: TekColors.sidebarBg,
                            onSelected: (val) => setState(() => _onlyUnread = true),
                          ),
                          const Spacer(),
                          if (unreadCount > 0)
                            TextButton.icon(
                              style: TextButton.styleFrom(
                                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                              ),
                              icon: const Icon(Icons.done_all_rounded, size: 16, color: TekColors.electricCyan),
                              label: const Text(
                                'Mark All Read',
                                style: TextStyle(
                                  color: TekColors.electricCyan,
                                  fontSize: 11.5,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              onPressed: () {
                                final ids = allNotifications.map((n) => n.id).toList();
                                NotificationService.instance.markAllAsRead(widget.staffId, ids);
                              },
                            ),
                        ],
                      ),
                    ],
                  ),
                ),

                // Notifications List
                Expanded(
                  child: displayList.isEmpty
                      ? Center(
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                _onlyUnread
                                    ? Icons.mark_email_read_rounded
                                    : Icons.notifications_none_rounded,
                                size: 48,
                                color: TekColors.textMuted.withValues(alpha: 0.6),
                              ),
                              const SizedBox(height: 12),
                              Text(
                                _onlyUnread
                                    ? 'എല്ലാ അറിയിപ്പുകളും വായിച്ചു കഴിഞ്ഞു!\n(No unread notifications)'
                                    : 'പുതിയ അറിയിപ്പുകൾ ഒന്നും ലഭ്യമല്ല.\n(No notifications available)',
                                textAlign: TextAlign.center,
                                style: const TextStyle(
                                  color: TekColors.textSecondary,
                                  fontSize: 13,
                                  height: 1.4,
                                  fontFamilyFallback: TekTypography.malayalamFallback,
                                ),
                              ),
                            ],
                          ),
                        )
                      : ListView.separated(
                          padding: const EdgeInsets.all(14),
                          itemCount: displayList.length,
                          separatorBuilder: (ctx, i) => const SizedBox(height: 10),
                          itemBuilder: (ctx, idx) {
                            final item = displayList[idx];
                            return _buildNotificationCard(item);
                          },
                        ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _buildNotificationCard(TekNotification n) {
    Color badgeColor;
    IconData badgeIcon;

    switch (n.priority) {
      case NotificationPriority.urgent:
        badgeColor = TekColors.error;
        badgeIcon = Icons.priority_high_rounded;
        break;
      case NotificationPriority.normal:
        badgeColor = TekColors.primaryBlue;
        badgeIcon = Icons.notifications_rounded;
        break;
      case NotificationPriority.info:
        badgeColor = TekColors.electricCyan;
        badgeIcon = Icons.info_outline_rounded;
        break;
    }

    return Container(
      decoration: BoxDecoration(
        color: n.isRead ? TekColors.cardBg : TekColors.elevatedSurface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: n.isRead ? TekColors.border : TekColors.primaryBlue.withValues(alpha: 0.5),
          width: n.isRead ? 1.0 : 1.4,
        ),
      ),
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(14),
        child: InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: () {
            NotificationService.instance.markAsRead(widget.staffId, n.id);
            _handleNotificationTap(n);
          },
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Container(
                      padding: const EdgeInsets.all(7),
                      decoration: BoxDecoration(
                        color: badgeColor.withValues(alpha: 0.18),
                        shape: BoxShape.circle,
                      ),
                      child: Icon(badgeIcon, size: 16, color: badgeColor),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            n.title,
                            style: TextStyle(
                              color: TekColors.textPrimary,
                              fontWeight: n.isRead ? FontWeight.w600 : FontWeight.bold,
                              fontSize: 13.5,
                              fontFamilyFallback: TekTypography.malayalamFallback,
                            ),
                          ),
                          const SizedBox(height: 3),
                          Text(
                            '${n.sender} • ${n.timeFormatted}',
                            style: const TextStyle(
                              color: TekColors.textMuted,
                              fontSize: 11,
                            ),
                          ),
                        ],
                      ),
                    ),
                    if (!n.isRead)
                      Container(
                        width: 8,
                        height: 8,
                        decoration: const BoxDecoration(
                          color: TekColors.error,
                          shape: BoxShape.circle,
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: 8),
                Text(
                  n.message,
                  style: const TextStyle(
                    color: TekColors.textSecondary,
                    fontSize: 12.5,
                    height: 1.35,
                    fontFamilyFallback: TekTypography.malayalamFallback,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  void _handleNotificationTap(TekNotification n) {
    Navigator.pop(context); // Close panel

    final action = n.metadata['action']?.toString() ?? '';
    final title = n.title.toLowerCase();

    if (action == 'staff_orders' || title.contains('ഓർഡർ') || title.contains('order')) {
      widget.onNavigateModule?.call(13); // OwnerOrdersView
    } else if (title.contains('അറ്റൻഡൻസ്') || title.contains('attendance')) {
      widget.onNavigateModule?.call(9); // OwnerAttendanceApprovalsView
    } else if (title.contains('റിപ്പയർ') || title.contains('repair') || title.contains('service')) {
      widget.onNavigateModule?.call(3); // ServicesView
    } else if (title.contains('ബാക്കി') || title.contains('reminder') || title.contains('payment')) {
      widget.onNavigateModule?.call(14); // RemindersScreen
    }
  }
}
