import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../sync/sync_engine.dart';
import '../main.dart' show dtFormat;

/// Green tick = synced, rotating arrows = syncing, amber cloud = offline.
class SyncStatusIcon extends StatefulWidget {
  const SyncStatusIcon({super.key});
  @override
  State<SyncStatusIcon> createState() => _SyncStatusIconState();
}

class _SyncStatusIconState extends State<SyncStatusIcon>
    with SingleTickerProviderStateMixin {
  late final AnimationController _spin =
      AnimationController(vsync: this, duration: const Duration(seconds: 1));

  @override
  void dispose() {
    _spin.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final e = context.watch<SyncEngine>();
    final dark = Theme.of(context).brightness == Brightness.dark;
    late IconData icon;
    late Color color;
    late String label;
    switch (e.state) {
      case SyncState.synced:
        icon = Icons.cloud_done_rounded;
        color = dark ? Colors.greenAccent : Colors.green.shade700;
        label = 'Connected / Synced (സിങ്ക് ആയി)';
      case SyncState.syncing:
        icon = Icons.sync_rounded;
        color = dark ? Colors.lightBlueAccent : Colors.blue.shade700;
        label = 'Syncing… (${e.pending} pending)';
      case SyncState.offline:
        icon = Icons.cloud_off_rounded;
        color = Colors.amber.shade800;
        label = 'Offline — ${e.pending} saved on device (ഓഫ്‌ലൈൻ)';
      case SyncState.error:
        icon = Icons.error_outline_rounded;
        color = Colors.red.shade600;
        label = 'Sync problem: ${e.lastError ?? ''}';
    }
    if (e.state == SyncState.syncing) {
      if (!_spin.isAnimating) _spin.repeat();
    } else {
      _spin.stop();
    }
    return IconButton(
      tooltip: label,
      onPressed: () => _sheet(context, e, label),
      icon: AnimatedSwitcher(
        duration: const Duration(milliseconds: 250),
        child: RotationTransition(
          key: ValueKey(e.state),
          turns: e.state == SyncState.syncing
              ? _spin
              : const AlwaysStoppedAnimation(0),
          child: Icon(icon, color: color),
        ),
      ),
    );
  }

  void _sheet(BuildContext context, SyncEngine e, String label) {
    showModalBottomSheet(
      context: context,
      showDragHandle: true,
      builder: (ctx) => Padding(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
        child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(label,
                  style: const TextStyle(
                      fontWeight: FontWeight.w800, fontSize: 16)),
              const SizedBox(height: 8),
              Text('Pending uploads: ${e.pending}'),
              Text(
                  'Last synced: ${e.lastSyncAt == null ? '—' : dtFormat.format(e.lastSyncAt!)}'),
              if (e.needsSeedDecision) ...[
                const SizedBox(height: 12),
                const Text(
                    'ഈ ഉപകരണത്തിൽ പഴയ ഡാറ്റ ഉണ്ട്, ക്ലൗഡിൽ മറ്റൊരു ഉപകരണത്തിന്റെ ഡാറ്റ ഉണ്ട്.\nThis device has old local data and the cloud already has data from another device.'),
                const SizedBox(height: 8),
                FilledButton(
                  onPressed: () {
                    Navigator.pop(ctx);
                    e.discardLocalAndPull();
                  },
                  child: const Text('Discard local data & download from cloud'),
                ),
              ],
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  OutlinedButton.icon(
                    onPressed: () {
                      Navigator.pop(ctx);
                      e.recoverSyncQueue();
                    },
                    icon: const Icon(Icons.sync),
                    label: const Text('Sync Now / Retry Uploads'),
                  ),
                  if (e.pending > 0 || e.state == SyncState.error)
                    OutlinedButton.icon(
                      style: OutlinedButton.styleFrom(
                        foregroundColor: Colors.red.shade700,
                      ),
                      onPressed: () async {
                        final confirm = await showDialog<bool>(
                          context: context,
                          builder: (dCtx) => AlertDialog(
                            title: const Text('Clear Stuck Uploads?'),
                            content: Text(
                              'This will clear the ${e.pending} pending upload queue items without deleting any local sales, inventory, or bills on this device. Use this to unblock the sync engine.',
                            ),
                            actions: [
                              TextButton(
                                onPressed: () => Navigator.pop(dCtx, false),
                                child: const Text('Cancel'),
                              ),
                              FilledButton(
                                style: FilledButton.styleFrom(
                                  backgroundColor: Colors.red,
                                ),
                                onPressed: () => Navigator.pop(dCtx, true),
                                child: const Text('Clear Queue'),
                              ),
                            ],
                          ),
                        );
                        if (confirm == true) {
                          if (ctx.mounted) Navigator.pop(ctx);
                          await e.clearOutbox();
                          if (context.mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(
                                content: Text(
                                    'Sync outbox cleared. Pending uploads reset.'),
                              ),
                            );
                          }
                        }
                      },
                      icon: const Icon(Icons.cleaning_services_rounded),
                      label: Text('Clear Stuck Uploads (${e.pending})'),
                    ),
                ],
              ),
            ]),
      ),
    );
  }
}

/// Drop-in replacement for AppBar that appends the sync icon.
/// Use:  sed -i 's/appBar: AppBar(/appBar: TekAppBar(/' main.dart
class TekAppBar extends StatelessWidget implements PreferredSizeWidget {
  final Widget? title;
  final List<Widget>? actions;
  final PreferredSizeWidget? bottom;
  const TekAppBar({super.key, this.title, this.actions, this.bottom});

  @override
  Size get preferredSize =>
      Size.fromHeight(kToolbarHeight + (bottom?.preferredSize.height ?? 0));

  @override
  Widget build(BuildContext context) => AppBar(
        title: title,
        bottom: bottom,
        actions: [
          ...?actions,
          const SyncStatusIcon(),
          const SizedBox(width: 4)
        ],
      );
}
