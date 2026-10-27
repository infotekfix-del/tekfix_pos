import 'dart:async';
import 'dart:io';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:ota_update/ota_update.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:url_launcher/url_launcher.dart';

/// Holds metadata about an available application update.
class AppUpdateInfo {
  final String latestVersion;
  final int latestBuildNumber;
  final String apkUrl;
  final String releaseNotes;
  final bool isMandatory;
  final String? minSupportedVersion;

  AppUpdateInfo({
    required this.latestVersion,
    required this.latestBuildNumber,
    required this.apkUrl,
    required this.releaseNotes,
    this.isMandatory = true,
    this.minSupportedVersion,
  });

  factory AppUpdateInfo.fromFirestore(Map<String, dynamic> data) {
    final rawBuild = data['latest_build_number'];
    final buildNum = rawBuild is int
        ? rawBuild
        : int.tryParse(rawBuild?.toString() ?? '') ?? 0;

    return AppUpdateInfo(
      latestVersion: (data['latest_version'] ?? '1.0.0').toString().trim(),
      latestBuildNumber: buildNum,
      apkUrl: (data['apk_url'] ?? '').toString().trim(),
      releaseNotes: (data['release_notes'] ??
              'പുതിയ ഫീച്ചറുകളും പരിഹാരങ്ങളും ഉൾപ്പെടുത്തിയിട്ടുണ്ട്.\n(New features and performance improvements included.)')
          .toString(),
      isMandatory: data['is_mandatory'] ?? true,
      minSupportedVersion: data['min_supported_version']?.toString(),
    );
  }
}

/// Centralized service to manage In-App Auto-Updates via Firestore & OTA Installer.
class AppUpdateService {
  AppUpdateService._();
  static final AppUpdateService instance = AppUpdateService._();

  bool _isChecking = false;
  bool _dialogShowing = false;
  DateTime? _lastAutoCheck;

  /// Helper to compare semantic versions (e.g. "1.0.1" vs "1.0.0").
  static bool isVersionGreater(String remote, String current) {
    try {
      final vRemote = remote.split('+').first.trim();
      final vCurrent = current.split('+').first.trim();

      final rParts =
          vRemote.split('.').map((e) => int.tryParse(e) ?? 0).toList();
      final cParts =
          vCurrent.split('.').map((e) => int.tryParse(e) ?? 0).toList();

      final maxLen =
          rParts.length > cParts.length ? rParts.length : cParts.length;
      for (int i = 0; i < maxLen; i++) {
        final r = i < rParts.length ? rParts[i] : 0;
        final c = i < cParts.length ? cParts[i] : 0;
        if (r > c) return true;
        if (r < c) return false;
      }
    } catch (e) {
      debugPrint('Version comparison error: $e');
    }
    return false;
  }

  /// Checks Firestore for updates and returns [AppUpdateInfo] if a newer version is found.
  Future<AppUpdateInfo?> checkUpdateAvailable() async {
    try {
      final packageInfo = await PackageInfo.fromPlatform();
      final currentVersion = packageInfo.version;
      final currentBuild = int.tryParse(packageInfo.buildNumber) ?? 0;

      debugPrint(
          'AppUpdateService: Installed Version=$currentVersion, Build=$currentBuild');

      // 1. Ensure user is authenticated before querying protected Firestore config
      if (FirebaseAuth.instance.currentUser == null) {
        try {
          await FirebaseAuth.instance
              .authStateChanges()
              .firstWhere((u) => u != null)
              .timeout(const Duration(seconds: 3));
        } catch (_) {
          debugPrint('AppUpdateService: Auth wait timeout or offline session.');
        }
      }

      // 2. Fetch version config from Firestore (collection: app_config, doc: version)
      // Guarded with a 4-second timeout to prevent UI hang on slow/offline connections.
      final doc = await FirebaseFirestore.instance
          .collection('app_config')
          .doc('version')
          .get()
          .timeout(const Duration(seconds: 4));

      if (!doc.exists || doc.data() == null) {
        debugPrint('AppUpdateService: No app_config/version document found in Firestore.');
        return null;
      }

      final updateInfo = AppUpdateInfo.fromFirestore(doc.data()!);
      if (updateInfo.apkUrl.isEmpty) {
        debugPrint('AppUpdateService: apk_url is empty in config.');
        return null;
      }

      // Check if remote version or build is newer
      final isNewerBuild = updateInfo.latestBuildNumber > currentBuild;
      final isNewerVersion =
          isVersionGreater(updateInfo.latestVersion, currentVersion);

      if (isNewerBuild || isNewerVersion) {
        debugPrint(
            'AppUpdateService: Update available! Remote v${updateInfo.latestVersion}+${updateInfo.latestBuildNumber} > Current v$currentVersion+$currentBuild');
        return updateInfo;
      } else {
        debugPrint('AppUpdateService: App is up to date.');
        return null;
      }
    } catch (e) {
      debugPrint('AppUpdateService: Error checking for update: $e');
      return null;
    }
  }

