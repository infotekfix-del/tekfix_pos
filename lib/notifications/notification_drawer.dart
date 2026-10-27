import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../theme/tek_tokens.dart';
import 'notification_models.dart';
import 'notification_service.dart';

class NotificationDrawer extends StatelessWidget {
  final String shopId;
  final String staffId;
  final String staffName;
  final Function(int targetTab)? onNavigateTab;

  const NotificationDrawer({
    super.key,
    required this.shopId,
    required this.staffId,
    required this.staffName,
    this.onNavigateTab,
  });

  static Future<void> show(
    BuildContext context, {
    required String shopId,
    required String staffId,
    required String staffName,
    Function(int targetTab)? onNavigateTab,
  }) {
    HapticFeedback.mediumImpact();
    return showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => NotificationDrawer(
        shopId: shopId,
        staffId: staffId,
        staffName: staffName,
        onNavigateTab: onNavigateTab,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      height: MediaQuery.of(context).size.height * 0.75,
      padding: const EdgeInsets.fromLTRB(18, 16, 18, 20),
      decoration: const BoxDecoration(
        color: TekColors.bgCard,
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
        border: Border(top: BorderSide(color: TekColors.border, width: 1.5)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Drag handle
          Center(
            child: Container(
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: TekColors.border,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
          const SizedBox(height: 14),

          // Drawer Header
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
                    child: const Icon(Icons.notifications_active_rounded, color: Colors.white, size: 18),
                  ),
                  const SizedBox(width: 10),
                  const Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Recent Alerts (അറിയിപ്പുകൾ)',
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.bold,
                          color: TekColors.textPrimary,
                          fontFamilyFallback: TekTypography.malayalamFallback,
                        ),
                      ),
                      Text(
                        'Live broadcast & repair updates',
                        style: TextStyle(fontSize: 11, color: TekColors.textSecondary),
                      ),
                    ],
                  ),
                ],
              ),
              IconButton(
                icon: const Icon(Icons.close_rounded, color: TekColors.textSecondary),
                onPressed: () => Navigator.pop(context),
              ),
            ],
          ),

          const Divider(height: 20, color: TekColors.border),

          // Stream Notifications List
          Expanded(
            child: StreamBuilder<List<TekNotification>>(
              stream: NotificationService.instance.streamNotifications(shopId, staffId),
              builder: (context, snapshot) {
                if (snapshot.connectionState == ConnectionState.waiting && !snapshot.hasData) {
                  return const Center(
                    child: CircularProgressIndicator(color: TekColors.primary),
                  );
                }

                final list = snapshot.data ?? [];
                if (list.isEmpty) {
                  return const Center(
                    child: Text(
                      'പുതിയ അറിയിപ്പുകൾ ഒന്നും ലഭ്യമല്ല',
                      style: TextStyle(
                        fontSize: 13,
                        color: TekColors.textSecondary,
                        fontFamilyFallback: TekTypography.malayalamFallback,
                      ),
                    ),
                  );
                }

                return ListView.separated(
                  physics: const BouncingScrollPhysics(),
                  itemCount: list.length,
                  separatorBuilder: (_, __) => const SizedBox(height: 10),
                  itemBuilder: (context, index) {
                    final notif = list[index];
                    return InkWell(
                      onTap: () {
                        NotificationService.instance.markAsRead(staffId, notif.id);
                        if (notif.type == NotificationType.repairUpdate && onNavigateTab != null) {
                          Navigator.pop(context);
                          onNavigateTab!(1);
                        }
                      },
                      borderRadius: BorderRadius.circular(14),
                      child: Container(
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: TekColors.bgSecondary,
                          borderRadius: BorderRadius.circular(14),
                          border: Border.all(
                            color: !notif.isRead
                                ? TekColors.primary.withValues(alpha: 0.5)
                                : TekColors.border,
                          ),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                Text(
                                  notif.sender,
                                  style: const TextStyle(
                                    fontSize: 11,
                                    fontWeight: FontWeight.bold,
                                    color: TekColors.secondary,
                                  ),
                                ),
                                Text(
                                  notif.timeFormatted,
                                  style: const TextStyle(fontSize: 10, color: TekColors.textMuted),
                                ),
                              ],
                            ),
                            const SizedBox(height: 4),
                            Text(
                              notif.title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.bold,
                                color: TekColors.textPrimary,
                              ),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              notif.message,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(fontSize: 11.5, color: TekColors.textSecondary),
                            ),
                          ],
                        ),
                      ),
                    );
                  },
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}
