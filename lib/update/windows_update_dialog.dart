import 'package:flutter/material.dart';
import 'windows_update_models.dart';
import 'windows_update_service.dart';

/// Modal dialog providing the complete Windows update download, progress,
/// validation, and restart experience.
class WindowsUpdateDialog extends StatefulWidget {
  final GitHubReleaseInfo release;
  final String currentVersion;

  const WindowsUpdateDialog({
    super.key,
    required this.release,
    required this.currentVersion,
  });

  static Future<void> show(
    BuildContext context, {
    required GitHubReleaseInfo release,
    required String currentVersion,
  }) {
    return showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => WindowsUpdateDialog(
        release: release,
        currentVersion: currentVersion,
      ),
    );
  }

  @override
  State<WindowsUpdateDialog> createState() => _WindowsUpdateDialogState();
}

class _WindowsUpdateDialogState extends State<WindowsUpdateDialog> {
  final WindowsUpdateService _service = WindowsUpdateService.instance;

  @override
  void initState() {
    super.initState();
    _service.addListener(_onServiceUpdate);
  }

  @override
  void dispose() {
    _service.removeListener(_onServiceUpdate);
    super.dispose();
  }

  void _onServiceUpdate() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final status = _service.status;
    final isDownloading = status == WindowsUpdateStatus.downloading;
    final isReady = status == WindowsUpdateStatus.downloadComplete;
    final isFailed = status == WindowsUpdateStatus.failed;
    final isInstalling = status == WindowsUpdateStatus.installing;
    final progress = _service.downloadProgress;