  /// Convenience method to check and automatically display update dialog on app launch.
  Future<void> checkForUpdate(BuildContext context,
      {bool autoShowDialog = true, bool showToastIfLatest = false}) async {
    // Throttle automatic checks so repeated widget mounts do not trigger duplicate queries
    if (autoShowDialog) {
      final now = DateTime.now();
      if (_lastAutoCheck != null && now.difference(_lastAutoCheck!).inMinutes < 15) {
        return;
      }
      _lastAutoCheck = now;
    }

    if (_isChecking || _dialogShowing) return;
    _isChecking = true;

    try {
      final info = await checkUpdateAvailable();

      if (!context.mounted) return;

      if (info != null) {
        if (autoShowDialog) {
          _dialogShowing = true;
          try {
            final packageInfo = await PackageInfo.fromPlatform();
            if (!context.mounted) return;

            await showDialog(
              context: context,
              barrierDismissible: !info.isMandatory,
              builder: (ctx) => AppUpdateDialog(
                updateInfo: info,
                currentVersion: '${packageInfo.version}+${packageInfo.buildNumber}',
              ),
            );
          } finally {
            _dialogShowing = false;
          }
        }
      } else if (showToastIfLatest) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Row(
              children: [
                Icon(Icons.check_circle_rounded, color: Colors.greenAccent),
                SizedBox(width: 10),
                Text('ആപ്പ് ഏറ്റവും പുതിയ പതിപ്പിലാണ് (App is up to date)'),
              ],
            ),
            duration: Duration(seconds: 3),
          ),
        );
      }
    } catch (e) {
      debugPrint('AppUpdateService: check error: $e');
    } finally {
      _isChecking = false;
    }
  }
}

/// The interactive Update Dialog showing download progress and installer actions.
class AppUpdateDialog extends StatefulWidget {
  final AppUpdateInfo updateInfo;
  final String currentVersion;

  const AppUpdateDialog({
    super.key,
    required this.updateInfo,
    required this.currentVersion,
  });

  @override
  State<AppUpdateDialog> createState() => _AppUpdateDialogState();
}

class _AppUpdateDialogState extends State<AppUpdateDialog> {
  bool _isDownloading = false;
  int _progress = 0;
  String _statusText = 'ഒരു പുതിയ പതിപ്പ് ലഭ്യമാണ്. ഉടൻ അപ്ഡേറ്റ് ചെയ്യുക.';
  String? _errorMessage;
  StreamSubscription<OtaEvent>? _otaSubscription;

  @override
  void dispose() {
    _otaSubscription?.cancel();
    super.dispose();
  }

