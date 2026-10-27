import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../theme/tek_tokens.dart';
import 'notification_models.dart';
import 'notification_service.dart';

class StaffNotificationsScreen extends StatefulWidget {
  final String shopId;
  final String staffId;
  final String staffName;
  final Function(int targetTab)? onNavigateTab;

  const StaffNotificationsScreen({
    super.key,
    required this.shopId,
    required this.staffId,
    required this.staffName,
    this.onNavigateTab,
  });

  @override
  State<StaffNotificationsScreen> createState() => _StaffNotificationsScreenState();
}

class _StaffNotificationsScreenState extends State<StaffNotificationsScreen> {
  String _selectedCategory = 'All'; // 'All', 'Announcements', 'Repairs', 'System'

  final List<String> _categories = [
    'All',
    'Announcements',
    'Repairs',
    'System',
  ];

  void _showNotificationDetails(TekNotification notif) {
    NotificationService.instance.markAsRead(widget.staffId, notif.id);

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: TekColors.bgCard,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(20),
          side: const BorderSide(color: TekColors.border),
        ),
        icon: Container(
          width: 50,
          height: 50,
          decoration: BoxDecoration(
            gradient: _getTypeGradient(notif.type),
            shape: BoxShape.circle,
          ),
          child: Icon(_getTypeIcon(notif.type), color: Colors.white, size: 26),
        ),
        title: Text(
          notif.title,
          textAlign: TextAlign.center,
          style: const TextStyle(
            color: TekColors.textPrimary,
            fontSize: 16,
            fontWeight: FontWeight.bold,
            fontFamilyFallback: TekTypography.malayalamFallback,
          ),
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  'From: ${notif.sender}',
                  style: const TextStyle(color: TekColors.secondary, fontSize: 12, fontWeight: FontWeight.bold),
                ),
                Text(
                  notif.timeFormatted,
                  style: const TextStyle(color: TekColors.textMuted, fontSize: 11),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: TekColors.bgSecondary,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: TekColors.border),
              ),
              child: Text(
                notif.message,
                style: const TextStyle(
                  color: TekColors.textPrimary,
                  fontSize: 13.5,
                  height: 1.45,
                  fontFamilyFallback: TekTypography.malayalamFallback,
                ),
              ),
            ),
            if (notif.isUrgent) ...[
              const SizedBox(height: 10),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                decoration: BoxDecoration(
                  color: TekColors.error.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: TekColors.error.withValues(alpha: 0.4)),
                ),
                child: const Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.warning_amber_rounded, size: 16, color: TekColors.error),
                    SizedBox(width: 6),
                    Text(
                      'URGENT PRIORITY (അടിയന്തിര ശ്രദ്ധയ്ക്ക്)',
                      style: TextStyle(
                        color: TekColors.error,
                        fontSize: 11,
                        fontWeight: FontWeight.bold,
                        fontFamilyFallback: TekTypography.malayalamFallback,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ],
        ),
        actions: [
          if (notif.type == NotificationType.repairUpdate && widget.onNavigateTab != null)
            TextButton(
              onPressed: () {
                Navigator.pop(ctx);
                widget.onNavigateTab!(1); // Go to Repairs tab
              },
              child: const Text('Go to Repairs (സർവീസിലേക്ക് പോകുക)'),
            ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: TekColors.primary),
            onPressed: () => Navigator.pop(ctx),
            child: const Text('ശരി (Close)'),
          ),
        ],
      ),
    );
  }

  void _showNewAnnouncementDialog() {
    final titleCtrl = TextEditingController();
    final msgCtrl = TextEditingController();
    bool isUrgent = false;

    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setD) => AlertDialog(
          backgroundColor: TekColors.bgCard,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(20),
            side: const BorderSide(color: TekColors.border),
          ),
          icon: const Icon(Icons.campaign_rounded, size: 38, color: TekColors.secondary),
          title: const Text(
            'New Announcement (അറിയിപ്പ് അയക്കുക)',
            style: TextStyle(
              color: TekColors.textPrimary,
              fontWeight: FontWeight.bold,
              fontSize: 16,
              fontFamilyFallback: TekTypography.malayalamFallback,
            ),
          ),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: titleCtrl,
                  style: const TextStyle(color: TekColors.textPrimary),
                  decoration: const InputDecoration(
                    labelText: 'Title (തലക്കെട്ട്)',
                    labelStyle: TextStyle(color: TekColors.textSecondary),
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: msgCtrl,
                  maxLines: 3,
                  style: const TextStyle(color: TekColors.textPrimary),
                  decoration: const InputDecoration(
                    labelText: 'Message (സന്ദേശം)',
                    labelStyle: TextStyle(color: TekColors.textSecondary),
                  ),
                ),
                const SizedBox(height: 12),
                CheckboxListTile(
                  contentPadding: EdgeInsets.zero,
                  value: isUrgent,
                  onChanged: (v) => setD(() => isUrgent = v ?? false),
                  title: const Text(
                    'Mark as Urgent (അടിയന്തിരം)',
                    style: TextStyle(color: TekColors.textPrimary, fontSize: 13),
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Cancel', style: TextStyle(color: TekColors.textSecondary)),
            ),
            FilledButton(
              style: FilledButton.styleFrom(backgroundColor: TekColors.primary),
              onPressed: () async {
                if (titleCtrl.text.trim().isEmpty || msgCtrl.text.trim().isEmpty) return;
                await NotificationService.instance.sendAnnouncement(
                  shopId: widget.shopId,
                  title: titleCtrl.text.trim(),
                  message: msgCtrl.text.trim(),
                  priority: isUrgent ? NotificationPriority.urgent : NotificationPriority.normal,
                  sender: widget.staffName.isNotEmpty ? widget.staffName : 'Staff Member',
                  staffId: widget.staffId,
                );
                if (ctx.mounted) Navigator.pop(ctx);
              },
              child: const Text('Broadcast'),
            ),
          ],
        ),
      ),
    );
  }

  IconData _getTypeIcon(NotificationType type) {
    switch (type) {
      case NotificationType.announcement:
        return Icons.campaign_rounded;
      case NotificationType.repairUpdate:
        return Icons.build_circle_rounded;
      case NotificationType.systemAlert:
        return Icons.bolt_rounded;
      case NotificationType.attendance:
        return Icons.how_to_reg_rounded;
    }
  }

  LinearGradient _getTypeGradient(NotificationType type) {
    switch (type) {
      case NotificationType.announcement:
        return TekColors.primaryGradient;
      case NotificationType.repairUpdate:
        return const LinearGradient(
          colors: [Color(0xFF0D9488), Color(0xFF14B8A6)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        );
      case NotificationType.systemAlert:
        return const LinearGradient(
          colors: [TekColors.warning, Color(0xFFF59E0B)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        );
      case NotificationType.attendance:
        return const LinearGradient(
          colors: [TekColors.success, Color(0xFF16A34A)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        );
    }
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
              'Alerts & Notifications',
              style: TekTypography.titleMedium.copyWith(fontSize: 18),
            ),
            const Text(
              'അറിയിപ്പുകൾ • Real-time Listener',
              style: TextStyle(
                fontSize: 11,
                color: TekColors.textSecondary,
                fontFamilyFallback: TekTypography.malayalamFallback,
              ),
            ),
          ],
        ),
        actions: [
          IconButton(
            tooltip: 'Post Announcement',
            icon: const Icon(Icons.add_comment_rounded, color: TekColors.secondary, size: 21),
            onPressed: _showNewAnnouncementDialog,
          ),
          const SizedBox(width: 6),
        ],
      ),
      body: StreamBuilder<List<TekNotification>>(
        stream: NotificationService.instance.streamNotifications(widget.shopId, widget.staffId),
        builder: (context, snapshot) {
          final allNotifs = snapshot.data ?? [];
          final unreadNotifs = allNotifs.where((n) => !n.isRead).toList();

          // Filter by category
          final filtered = allNotifs.where((n) {
            if (_selectedCategory == 'All') return true;
            if (_selectedCategory == 'Announcements') {
              return n.type == NotificationType.announcement;
            }
            if (_selectedCategory == 'Repairs') {
              return n.type == NotificationType.repairUpdate;
            }
            if (_selectedCategory == 'System') {
              return n.type == NotificationType.systemAlert || n.type == NotificationType.attendance;
            }
            return true;
          }).toList();

          return Column(
            children: [
              // Header Summary Bar: Unread Count Pill & Mark All As Read
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 6, 16, 10),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                      decoration: BoxDecoration(
                        color: unreadNotifs.isNotEmpty
                            ? TekColors.primary.withValues(alpha: 0.18)
                            : TekColors.bgSecondary,
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(
                          color: unreadNotifs.isNotEmpty
                              ? TekColors.primary.withValues(alpha: 0.5)
                              : TekColors.border,
                        ),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            Icons.mark_email_unread_rounded,
                            size: 14,
                            color: unreadNotifs.isNotEmpty ? TekColors.secondary : TekColors.textMuted,
                          ),
                          const SizedBox(width: 6),
                          Text(
                            unreadNotifs.isNotEmpty
                                ? '${unreadNotifs.length} പുതിയ അറിയിപ്പുകൾ (Unread)'
                                : 'All Caught Up (എല്ലാം കണ്ടു)',
                            style: TextStyle(
                              fontSize: 11.5,
                              fontWeight: FontWeight.bold,
                              color: unreadNotifs.isNotEmpty ? TekColors.secondary : TekColors.textSecondary,
                              fontFamilyFallback: TekTypography.malayalamFallback,
                            ),
                          ),
                        ],
                      ),
                    ),

                    if (unreadNotifs.isNotEmpty)
                      GestureDetector(
                        onTap: () {
                          HapticFeedback.lightImpact();
                          NotificationService.instance.markAllAsRead(
                            widget.staffId,
                            unreadNotifs.map((e) => e.id).toList(),
                          );
                        },
                        child: const Row(
                          children: [
                            Icon(Icons.done_all_rounded, size: 16, color: TekColors.secondary),
                            SizedBox(width: 4),
                            Text(
                              'Mark all as read',
                              style: TextStyle(fontSize: 11, color: TekColors.secondary, fontWeight: FontWeight.bold),
                            ),
                          ],
                        ),
                      ),
                  ],
                ),
              ),

              // Category Filter Chips
              SizedBox(
                height: 40,
                child: ListView.separated(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  itemCount: _categories.length,
                  separatorBuilder: (_, __) => const SizedBox(width: 8),
                  itemBuilder: (ctx, idx) {
                    final cat = _categories[idx];
                    final isSelected = _selectedCategory == cat;
                    return ChoiceChip(
                      label: Text(
                        cat,
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
                          setState(() => _selectedCategory = cat);
                        }
                      },
                    );
                  },
                ),
              ),

              const SizedBox(height: 10),

              // Notification List
              Expanded(
                child: snapshot.connectionState == ConnectionState.waiting && allNotifs.isEmpty
                    ? const Center(
                        child: CircularProgressIndicator(color: TekColors.primary),
                      )
                    : filtered.isEmpty
                        ? _buildEmptyState()
                        : ListView.separated(
                            padding: const EdgeInsets.fromLTRB(16, 6, 16, 85),
                            physics: const BouncingScrollPhysics(),
                            itemCount: filtered.length,
                            separatorBuilder: (_, __) => const SizedBox(height: 10),
                            itemBuilder: (context, index) {
                              final notif = filtered[index];
                              return _buildNotificationCard(notif);
                            },
                          ),
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _buildNotificationCard(TekNotification notif) {
    final gradient = _getTypeGradient(notif.type);
    final icon = _getTypeIcon(notif.type);

    return InkWell(
      onTap: () => _showNotificationDetails(notif),
      borderRadius: BorderRadius.circular(18),
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: TekColors.bgCard,
          borderRadius: BorderRadius.circular(18),
          border: Border.all(
            color: !notif.isRead
                ? TekColors.primary.withValues(alpha: 0.6)
                : TekColors.border,
            width: !notif.isRead ? 1.4 : 1.0,
          ),
          boxShadow: !notif.isRead ? TekColors.cardShadow : null,
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Icon Badge
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                gradient: gradient,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Icon(icon, color: Colors.white, size: 20),
            ),
            const SizedBox(width: 12),

            // Content
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      // Sender & Priority
                      Row(
                        children: [
                          Text(
                            notif.sender,
                            style: const TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.bold,
                              color: TekColors.secondary,
                            ),
                          ),
                          if (notif.isUrgent) ...[
                            const SizedBox(width: 6),
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                              decoration: BoxDecoration(
                                color: TekColors.error.withValues(alpha: 0.2),
                                borderRadius: BorderRadius.circular(4),
                              ),
                              child: const Text(
                                'URGENT',
                                style: TextStyle(
                                  fontSize: 8.5,
                                  fontWeight: FontWeight.bold,
                                  color: TekColors.error,
                                ),
                              ),
                            ),
                          ],
                        ],
                      ),

                      // Time & Unread dot
                      Row(
                        children: [
                          Text(
                            notif.timeFormatted,
                            style: const TextStyle(fontSize: 10.5, color: TekColors.textMuted),
                          ),
                          if (!notif.isRead) ...[
                            const SizedBox(width: 6),
                            Container(
                              width: 8,
                              height: 8,
                              decoration: const BoxDecoration(
                                color: TekColors.primary,
                                shape: BoxShape.circle,
                              ),
                            ),
                          ],
                        ],
                      ),
                    ],
                  ),

                  const SizedBox(height: 4),

                  // Title
                  Text(
                    notif.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 13.5,
                      fontWeight: !notif.isRead ? FontWeight.bold : FontWeight.w600,
                      color: TekColors.textPrimary,
                      fontFamilyFallback: TekTypography.malayalamFallback,
                    ),
                  ),

                  const SizedBox(height: 3),

                  // Message preview
                  Text(
                    notif.message,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 12,
                      color: !notif.isRead ? TekColors.textPrimary.withValues(alpha: 0.85) : TekColors.textSecondary,
                      height: 1.35,
                      fontFamilyFallback: TekTypography.malayalamFallback,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
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
            child: const Icon(Icons.notifications_off_rounded, size: 44, color: TekColors.textMuted),
          ),
          const SizedBox(height: 14),
          const Text(
            'അറിയിപ്പുകൾ ഒന്നും ലഭ്യമല്ല',
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.bold,
              color: TekColors.textPrimary,
              fontFamilyFallback: TekTypography.malayalamFallback,
            ),
          ),
          const SizedBox(height: 4),
          const Text(
            'No notifications in this category',
            style: TextStyle(fontSize: 12, color: TekColors.textSecondary),
          ),
        ],
      ),
    );
  }
}