    return PopScope(
      canPop: !isDownloading && !isInstalling,
      child: Dialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        elevation: 16,
        backgroundColor: isDark ? const Color(0xFF1E293B) : Colors.white,
        child: Container(
          width: 520,
          padding: const EdgeInsets.all(24),
          decoration: BoxDecoration(
            color: isDark ? const Color(0xFF1E293B) : Colors.white,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
              color: isDark ? const Color(0xFF334155) : const Color(0xFFE2E8F0),
            ),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Header
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: const Color(0xFF3B82F6).withAlpha(30),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: const Icon(
                      Icons.system_update_rounded,
                      color: Color(0xFF3B82F6),
                      size: 28,
                    ),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'പുതിയ അപ്ഡേറ്റ് ലഭ്യമാണ്! (Update Available)',
                          style: TextStyle(
                            fontSize: 17,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Row(
                          children: [
                            Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 8, vertical: 2),
                              decoration: BoxDecoration(
                                color: isDark
                                    ? const Color(0xFF334155)
                                    : const Color(0xFFF1F5F9),
                                borderRadius: BorderRadius.circular(6),
                              ),
                              child: Text(
                                'Current: v${widget.currentVersion}',
                                style: TextStyle(
                                  fontSize: 12,
                                  color: isDark ? Colors.white70 : Colors.black87,
                                ),
                              ),
                            ),
                            const SizedBox(width: 8),
                            const Icon(Icons.arrow_forward_rounded,
                                size: 14, color: Color(0xFF3B82F6)),
                            const SizedBox(width: 8),
                            Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 8, vertical: 2),
                              decoration: BoxDecoration(
                                color: const Color(0xFF10B981).withAlpha(30),
                                borderRadius: BorderRadius.circular(6),
                                border: Border.all(
                                    color: const Color(0xFF10B981).withAlpha(80)),
                              ),
                              child: Text(
                                'Latest: ${widget.release.tagName}',
                                style: const TextStyle(
                                  fontSize: 12,
                                  fontWeight: FontWeight.bold,
                                  color: Color(0xFF10B981),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                  if (!isDownloading && !isInstalling)
                    IconButton(
                      icon: const Icon(Icons.close_rounded, size: 20),
                      tooltip: 'Close',
                      onPressed: () {
                        _service.resetStatus();
                        Navigator.of(context).pop();
                      },
                    ),
                ],
              ),

              const SizedBox(height: 18),

              // Release notes
              if (widget.release.body.isNotEmpty) ...[
                const Text(
                  'പുതിയ മാറ്റങ്ങൾ (What\'s New):',
                  style: TextStyle(
                    fontWeight: FontWeight.w600,
                    fontSize: 13,
                  ),
                ),
                const SizedBox(height: 6),
                Container(
                  constraints: const BoxConstraints(maxHeight: 140),
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: isDark
                        ? const Color(0xFF0F172A)
                        : const Color(0xFFF8FAFC),
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(
                      color: isDark
                          ? const Color(0xFF334155)
                          : const Color(0xFFE2E8F0),
                    ),
                  ),
                  child: SingleChildScrollView(
                    child: Text(
                      widget.release.body,
                      style: TextStyle(
                        fontSize: 12.5,
                        height: 1.4,
                        color: isDark ? const Color(0xFFCBD5E1) : const Color(0xFF475569),
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 16),
              ],

              // Downloading Progress Section
              if (isDownloading) ...[
                Container(
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: const Color(0xFF3B82F6).withAlpha(15),
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: const Color(0xFF3B82F6).withAlpha(60)),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text(
                            progress.statusText.isNotEmpty
                                ? progress.statusText
                                : 'Downloading update...',
                            style: const TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                              color: Color(0xFF3B82F6),
                            ),
                          ),
                          Text(
                            '${progress.percentage}%',
                            style: const TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.bold,
                              color: Color(0xFF3B82F6),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 10),
                      ClipRRect(
                        borderRadius: BorderRadius.circular(6),
                        child: LinearProgressIndicator(
                          value: progress.progress > 0 ? progress.progress : null,
                          minHeight: 8,
                          backgroundColor: isDark
                              ? const Color(0xFF334155)
                              : const Color(0xFFE2E8F0),
                          valueColor: const AlwaysStoppedAnimation<Color>(
                              Color(0xFF3B82F6)),
                        ),
                      ),
                      const SizedBox(height: 8),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text(
                            '${progress.downloadedFormatted} / ${progress.totalFormatted}',
                            style: TextStyle(
                              fontSize: 12,
                              color: isDark ? Colors.white60 : Colors.black54,
                            ),
                          ),
                          Text(
                            progress.speedFormatted,
                            style: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w500,
                              color: isDark ? Colors.white60 : Colors.black54,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 16),
              ],

              // Ready to install notification
              if (isReady) ...[
                Container(
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: const Color(0xFF10B981).withAlpha(20),
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: const Color(0xFF10B981).withAlpha(80)),
                  ),
                  child: const Row(
                    children: [
                      Icon(Icons.check_circle_rounded,
                          color: Color(0xFF10B981), size: 24),
                      SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'Update Ready! (ഇൻസ്റ്റാളേഷൻ തയ്യാർ)',
                              style: TextStyle(
                                fontWeight: FontWeight.bold,
                                color: Color(0xFF10B981),
                                fontSize: 14,
                              ),
                            ),
                            SizedBox(height: 2),
                            Text(
                              'പുതിയ അപ്ഡേറ്റ് പ്രയോഗിക്കാൻ TekFix ERP റീസ്റ്റാർട്ട് ചെയ്യുക.\n(Restart TekFix ERP to apply the update automatically).',
                              style: TextStyle(fontSize: 12, height: 1.3),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 16),
              ],

              // Error display
              if (isFailed && _service.errorMessage != null) ...[
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: const Color(0xFFEF4444).withAlpha(20),
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: const Color(0xFFEF4444).withAlpha(80)),
                  ),
                  child: Row(
                    children: [
                      const Icon(Icons.error_outline_rounded,
                          color: Color(0xFFEF4444), size: 22),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          _service.errorMessage!,
                          style: const TextStyle(
                            color: Color(0xFFEF4444),
                            fontSize: 12.5,
                            height: 1.3,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 16),
              ],

              // Action buttons
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  // Cancel / Later Button
                  if (isDownloading)
                    TextButton.icon(
                      onPressed: () => _service.cancelDownload(),
                      icon: const Icon(Icons.cancel_outlined, size: 16),
                      label: const Text('റദ്ദാക്കുക (Cancel)'),
                    )
                  else if (!isInstalling)
                    TextButton(
                      onPressed: () {
                        _service.postponeUpdate();
                        Navigator.of(context).pop();
                      },
                      child: const Text('പിന്നീട് (Later)'),
                    ),

                  const SizedBox(width: 10),

                  // Primary Action Button
                  if (isReady)
                    FilledButton.icon(
                      style: FilledButton.styleFrom(
                        backgroundColor: const Color(0xFF10B981),
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(
                            horizontal: 20, vertical: 12),
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(10)),
                      ),
                      onPressed: isInstalling
                          ? null
                          : () {
                              _service.restartAndInstall();
                            },
                      icon: const Icon(Icons.restart_alt_rounded, size: 18),
                      label: const Text(
                        'റീസ്റ്റാർട്ട് & അപ്ഡേറ്റ് (Restart & Update)',
                        style: TextStyle(fontWeight: FontWeight.bold),
                      ),
                    )
                  else if (!isDownloading && !isInstalling)
                    FilledButton.icon(
                      style: FilledButton.styleFrom(
                        backgroundColor: const Color(0xFF3B82F6),
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(
                            horizontal: 20, vertical: 12),
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(10)),
                      ),
                      onPressed: () {
                        _service.downloadUpdate();
                      },
                      icon: Icon(
                        isFailed ? Icons.refresh_rounded : Icons.download_rounded,
                        size: 18,
                      ),
                      label: Text(
                        isFailed
                            ? 'വീണ്ടും ശ്രമിക്കുക (Retry)'
                            : 'ഉടൻ അപ്ഡേറ്റ് ചെയ്യുക (Update Now)',
                        style: const TextStyle(fontWeight: FontWeight.bold),
                      ),
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