  Future<void> _startUpdate() async {
    final apkUrl = widget.updateInfo.apkUrl.trim();
    if (apkUrl.isEmpty) {
      setState(() => _errorMessage =
          'APK URL ലഭ്യമല്ല (APK URL is missing in update config).');
      return;
    }

    // Check platform
    if (!kIsWeb && !Platform.isAndroid) {
      // For Windows or desktop, launch browser directly to download
      await _downloadViaBrowser();
      return;
    }

    // Clean up any stale subscription or previous running download
    try {
      await _otaSubscription?.cancel();
      _otaSubscription = null;
      await OtaUpdate().cancel().catchError((_) {});
    } catch (_) {}

    setState(() {
      _isDownloading = true;
      _errorMessage = null;
      _progress = 0;
      _statusText = 'ഡൗൺലോഡ് ആരംഭിക്കുന്നു (Connecting to server)...';
    });

    try {
      final packageInfo = await PackageInfo.fromPlatform();
      final authority = '${packageInfo.packageName}.ota_update_provider';

      debugPrint('AppUpdateService: Starting OTA update download from: $apkUrl');
      debugPrint('AppUpdateService: Provider authority: $authority');

      _otaSubscription = OtaUpdate()
          .execute(
        apkUrl,
        destinationFilename: 'tekfix_update.apk',
        androidProviderAuthority: authority,
      )
          .listen(
        (OtaEvent event) {
          if (!mounted) return;
          debugPrint(
              'AppUpdateService: OTA event received -> status=${event.status}, value=${event.value}');
          switch (event.status) {
            case OtaStatus.DOWNLOADING:
              final p = int.tryParse(event.value ?? '0') ?? 0;
              setState(() {
                _progress = p;
                _statusText = 'ഡൗൺലോഡ് ചെയ്യുന്നു: $p% (Downloading APK...)';
              });
              break;
            case OtaStatus.INSTALLING:
              setState(() {
                _isDownloading = false;
                _progress = 100;
                _statusText =
                    'ഇൻസ്റ്റാളർ തുറക്കുന്നു... ഫോണിൽ "Install" ടാപ്പ് ചെയ്യുക.\n(Launching installer... Tap "Install" on prompt)';
              });
              break;
            case OtaStatus.INSTALLATION_DONE:
              setState(() {
                _isDownloading = false;
                _progress = 100;
                _statusText =
                    'ഇൻസ്റ്റാളേഷൻ പൂർത്തിയായി (Installation completed).';
              });
              break;
            case OtaStatus.ALREADY_RUNNING_ERROR:
              setState(() {
                _statusText =
                    'ഡൗൺലോഡ് ഇതിനകം നടക്കുന്നുണ്ട് (Download already running)...';
              });
              break;
            case OtaStatus.PERMISSION_NOT_GRANTED_ERROR:
              setState(() {
                _isDownloading = false;
                _errorMessage =
                    'ഇൻസ്റ്റാളേഷൻ അനുമതിയില്ല. Android Settings-ൽ "Install unknown apps" അനുമതി നൽകുക.\n(Permission denied. Enable "Install unknown apps" for TekFix in Settings).\nവിശദാംശം: ${event.value ?? "Permission required"}';
              });
              break;
            case OtaStatus.CANCELED:
              setState(() {
                _isDownloading = false;
                _statusText =
                    'ഡൗൺലോഡ് റദ്ദാക്കി (Download cancelled)';
              });
              break;
            case OtaStatus.INTERNAL_ERROR:
            case OtaStatus.DOWNLOAD_ERROR:
            case OtaStatus.CHECKSUM_ERROR:
            case OtaStatus.INSTALLATION_ERROR:
              final detail =
                  (event.value != null && event.value!.trim().isNotEmpty)
                      ? ' (${event.value})'
                      : '';
              setState(() {
                _isDownloading = false;
                _errorMessage =
                    'ഡൗൺലോഡ് / ഇൻസ്റ്റാളേഷൻ പരാജയപ്പെട്ടു: ${event.status.name}$detail.\nഇൻറർനെറ്റ് കണക്ഷൻ പരിശോധിക്കുക അല്ലെങ്കിൽ താഴെ "ബ്രൗസർ വഴി" ടാപ്പ് ചെയ്ത് നേരിട്ട് ഇൻസ്റ്റാൾ ചെയ്യുക.\n(Download failed. Check your connection or tap "Browser" below to download directly).';
              });
              break;
          }
        },
        onError: (e) {
          if (!mounted) return;
          debugPrint('AppUpdateService: Stream onError: $e');
          setState(() {
            _isDownloading = false;
            _errorMessage =
                'അപ്ഡേറ്റ് പിശക് (Stream error): $e\nതാഴെ "ബ്രൗസർ വഴി" ടാപ്പ് ചെയ്ത് നേരിട്ട് ഡൗൺലോഡ് ചെയ്യുക.';
          });
        },
        cancelOnError: true,
      );
    } catch (e) {
      if (!mounted) return;
      debugPrint('AppUpdateService: execute catch error: $e');
      setState(() {
        _isDownloading = false;
        _errorMessage =
            'അപ്ഡേറ്റ് തുടങ്ങാൻ സാധിച്ചില്ല: $e\nതാഴെ "ബ്രൗസർ വഴി" ടാപ്പ് ചെയ്ത് നേരിട്ട് ഡൗൺലോഡ് ചെയ്യുക.';
      });
    }
  }

