import 'dart:io';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'app_update_service.dart';

class AppUpdateManagementView extends StatefulWidget {
  const AppUpdateManagementView({super.key});

  @override
  State<AppUpdateManagementView> createState() =>
      _AppUpdateManagementViewState();
}

class _AppUpdateManagementViewState extends State<AppUpdateManagementView> {
  final _versionController = TextEditingController();
  final _buildNumberController = TextEditingController();
  final _apkUrlController = TextEditingController();
  final _releaseNotesController = TextEditingController();
  bool _isMandatory = true;

  bool _loading = false;
  String _currentInstalledVersion = 'Loading...';
  int _currentInstalledBuild = 0;

  @override
  void initState() {
    super.initState();
    _applyLocalDefaults();
    _loadCurrentAppInfo();
    _fetchFirestoreConfig();
  }

  @override
  void dispose() {
    _versionController.dispose();
    _buildNumberController.dispose();
    _apkUrlController.dispose();
    _releaseNotesController.dispose();
    super.dispose();
  }

  void _applyLocalDefaults() {
    _versionController.text = '1.0.10';
    _buildNumberController.text = '10';
    _apkUrlController.text =
        'https://github.com/infotekfix-del/tekfix_pos/releases/download/v1.0.10/app-release.apk';
    _releaseNotesController.text =
        '• Offline-First Purchase Bill Persistence: Guarantees local database write and stock sync before Cloud Firestore sync\n• Draft Resume Loop Fix: Auto-clears and deletes draft state on save or discard with manual reset button\n• Interactive Dashboard: Tap "Unpaid Bills" or other KPI cards to instantly filter bills table\n• Interactive & Responsive Bills Table: Tapping anywhere on bill rows opens details, with responsive card list on mobile\n• Complete Windows Package (.zip) with all plugin DLLs included';
    _isMandatory = true;
  }

  Future<void> _loadCurrentAppInfo() async {
    try {
      final info = await PackageInfo.fromPlatform();
      setState(() {
        _currentInstalledVersion = info.version;
        _currentInstalledBuild = int.tryParse(info.buildNumber) ?? 1;
      });
    } catch (e) {
      debugPrint('Failed to load package info: $e');
    }
  }

  Future<void> _fetchFirestoreConfig({bool showNoticeOnFailure = false}) async {
    setState(() => _loading = true);
    try {
      // 1. Ensure Firebase Auth session is active before querying protected config
      if (FirebaseAuth.instance.currentUser == null) {
        try {
          await FirebaseAuth.instance
              .authStateChanges()
              .firstWhere((u) => u != null)
              .timeout(const Duration(seconds: 4));
        } catch (_) {
          debugPrint('AppUpdateManagementView: Firebase Auth session wait timeout.');
        }
      }

      final doc = await FirebaseFirestore.instance
          .collection('app_config')
          .doc('version')
          .get();

      if (doc.exists && doc.data() != null) {
        final data = doc.data()!;
        _versionController.text = (data['latest_version'] ?? '1.0.10').toString();
        _buildNumberController.text =
            (data['latest_build_number'] ?? '10').toString();
        _apkUrlController.text = (data['apk_url'] != null && data['apk_url'].toString().isNotEmpty)
            ? data['apk_url'].toString()
            : 'https://github.com/infotekfix-del/tekfix_pos/releases/download/v1.0.10/app-release.apk';
        _releaseNotesController.text = (data['release_notes'] ?? '').toString();
        _isMandatory = data['is_mandatory'] ?? true;
      } else {
        _applyLocalDefaults();
      }
    } catch (e) {
      debugPrint('AppUpdateManagementView: Error loading config from Firestore: $e');
      _applyLocalDefaults();
      if (showNoticeOnFailure && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: const Row(
              children: [
                Icon(Icons.info_outline, color: Colors.amberAccent, size: 20),
                SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'ഓഫ്ലൈൻ ഡിഫോൾട്ട് വിവരങ്ങൾ ലോഡ് ചെയ്തു (Loaded offline release defaults).',
                    style: TextStyle(fontSize: 12),
                  ),
                ),
              ],
            ),
            backgroundColor: const Color(0xFF1E293B),
            action: SnackBarAction(
              label: 'വീണ്ടും ശ്രമിക്കുക (Retry)',
              textColor: Colors.amberAccent,
              onPressed: () => _fetchFirestoreConfig(showNoticeOnFailure: true),
            ),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _publishUpdate() async {
    final version = _versionController.text.trim();
    final buildStr = _buildNumberController.text.trim();
    final apkUrl = _apkUrlController.text.trim();
    final notes = _releaseNotesController.text.trim();

    if (version.isEmpty || buildStr.isEmpty || apkUrl.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('ദയവായി Version, Build Number, APK URL എന്നിവ നൽകുക.'),
          backgroundColor: Colors.orange,
        ),
      );
      return;
    }