  Future<void> _downloadViaBrowser() async {
    final rawUrl = widget.updateInfo.apkUrl.trim();
    if (rawUrl.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('APK URL ലഭ്യമല്ല (APK URL is missing)'),
            backgroundColor: Colors.red,
          ),
        );
      }
      return;
    }

    final uri = Uri.parse(rawUrl);
    debugPrint(
        'AppUpdateService: Opening external browser for APK download: $rawUrl');

    try {
      final launched = await launchUrl(
        uri,
        mode: LaunchMode.externalApplication,
      );

      if (!launched) {
        final fallback = await launchUrl(
          uri,
          mode: LaunchMode.platformDefault,
        );
        if (!fallback && mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('ബ്രൗസർ തുറക്കാൻ സാധിച്ചില്ല. URL:\n$rawUrl'),
              backgroundColor: Colors.red.shade700,
              duration: const Duration(seconds: 8),
            ),
          );
        }
      }
    } catch (e) {
      debugPrint('AppUpdateService: Could not launch browser URL: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('ബ്രൗസർ തുറക്കാൻ സാധിച്ചില്ല: $e\nURL: $rawUrl'),
            backgroundColor: Colors.red.shade700,
            duration: const Duration(seconds: 8),
          ),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isMandatory = widget.updateInfo.isMandatory;

    return PopScope(
      canPop: !isMandatory && !_isDownloading,
      child: Dialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        elevation: 12,
        child: Container(
          width: 440,
          padding: const EdgeInsets.all(24),
          decoration: BoxDecoration(
            color: theme.colorScheme.surface,
            borderRadius: BorderRadius.circular(20),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Header Icon and Badge
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: const Color(0xFF2563EB).withAlpha(30),
                      shape: BoxShape.circle,
                    ),
                    child: const Icon(
                      Icons.system_update_rounded,
                      color: Color(0xFF2563EB),
                      size: 32,
                    ),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            const Text(
                              'ആപ്പ് അപ്ഡേറ്റ് (App Update)',
                              style: TextStyle(
                                fontSize: 18,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                            if (isMandatory) ...[
                              const SizedBox(width: 8),
                              Container(
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 6, vertical: 2),
                                decoration: BoxDecoration(
                                  color: Colors.red.withAlpha(30),
                                  borderRadius: BorderRadius.circular(6),
                                  border: Border.all(
                                      color: Colors.red.withAlpha(100)),
                                ),
                                child: const Text(
                                  'MANDATORY',
                                  style: TextStyle(
                                    color: Colors.red,
                                    fontSize: 9.5,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                              ),
                            ]
                          ],
                        ),
                        const SizedBox(height: 4),
                        Text(
                          'v${widget.currentVersion} ➔ v${widget.updateInfo.latestVersion}',
                          style: TextStyle(
                            fontSize: 13,
                            color: theme.colorScheme.onSurfaceVariant,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),

              const SizedBox(height: 18),

              // Status / Instruction Text
              Text(
                _statusText,
                style: const TextStyle(fontSize: 13.5, height: 1.4),
              ),

              // Release Notes Box
              if (widget.updateInfo.releaseNotes.isNotEmpty) ...[
                const SizedBox(height: 14),
                Container(
                  constraints: const BoxConstraints(maxHeight: 120),
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.surfaceContainerHighest.withAlpha(60),
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(
                      color: theme.colorScheme.outlineVariant.withAlpha(80),
                    ),
                  ),
                  child: SingleChildScrollView(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'പുതിയ മാറ്റങ്ങൾ (What\'s New):',
                          style: TextStyle(
                            fontWeight: FontWeight.bold,
                            fontSize: 12,
                          ),
                        ),
                        const SizedBox(height: 6),
                        Text(
                          widget.updateInfo.releaseNotes,
                          style: TextStyle(
                            fontSize: 12.5,
                            height: 1.35,
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],

              // Error Message
              if (_errorMessage != null) ...[
                const SizedBox(height: 14),
                Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: Colors.red.shade50,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: Colors.red.shade200),
                  ),
                  child: Text(
                    _errorMessage!,
                    style: TextStyle(
                      color: Colors.red.shade900,
                      fontSize: 12,
                      height: 1.3,
                    ),
                  ),
                ),
              ],

              // Download Progress Bar
              if (_isDownloading) ...[
                const SizedBox(height: 18),
                ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: LinearProgressIndicator(
                    value: _progress > 0 ? _progress / 100 : null,
                    minHeight: 8,
                    backgroundColor: theme.colorScheme.surfaceContainerHighest,
                    valueColor: const AlwaysStoppedAnimation<Color>(Color(0xFF2563EB)),
                  ),
                ),
                const SizedBox(height: 6),
                Align(
                  alignment: Alignment.centerRight,
                  child: Text(
                    '$_progress%',
                    style: const TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.bold,
                      color: Color(0xFF2563EB),
                    ),
                  ),
                ),
              ],

              const SizedBox(height: 22),

              // Action Buttons
              Wrap(
                alignment: WrapAlignment.end,
                crossAxisAlignment: WrapCrossAlignment.center,
                spacing: 8,
                runSpacing: 8,
                children: [
                  // Fallback browser download if error happens OR available as alternative
                  if (_errorMessage != null || !_isDownloading) ...[
                    OutlinedButton.icon(
                      onPressed: _downloadViaBrowser,
                      icon: const Icon(Icons.open_in_browser_rounded, size: 16),
                      label: const Text('ബ്രൗസർ വഴി (Browser)'),
                      style: OutlinedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 14, vertical: 11),
                      ),
                    ),
                  ],

                  // Dismiss button if not mandatory and not currently downloading
                  if (!isMandatory && !_isDownloading) ...[
                    TextButton(
                      onPressed: () => Navigator.pop(context),
                      child: const Text('പിന്നീട് (Later)'),
                    ),
                  ],

                  // Primary Update / Retry Button
                  FilledButton.icon(
                    onPressed: _isDownloading ? null : _startUpdate,
                    style: FilledButton.styleFrom(
                      backgroundColor: const Color(0xFF2563EB),
                      padding: const EdgeInsets.symmetric(
                          horizontal: 18, vertical: 12),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(10),
                      ),
                    ),
                    icon: _isDownloading
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: Colors.white,
                            ),
                          )
                        : Icon(
                            _errorMessage != null
                                ? Icons.refresh_rounded
                                : Icons.download_rounded,
                            size: 18,
                          ),
                    label: Text(
                      _errorMessage != null
                          ? 'വീണ്ടും ശ്രമിക്കുക (Retry)'
                          : (_isDownloading
                              ? 'ഡൗൺലോഡ് ചെയ്യുന്നു...'
                              : 'ഉടൻ അപ്ഡേറ്റ് ചെയ്യുക (Update Now)'),
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