    final buildNum = int.tryParse(buildStr) ?? 1;

    setState(() => _loading = true);
    try {
      await AppUpdateService.instance.publishUpdateConfig(
        latestVersion: version,
        latestBuildNumber: buildNum,
        apkUrl: apkUrl,
        windowsUrl:
            'https://github.com/infotekfix-del/tekfix_pos/releases/tag/v$version',
        releaseNotes: notes,
        isMandatory: _isMandatory,
      );

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Row(
            children: [
              const Icon(Icons.check_circle_rounded, color: Colors.greenAccent),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  'പുതിയ പതിപ്പ് v$version ($buildNum) വിജയകരമായി പബ്ലിഷ് ചെയ്തു!\n(Published successfully to Firestore)',
                ),
              ),
            ],
          ),
          backgroundColor: const Color(0xFF1E293B),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('പബ്ലിഷ് ചെയ്യാൻ സാധിച്ചില്ല: $e'),
          backgroundColor: Colors.red,
        ),
      );
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _previewDialog() {
    final version = _versionController.text.trim();
    final buildStr = _buildNumberController.text.trim();
    final apkUrl = _apkUrlController.text.trim();
    final notes = _releaseNotesController.text.trim();

    final info = AppUpdateInfo(
      latestVersion: version.isNotEmpty ? version : '1.0.1',
      latestBuildNumber: int.tryParse(buildStr) ?? 2,
      apkUrl: apkUrl.isNotEmpty ? apkUrl : 'https://example.com/app-release.apk',
      releaseNotes: notes,
      isMandatory: _isMandatory,
    );

    showDialog(
      context: context,
      barrierDismissible: true,
      builder: (ctx) => AppUpdateDialog(
        updateInfo: info,
        currentVersion: '$_currentInstalledVersion+$_currentInstalledBuild',
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    return Scaffold(
      appBar: AppBar(
        title: const Text('ആപ്പ് അപ്ഡേറ്റ് മാനേജ്‌മെന്റ് (App Updates)'),
        actions: [
          IconButton(
            tooltip: 'റീഫ്രഷ് (Refresh)',
            icon: const Icon(Icons.refresh_rounded),
            onPressed: _loading ? null : _fetchFirestoreConfig,
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : SingleChildScrollView(
              padding: const EdgeInsets.all(20),
              child: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 820),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      // Active App Info Banner
                      Container(
                        padding: const EdgeInsets.all(18),
                        decoration: BoxDecoration(
                          gradient: const LinearGradient(
                            colors: [Color(0xFF1E3A8A), Color(0xFF2563EB)],
                            begin: Alignment.topLeft,
                            end: Alignment.bottomRight,
                          ),
                          borderRadius: BorderRadius.circular(16),
                          boxShadow: [
                            BoxShadow(
                              color: const Color(0xFF2563EB).withAlpha(50),
                              blurRadius: 16,
                              offset: const Offset(0, 4),
                            )
                          ],
                        ),
                        child: Row(
                          children: [
                            Container(
                              padding: const EdgeInsets.all(12),
                              decoration: BoxDecoration(
                                color: Colors.white.withAlpha(40),
                                shape: BoxShape.circle,
                              ),
                              child: const Icon(
                                Icons.rocket_launch_rounded,
                                color: Colors.white,
                                size: 30,
                              ),
                            ),
                            const SizedBox(width: 16),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  const Text(
                                    'In-App Auto-Update System',
                                    style: TextStyle(
                                      color: Colors.white,
                                      fontWeight: FontWeight.bold,
                                      fontSize: 17,
                                    ),
                                  ),
                                  const SizedBox(height: 4),
                                  Text(
                                    'Currently Running: v$_currentInstalledVersion (Build $_currentInstalledBuild) on ${kIsWeb ? 'Web' : Platform.operatingSystem.toUpperCase()}',
                                    style: const TextStyle(
                                      color: Colors.white70,
                                      fontSize: 13,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            OutlinedButton.icon(
                              style: OutlinedButton.styleFrom(
                                foregroundColor: Colors.white,
                                side: const BorderSide(color: Colors.white70),
                              ),
                              onPressed: () => AppUpdateService.instance
                                  .checkForUpdate(context,
                                      autoShowDialog: true,
                                      showToastIfLatest: true),
                              icon: const Icon(Icons.sync_rounded, size: 16),
                              label: const Text('Check Now'),
                            ),
                          ],
                        ),
                      ),

                      const SizedBox(height: 24),

                      // Firestore Release Publishing Card
                      Container(
                        padding: const EdgeInsets.all(22),
                        decoration: BoxDecoration(
                          color: theme.colorScheme.surface,
                          borderRadius: BorderRadius.circular(16),
                          border: Border.all(
                            color: theme.colorScheme.outlineVariant.withAlpha(80),
                          ),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Row(
                              children: [
                                Icon(
                                  Icons.cloud_upload_rounded,
                                  color: Color(0xFF2563EB),
                                ),
                                SizedBox(width: 10),
                                Text(
                                  'പുതിയ പതിപ്പ് പബ്ലിഷ് ചെയ്യുക (Publish New Release)',
                                  style: TextStyle(
                                    fontSize: 16,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 8),
                            Text(
                              'ഇവിടെ നൽകുന്ന വിവരങ്ങൾ Firebase Firestore-ൽ (app_config/version) സേവ് ചെയ്യപ്പെടുകയും, സ്റ്റാഫ് ആപ്പ് തുറക്കുമ്പോൾ പുതിയ പതിപ്പ് സ്വയം ഡൗൺലോഡ് ചെയ്ത് ഇൻസ്റ്റാൾ ചെയ്യുകയും ചെയ്യും.',
                              style: TextStyle(
                                fontSize: 13,
                                color: theme.colorScheme.onSurfaceVariant,
                                height: 1.4,
                              ),
                            ),
                            const SizedBox(height: 20),

                            Row(
                              children: [
                                Expanded(
                                  flex: 3,
                                  child: TextField(
                                    controller: _versionController,
                                    decoration: const InputDecoration(
                                      labelText: 'Latest Version (ഉദാ: 1.0.1)',
                                      prefixIcon: Icon(Icons.tag_rounded),
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 16),
                                Expanded(
                                  flex: 2,
                                  child: TextField(
                                    controller: _buildNumberController,
                                    keyboardType: TextInputType.number,
                                    decoration: const InputDecoration(
                                      labelText: 'Build Number (ഉദാ: 2)',
                                      prefixIcon: Icon(Icons.numbers_rounded),
                                    ),
                                  ),
                                ),
                              ],
                            ),

                            const SizedBox(height: 16),

                            TextField(
                              controller: _apkUrlController,
                              decoration: const InputDecoration(
                                labelText: 'APK Direct Download URL',
                                hintText:
                                    'https://.../app-release.apk (Firebase Storage / GitHub / Hosting)',
                                prefixIcon: Icon(Icons.link_rounded),
                              ),
                            ),

                            const SizedBox(height: 16),

                            TextField(
                              controller: _releaseNotesController,
                              maxLines: 4,
                              decoration: const InputDecoration(
                                labelText:
                                    'Release Notes / What\'s New (മാറ്റങ്ങൾ)',
                                hintText:
                                    '• പുതിയ ഫീച്ചറുകൾ\n• ബഗ് പരിഹാരങ്ങൾ\n• പെർഫോമൻസ് മാറ്റങ്ങൾ',
                                alignLabelWithHint: true,
                              ),
                            ),

                            const SizedBox(height: 16),

                            // Mandatory switch
                            Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 14, vertical: 8),
                              decoration: BoxDecoration(
                                color: isDark
                                    ? Colors.black26
                                    : const Color(0xFFF1F5F9),
                                borderRadius: BorderRadius.circular(10),
                              ),
                              child: Row(
                                children: [
                                  const Icon(Icons.security_update_warning_rounded,
                                      color: Colors.orange),
                                  const SizedBox(width: 12),
                                  const Expanded(
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Text(
                                          'നിർബന്ധിത അപ്ഡേറ്റ് (Mandatory Update)',
                                          style: TextStyle(
                                            fontWeight: FontWeight.bold,
                                            fontSize: 14,
                                          ),
                                        ),
                                        Text(
                                          'അപ്ഡേറ്റ് ചെയ്യാതെ സ്റ്റാഫിന് ആപ്പ് ഉപയോഗിക്കാൻ കഴിയില്ല.',
                                          style: TextStyle(fontSize: 12),
                                        ),
                                      ],
                                    ),
                                  ),
                                  Switch(
                                    value: _isMandatory,
                                    onChanged: (v) =>
                                        setState(() => _isMandatory = v),
                                  ),
                                ],
                              ),
                            ),

                            const SizedBox(height: 24),

                            // Action buttons
                            Row(
                              mainAxisAlignment: MainAxisAlignment.end,
                              children: [
                                OutlinedButton.icon(
                                  onPressed: _previewDialog,
                                  icon: const Icon(Icons.visibility_rounded,
                                      size: 18),
                                  label: const Text('ഡയലോഗ് പ്രിവ്യൂ (Preview)'),
                                ),
                                const SizedBox(width: 12),
                                FilledButton.icon(
                                  style: FilledButton.styleFrom(
                                    backgroundColor: const Color(0xFF2563EB),
                                    padding: const EdgeInsets.symmetric(
                                        horizontal: 24, vertical: 14),
                                    shape: RoundedRectangleBorder(
                                      borderRadius: BorderRadius.circular(10),
                                    ),
                                  ),
                                  onPressed: _loading ? null : _publishUpdate,
                                  icon: const Icon(Icons.publish_rounded,
                                      size: 18),
                                  label: const Text(
                                    'പബ്ലിഷ് ചെയ്യുക (Publish to Firestore)',
                                    style:
                                        TextStyle(fontWeight: FontWeight.bold),
                                  ),
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),

                      const SizedBox(height: 24),

                      // Hosting & Setup Guide Card
                      Container(
                        padding: const EdgeInsets.all(20),
                        decoration: BoxDecoration(
                          color: theme.colorScheme.surface,
                          borderRadius: BorderRadius.circular(16),
                          border: Border.all(
                            color: theme.colorScheme.outlineVariant.withAlpha(80),
                          ),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Row(
                              children: [
                                Icon(Icons.info_outline_rounded,
                                    color: Colors.teal),
                                SizedBox(width: 8),
                                Text(
                                  'എങ്ങനെ APK ഹോസ്റ്റ് ചെയ്യാം? (How to Host APK & Deploy)',
                                  style: TextStyle(
                                    fontSize: 15,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 12),
                            _guideStep(
                              '1',
                              'പുതിയ APK ബിൽഡ് ചെയ്യുക:',
                              '`flutter build apk --release` റൺ ചെയ്യുക. ഔട്ട്പുട്ട് ഫയൽ `build/app/outputs/flutter-apk/app-release.apk` എന്നതിൽ ലഭിക്കും.',
                            ),
                            const SizedBox(height: 10),
                            _guideStep(
                              '2',
                              'APK അപ്‌ലോഡ് ചെയ്യുക:',
                              'ഏതെങ്കിലും വിശ്വസനീയമായ ക്ലൗഡ് സ്റ്റോറേജിൽ APK അപ്‌ലോഡ് ചെയ്ത് Direct Download Link എടുക്കുക:\n• **GitHub Releases** (Free & Reliable: Repo-ൽ Release ഉണ്ടാക്കി APK ഡ്രോപ്പ് ചെയ്യുക)\n• **Firebase Storage** (Firebase Console -> Storage-ൽ ഫയൽ ഇട്ട് Public Download URL എടുക്കുക)\n• **Google Drive / Own Hosting Server**.',
                            ),
                            const SizedBox(height: 10),
                            _guideStep(
                              '3',
                              'Firestore-ൽ റിലീസ് പബ്ലിഷ് ചെയ്യുക:',
                              'മുകളിലുള്ള ഫോമിൽ പുതിയ പതിപ്പ് നമ്പർ (e.g. 1.0.1, Build 2) ഒപ്പം APK ലിങ്കും നൽകി "Publish to Firestore" ക്ലിക്ക് ചെയ്യുക. എല്ലാ സ്റ്റാഫ് ഫോണുകളിലും അടുത്ത തവണ ആപ്പ് തുറക്കുമ്പോൾ ഈ അപ്ഡേറ്റ് ഡയലോഗ് സ്വയം കാണിക്കുകയും, ഒരു ക്ലിക്കിൽ ഡൗൺലോഡ് ചെയ്ത് ഇൻസ്റ്റാൾ ചെയ്യുകയും ചെയ്യും!',
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
    );
  }

  Widget _guideStep(String num, String title, String body) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: 24,
          height: 24,
          decoration: const BoxDecoration(
            color: Color(0xFF2563EB),
            shape: BoxShape.circle,
          ),
          alignment: Alignment.center,
          child: Text(
            num,
            style: const TextStyle(
              color: Colors.white,
              fontWeight: FontWeight.bold,
              fontSize: 12,
            ),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: const TextStyle(fontWeight: FontWeight.bold)),
              const SizedBox(height: 2),
              Text(
                body,
                style: const TextStyle(fontSize: 12.5, height: 1.35),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
