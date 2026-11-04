import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'windows_update_models.dart';
import 'windows_update_service.dart';
import 'windows_update_dialog.dart';
import 'app_update_service.dart';

/// Comprehensive Update Management View for TekFix ERP.
/// Supports Windows In-App Auto Update (GitHub Releases) and Android APK publishing (Firestore).
class AppUpdateManagementView extends StatefulWidget {
  const AppUpdateManagementView({super.key});

  @override
  State<AppUpdateManagementView> createState() =>
      _AppUpdateManagementViewState();
}

class _AppUpdateManagementViewState extends State<AppUpdateManagementView>
    with SingleTickerProviderStateMixin {
  final WindowsUpdateService _winService = WindowsUpdateService.instance;
  late TabController _tabController;

  // GitHub Config Form Controllers
  final _ownerController = TextEditingController();
  final _repoController = TextEditingController();

  // Firestore Android Release Controllers
  final _versionController = TextEditingController();
  final _buildNumberController = TextEditingController();
  final _apkUrlController = TextEditingController();
  final _releaseNotesController = TextEditingController();
  bool _isMandatory = true;
  bool _firestoreLoading = false;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
    _winService.addListener(_onServiceUpdate);

    // Initial values
    _ownerController.text = _winService.settings.githubOwner;
    _repoController.text = _winService.settings.githubRepo;

    // Load info
    _winService.initialize();
    _applyLocalDefaults();
    _fetchFirestoreConfig();
  }

  @override
  void dispose() {
    _winService.removeListener(_onServiceUpdate);
    _tabController.dispose();
    _ownerController.dispose();
    _repoController.dispose();
    _versionController.dispose();
    _buildNumberController.dispose();
    _apkUrlController.dispose();
    _releaseNotesController.dispose();
    super.dispose();
  }

  void _onServiceUpdate() {
    if (mounted) setState(() {});
  }

  void _applyLocalDefaults() {
    _versionController.text = '1.0.14';
    _buildNumberController.text = '14';
    _apkUrlController.text =
        'https://github.com/infotekfix-del/tekfix_pos/releases/download/v1.0.14/app-release.apk';
    _releaseNotesController.text =
        '• Windows In-App Auto-Update with GitHub Releases\n• Owner Salary & Excess Drawings Tracking\n• Daily Shop Rent Management\n• Realtime POS Ledger & 10 PM EOD Closing';
    _isMandatory = true;
  }

  Future<void> _fetchFirestoreConfig() async {
    setState(() => _firestoreLoading = true);
    try {
      if (FirebaseAuth.instance.currentUser == null) {
        try {
          await FirebaseAuth.instance
              .authStateChanges()
              .firstWhere((u) => u != null)
              .timeout(const Duration(seconds: 3));
        } catch (_) {}
      }

      final doc = await FirebaseFirestore.instance
          .collection('app_config')
          .doc('version')
          .get()
          .timeout(const Duration(seconds: 4));

      if (doc.exists && doc.data() != null) {
        final data = doc.data()!;
        _versionController.text = (data['latest_version'] ?? '1.0.13').toString();
        _buildNumberController.text =
            (data['latest_build_number'] ?? '13').toString();
        _apkUrlController.text = (data['apk_url'] ?? '').toString();
        _releaseNotesController.text = (data['release_notes'] ?? '').toString();
        _isMandatory = data['is_mandatory'] ?? true;
      }
    } catch (e) {
      debugPrint('AppUpdateManagementView: Firestore fetch error: $e');
    } finally {
      if (mounted) setState(() => _firestoreLoading = false);
    }
  }

  Future<void> _publishFirestoreUpdate() async {
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
    setState(() => _firestoreLoading = true);

    try {
      await AppUpdateService.instance.publishUpdateConfig(
        latestVersion: version,
        latestBuildNumber: buildNum,
        apkUrl: apkUrl,
        windowsUrl:
            'https://github.com/${_winService.settings.githubOwner}/${_winService.settings.githubRepo}/releases/tag/v$version',
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
      if (mounted) setState(() => _firestoreLoading = false);
    }
  }

  Future<void> _saveGithubRepoSettings() async {
    final owner = _ownerController.text.trim();
    final repo = _repoController.text.trim();
    if (owner.isEmpty || repo.isEmpty) return;

    await _winService.saveSettings(
      _winService.settings.copyWith(
        githubOwner: owner,
        githubRepo: repo,
      ),
    );

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('GitHub repository settings saved successfully.'),
          backgroundColor: Color(0xFF10B981),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    return Scaffold(
      backgroundColor: isDark ? const Color(0xFF0F172A) : const Color(0xFFF8FAFC),
      appBar: AppBar(
        title: const Text('ആപ്പ് അപ്ഡേറ്റ് മാനേജ്‌മെന്റ് (App Updates & Releases)'),
        backgroundColor: isDark ? const Color(0xFF1E293B) : Colors.white,
        elevation: 0,
        bottom: TabBar(
          controller: _tabController,
          indicatorColor: const Color(0xFF3B82F6),
          labelColor: const Color(0xFF3B82F6),
          unselectedLabelColor: isDark ? Colors.white60 : Colors.black54,
          tabs: const [
            Tab(
              icon: Icon(Icons.desktop_windows_rounded),
              text: 'Windows Desktop Auto-Update',
            ),
            Tab(
              icon: Icon(Icons.cloud_upload_rounded),
              text: 'Android / Cloud Releases',
            ),
          ],
        ),
      ),
      body: TabBarView(
        controller: _tabController,
        children: [
          _buildWindowsUpdateTab(theme, isDark),
          _buildAndroidFirestoreTab(theme, isDark),
        ],
      ),
    );
  }

  /// Main Windows Desktop Auto-Update Management Tab.
  Widget _buildWindowsUpdateTab(ThemeData theme, bool isDark) {
    final status = _winService.status;
    final release = _winService.latestRelease;
    final lastChecked = _winService.settings.lastCheckedAt;
    final lastCheckedStr = lastChecked != null
        ? DateFormat('dd MMM yyyy, hh:mm a').format(lastChecked)
        : 'Never';

    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 900),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // 1. Version & Status Header Card
              Container(
                padding: const EdgeInsets.all(22),
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
                      padding: const EdgeInsets.all(14),
                      decoration: BoxDecoration(
                        color: Colors.white.withAlpha(35),
                        shape: BoxShape.circle,
                      ),
                      child: const Icon(
                        Icons.system_update_rounded,
                        color: Colors.white,
                        size: 34,
                      ),
                    ),
                    const SizedBox(width: 20),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text(
                            'TekFix ERP Windows In-App Updater',
                            style: TextStyle(
                              color: Colors.white,
                              fontWeight: FontWeight.bold,
                              fontSize: 18,
                            ),
                          ),
                          const SizedBox(height: 6),
                          Row(
                            children: [
                              Text(
                                'Current Version: v${_winService.currentVersion}',
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontWeight: FontWeight.w600,
                                  fontSize: 13.5,
                                ),
                              ),
                              const SizedBox(width: 12),
                              Container(
                                width: 4,
                                height: 4,
                                decoration: const BoxDecoration(
                                  color: Colors.white70,
                                  shape: BoxShape.circle,
                                ),
                              ),
                              const SizedBox(width: 12),
                              Text(
                                'Latest: ${release != null ? release.tagName : 'v${_winService.currentVersion}'}',
                                style: const TextStyle(
                                  color: Colors.white70,
                                  fontSize: 13,
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 6),
                          Text(
                            'Last Checked: $lastCheckedStr',
                            style: const TextStyle(
                              color: Colors.white60,
                              fontSize: 12,
                            ),
                          ),
                        ],
                      ),
                    ),
                    _buildStatusBadge(status),
                  ],
                ),
              ),

              const SizedBox(height: 20),

              // 2. Main Action Buttons Row
              Card(
                color: isDark ? const Color(0xFF1E293B) : Colors.white,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14),
                  side: BorderSide(
                    color: isDark ? const Color(0xFF334155) : const Color(0xFFE2E8F0),
                  ),
                ),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
                  child: Row(
                    children: [
                      // Check for updates button
                      FilledButton.icon(
                        style: FilledButton.styleFrom(
                          backgroundColor: const Color(0xFF3B82F6),
                          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(10),
                          ),
                        ),
                        onPressed: _winService.isChecking
                            ? null
                            : () async {
                                final res = await _winService.checkForUpdates(isManual: true);
                                if (!mounted) return;
                                if (_winService.errorMessage != null) {
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    SnackBar(
                                      content: Row(
                                        children: [
                                          const Icon(Icons.error_outline_rounded,
                                              color: Colors.amberAccent),
                                          const SizedBox(width: 10),
                                          Expanded(
                                            child: Text(
                                              'അപ്ഡേറ്റ് പരിശോധന പരാജയപ്പെട്ടു: ${_winService.errorMessage}',
                                              style: const TextStyle(fontWeight: FontWeight.w600),
                                            ),
                                          ),
                                        ],
                                      ),
                                      backgroundColor: const Color(0xFF991B1B),
                                      behavior: SnackBarBehavior.floating,
                                      duration: const Duration(seconds: 5),
                                    ),
                                  );
                                } else if (res != null && _winService.isUpdateAvailable) {
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    SnackBar(
                                      content: Row(
                                        children: [
                                          const Icon(Icons.system_update_rounded,
                                              color: Colors.greenAccent),
                                          const SizedBox(width: 10),
                                          Expanded(
                                            child: Text(
                                              'പുതിയ പതിപ്പ് (${res.tagName}) ലഭ്യമാണ്! (Update Available)',
                                              style: const TextStyle(fontWeight: FontWeight.w600),
                                            ),
                                          ),
                                        ],
                                      ),
                                      backgroundColor: const Color(0xFF1E293B),
                                      behavior: SnackBarBehavior.floating,
                                    ),
                                  );
                                } else {
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    SnackBar(
                                      content: const Row(
                                        children: [
                                          Icon(Icons.check_circle_rounded,
                                              color: Colors.greenAccent),
                                          SizedBox(width: 10),
                                          Expanded(
                                            child: Text(
                                              'നിങ്ങൾ ഉപയോഗിക്കുന്നത് ഏറ്റവും പുതിയ പതിപ്പാണ് (App is up to date).',
                                              style: TextStyle(fontWeight: FontWeight.w600),
                                            ),
                                          ),
                                        ],
                                      ),
                                      backgroundColor: const Color(0xFF1E293B),
                                      behavior: SnackBarBehavior.floating,
                                    ),
                                  );
                                }
                              },
                        icon: _winService.isChecking
                            ? const SizedBox(
                                width: 16,
                                height: 16,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  color: Colors.white,
                                ),
                              )
                            : const Icon(Icons.sync_rounded, size: 18),
                        label: Text(
                          _winService.isChecking ? 'Checking...' : 'Check for Updates',
                          style: const TextStyle(fontWeight: FontWeight.bold),
                        ),
                      ),
                      const SizedBox(width: 12),

                      // Download button
                      if (status == WindowsUpdateStatus.updateAvailable ||
                          status == WindowsUpdateStatus.downloading)
                        FilledButton.icon(
                          style: FilledButton.styleFrom(
                            backgroundColor: const Color(0xFF6366F1),
                            padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(10),
                            ),
                          ),
                          onPressed: _winService.isDownloading
                              ? null
                              : () => _winService.downloadUpdate(),
                          icon: _winService.isDownloading
                              ? const SizedBox(
                                  width: 16,
                                  height: 16,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                    color: Colors.white,
                                  ),
                                )
                              : const Icon(Icons.download_rounded, size: 18),
                          label: Text(
                            _winService.isDownloading
                                ? 'Downloading...'
                                : 'Download Update',
                            style: const TextStyle(fontWeight: FontWeight.bold),
                          ),
                        ),

                      // Restart & Install button
                      if (status == WindowsUpdateStatus.downloadComplete)
                        FilledButton.icon(
                          style: FilledButton.styleFrom(
                            backgroundColor: const Color(0xFF10B981),
                            padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(10),
                            ),
                          ),
                          onPressed: () => _winService.restartAndInstall(),
                          icon: const Icon(Icons.restart_alt_rounded, size: 18),
                          label: const Text(
                            'Restart & Install',
                            style: TextStyle(fontWeight: FontWeight.bold),
                          ),
                        ),

                      const Spacer(),

                      // Quick Dialog button
                      if (release != null && _winService.isUpdateAvailable)
                        OutlinedButton.icon(
                          onPressed: () {
                            WindowsUpdateDialog.show(
                              context,
                              release: release,
                              currentVersion: _winService.currentVersion,
                            );
                          },
                          icon: const Icon(Icons.open_in_new_rounded, size: 16),
                          label: const Text('Open Update Dialog'),
                        ),
                    ],
                  ),
                ),
              ),

              // Downloading progress indicator
              if (status == WindowsUpdateStatus.downloading) ...[
                const SizedBox(height: 16),
                _buildDownloadProgressCard(isDark),
              ],

              // Error banner if any
              if (_winService.errorMessage != null) ...[
                const SizedBox(height: 16),
                Container(
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: const Color(0xFFEF4444).withAlpha(20),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: const Color(0xFFEF4444).withAlpha(80)),
                  ),
                  child: Row(
                    children: [
                      const Icon(Icons.error_outline_rounded,
                          color: Color(0xFFEF4444), size: 24),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text(
                          _winService.errorMessage!,
                          style: const TextStyle(
                            color: Color(0xFFEF4444),
                            fontSize: 13,
                          ),
                        ),
                      ),
                      IconButton(
                        icon: const Icon(Icons.close_rounded,
                            size: 18, color: Color(0xFFEF4444)),
                        onPressed: () => _winService.resetStatus(),
                      ),
                    ],
                  ),
                ),
              ],

              const SizedBox(height: 20),

              // Real-Time Update Diagnostics & Live Logs
              _buildDiagnosticsAndLogsCard(isDark),

              const SizedBox(height: 20),

              // 3. Release Notes Card
              if (release != null && release.body.isNotEmpty) ...[
                Card(
                  color: isDark ? const Color(0xFF1E293B) : Colors.white,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14),
                    side: BorderSide(
                      color: isDark ? const Color(0xFF334155) : const Color(0xFFE2E8F0),
                    ),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.all(20),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            const Icon(Icons.newspaper_rounded,
                                color: Color(0xFF3B82F6), size: 20),
                            const SizedBox(width: 10),
                            Text(
                              'Release Notes — ${release.name.isNotEmpty ? release.name : release.tagName}',
                              style: const TextStyle(
                                fontSize: 15,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                            const Spacer(),
                            Text(
                              'Published: ${DateFormat('dd MMM yyyy').format(release.publishedAt)}',
                              style: TextStyle(
                                fontSize: 12,
                                color: isDark ? Colors.white60 : Colors.black54,
                              ),
                            ),
                          ],
                        ),
                        const Divider(height: 24),
                        Text(
                          release.body,
                          style: TextStyle(
                            fontSize: 13.5,
                            height: 1.5,
                            color: isDark ? const Color(0xFFCBD5E1) : const Color(0xFF334155),
                          ),
                        ),
                        if (release.windowsInstallerAsset != null) ...[
                          const SizedBox(height: 14),
                          Container(
                            padding: const EdgeInsets.all(10),
                            decoration: BoxDecoration(
                              color: isDark ? const Color(0xFF0F172A) : const Color(0xFFF1F5F9),
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: Row(
                              children: [
                                const Icon(Icons.attachment_rounded, size: 16),
                                const SizedBox(width: 8),
                                Text(
                                  'Installer: ${release.windowsInstallerAsset!.name} (${(release.windowsInstallerAsset!.sizeBytes / (1024 * 1024)).toStringAsFixed(1)} MB)',
                                  style: const TextStyle(fontSize: 12),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 20),
              ],

              // 4. Automatic Update Check Settings Card
              Card(
                color: isDark ? const Color(0xFF1E293B) : Colors.white,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14),
                  side: BorderSide(
                    color: isDark ? const Color(0xFF334155) : const Color(0xFFE2E8F0),
                  ),
                ),
                child: Padding(
                  padding: const EdgeInsets.all(20),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Row(
                        children: [
                          Icon(Icons.tune_rounded, color: Color(0xFF10B981), size: 20),
                          SizedBox(width: 10),
                          Text(
                            'അപ്ഡേറ്റ് ക്രമീകരണങ്ങൾ (Automatic Update Settings)',
                            style: TextStyle(
                              fontSize: 15,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 16),

                      // Setting 1: Automatically Check for Updates
                      SwitchListTile(
                        contentPadding: EdgeInsets.zero,
                        title: const Text('Automatically Check for Updates'),
                        subtitle: const Text(
                          'പശ്ചാത്തലത്തിൽ പുതിയ പതിപ്പുകൾ പരിശോധിക്കുക (Periodically check GitHub in background)',
                          style: TextStyle(fontSize: 12),
                        ),
                        value: _winService.settings.autoCheckUpdates,
                        onChanged: (val) {
                          _winService.saveSettings(
                            _winService.settings.copyWith(autoCheckUpdates: val),
                          );
                        },
                      ),
                      const Divider(),

                      // Setting 2: Check on Startup
                      SwitchListTile(
                        contentPadding: EdgeInsets.zero,
                        title: const Text('Check on Startup'),
                        subtitle: const Text(
                          'ആപ്പ് തുറക്കുമ്പോൾ പരിശോധിക്കുക (Start non-blocking update check upon launch)',
                          style: TextStyle(fontSize: 12),
                        ),
                        value: _winService.settings.checkOnStartup,
                        onChanged: (val) {
                          _winService.saveSettings(
                            _winService.settings.copyWith(checkOnStartup: val),
                          );
                        },
                      ),
                      const Divider(),

                      // Setting 3: Show Release Notifications
                      SwitchListTile(
                        contentPadding: EdgeInsets.zero,
                        title: const Text('Show Release Notifications'),
                        subtitle: const Text(
                          'ഡാഷ്‌ബോർഡിൽ അപ്ഡേറ്റ് ബാനർ കാണിക്കുക (Display notification banner on Dashboard)',
                          style: TextStyle(fontSize: 12),
                        ),
                        value: _winService.settings.showReleaseNotifications,
                        onChanged: (val) {
                          _winService.saveSettings(
                            _winService.settings.copyWith(showReleaseNotifications: val),
                          );
                        },
                      ),
                      const Divider(),

                      // Setting 4: GitHub Repository Configuration
                      const SizedBox(height: 8),
                      const Text(
                        'GitHub Releases Repository Settings',
                        style: TextStyle(
                          fontWeight: FontWeight.w600,
                          fontSize: 13,
                        ),
                      ),
                      const SizedBox(height: 10),
                      Row(
                        children: [
                          Expanded(
                            child: TextField(
                              controller: _ownerController,
                              decoration: const InputDecoration(
                                labelText: 'GITHUB_OWNER',
                                hintText: 'infotekfix-del',
                                prefixIcon: Icon(Icons.person_rounded),
                              ),
                            ),
                          ),
                          const SizedBox(width: 16),
                          Expanded(
                            child: TextField(
                              controller: _repoController,
                              decoration: const InputDecoration(
                                labelText: 'GITHUB_REPO',
                                hintText: 'tekfix_pos',
                                prefixIcon: Icon(Icons.folder_rounded),
                              ),
                            ),
                          ),
                          const SizedBox(width: 16),
                          FilledButton.icon(
                            style: FilledButton.styleFrom(
                              backgroundColor: const Color(0xFF10B981),
                              padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(10),
                              ),
                            ),
                            onPressed: _saveGithubRepoSettings,
                            icon: const Icon(Icons.save_rounded, size: 18),
                            label: const Text('Save Repo'),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// Download progress card
  Widget _buildDownloadProgressCard(bool isDark) {
    final prog = _winService.downloadProgress;
    return Card(
      color: isDark ? const Color(0xFF1E293B) : Colors.white,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: const BorderSide(color: Color(0xFF3B82F6), width: 1.2),
      ),
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  prog.statusText,
                  style: const TextStyle(
                    fontWeight: FontWeight.w600,
                    color: Color(0xFF3B82F6),
                  ),
                ),
                Text(
                  '${prog.percentage}%',
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                    color: Color(0xFF3B82F6),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            ClipRRect(
              borderRadius: BorderRadius.circular(6),
              child: LinearProgressIndicator(
                value: prog.progress > 0 ? prog.progress : null,
                minHeight: 10,
                backgroundColor: isDark ? const Color(0xFF334155) : const Color(0xFFE2E8F0),
                valueColor: const AlwaysStoppedAnimation<Color>(Color(0xFF3B82F6)),
              ),
            ),
            const SizedBox(height: 10),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  '${prog.downloadedFormatted} / ${prog.totalFormatted}',
                  style: TextStyle(
                    fontSize: 12,
                    color: isDark ? Colors.white60 : Colors.black54,
                  ),
                ),
                Text(
                  prog.speedFormatted,
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w500,
                    color: isDark ? Colors.white60 : Colors.black54,
                  ),
                ),
                TextButton(
                  onPressed: () => _winService.cancelDownload(),
                  child: const Text('Cancel Download', style: TextStyle(color: Colors.red)),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  /// Status badge widget
  Widget _buildStatusBadge(WindowsUpdateStatus status) {
    Color bg;
    Color fg;
    String text;
    IconData icon;

    switch (status) {
      case WindowsUpdateStatus.idle:
      case WindowsUpdateStatus.upToDate:
        bg = const Color(0xFF10B981).withAlpha(40);
        fg = const Color(0xFF10B981);
        text = 'Up to date';
        icon = Icons.check_circle_rounded;
        break;
      case WindowsUpdateStatus.checking:
        bg = Colors.amber.withAlpha(40);
        fg = Colors.amberAccent;
        text = 'Checking...';
        icon = Icons.sync_rounded;
        break;
      case WindowsUpdateStatus.updateAvailable:
        bg = const Color(0xFF3B82F6).withAlpha(40);
        fg = Colors.white;
        text = 'Update Available';
        icon = Icons.new_releases_rounded;
        break;
      case WindowsUpdateStatus.downloading:
        bg = const Color(0xFF8B5CF6).withAlpha(40);
        fg = const Color(0xFFC4B5FD);
        text = 'Downloading';
        icon = Icons.downloading_rounded;
        break;
      case WindowsUpdateStatus.downloadComplete:
        bg = const Color(0xFF10B981).withAlpha(40);
        fg = const Color(0xFF34D399);
        text = 'Download Complete';
        icon = Icons.check_circle_outline_rounded;
        break;
      case WindowsUpdateStatus.installing:
        bg = Colors.orange.withAlpha(40);
        fg = Colors.orangeAccent;
        text = 'Installing...';
        icon = Icons.hourglass_top_rounded;
        break;
      case WindowsUpdateStatus.failed:
        bg = Colors.red.withAlpha(40);
        fg = Colors.redAccent;
        text = 'Update Failed';
        icon = Icons.error_rounded;
        break;
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: fg.withAlpha(120)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, color: fg, size: 16),
          const SizedBox(width: 6),
          Text(
            text,
            style: TextStyle(
              color: fg,
              fontWeight: FontWeight.bold,
              fontSize: 12,
            ),
          ),
        ],
      ),
    );
  }

  /// Secondary Tab for Android & Cloud Releases (preserving existing capability)
  Widget _buildAndroidFirestoreTab(ThemeData theme, bool isDark) {
    return _firestoreLoading
        ? const Center(child: CircularProgressIndicator())
        : SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 850),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Container(
                      padding: const EdgeInsets.all(20),
                      decoration: BoxDecoration(
                        color: isDark ? const Color(0xFF1E293B) : Colors.white,
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(
                          color: isDark ? const Color(0xFF334155) : const Color(0xFFE2E8F0),
                        ),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Row(
                            children: [
                              Icon(Icons.cloud_upload_rounded, color: Color(0xFF2563EB)),
                              SizedBox(width: 10),
                              Text(
                                'Android APK & Firestore Config (Mobile Staff Portal)',
                                style: TextStyle(
                                  fontSize: 16,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 8),
                          Text(
                            'ഇവിടെ നൽകുന്ന വിവരങ്ങൾ Firebase Firestore-ൽ (app_config/version) സേവ് ചെയ്യപ്പെടുകയും, Android ഫോണുകളിൽ സ്റ്റാഫ് ആപ്പ് തുറക്കുമ്പോൾ APK സ്വയം അപ്ഡേറ്റ് ചെയ്യപ്പെടുകയും ചെയ്യും.',
                            style: TextStyle(
                              fontSize: 13,
                              color: isDark ? Colors.white70 : Colors.black87,
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
                                    labelText: 'Version (e.g. 1.0.13)',
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
                                    labelText: 'Build Number (e.g. 13)',
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
                              hintText: 'https://.../app-release.apk',
                              prefixIcon: Icon(Icons.link_rounded),
                            ),
                          ),
                          const SizedBox(height: 16),
                          TextField(
                            controller: _releaseNotesController,
                            maxLines: 4,
                            decoration: const InputDecoration(
                              labelText: 'Release Notes / What\'s New',
                              alignLabelWithHint: true,
                            ),
                          ),
                          const SizedBox(height: 16),
                          SwitchListTile(
                            contentPadding: EdgeInsets.zero,
                            title: const Text('Mandatory Update for Mobile Staff'),
                            subtitle: const Text(
                              'Staff cannot use the app without updating',
                              style: TextStyle(fontSize: 12),
                            ),
                            value: _isMandatory,
                            onChanged: (v) => setState(() => _isMandatory = v),
                          ),
                          const SizedBox(height: 20),
                          Align(
                            alignment: Alignment.centerRight,
                            child: FilledButton.icon(
                              style: FilledButton.styleFrom(
                                backgroundColor: const Color(0xFF2563EB),
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 24, vertical: 14),
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(10),
                                ),
                              ),
                              onPressed: _firestoreLoading ? null : _publishFirestoreUpdate,
                              icon: const Icon(Icons.publish_rounded, size: 18),
                              label: const Text(
                                'Publish to Firestore',
                                style: TextStyle(fontWeight: FontWeight.bold),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          );
  }

  /// Real-time live update diagnostics card with status metrics & console log output.
  Widget _buildDiagnosticsAndLogsCard(bool isDark) {
    final logs = _winService.diagnosticLogs;
    final statusSummary = _winService.checkStatusSummary;
    final isError = statusSummary.toLowerCase().contains('error') ||
        statusSummary.toLowerCase().contains('failed');
    final isAvailable = statusSummary.toLowerCase().contains('available');
    final isUpToDate = statusSummary.toLowerCase().contains('up to date');

    Color badgeColor = const Color(0xFF64748B);
    if (isError) badgeColor = const Color(0xFFEF4444);
    if (isAvailable) badgeColor = const Color(0xFF10B981);
    if (isUpToDate) badgeColor = const Color(0xFF3B82F6);

    return Card(
      color: isDark ? const Color(0xFF1E293B) : Colors.white,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(
          color: isDark ? const Color(0xFF334155) : const Color(0xFFE2E8F0),
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.terminal_rounded, color: Color(0xFF3B82F6), size: 22),
                const SizedBox(width: 10),
                const Text(
                  'Real-Time Update Diagnostics & Live Logs',
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const Spacer(),
                if (logs.isNotEmpty) ...[
                  IconButton(
                    tooltip: 'Copy Logs',
                    icon: const Icon(Icons.copy_rounded, size: 18),
                    onPressed: () {
                      Clipboard.setData(ClipboardData(text: logs.join('\n')));
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(
                          content: Text('Logs copied to clipboard'),
                          behavior: SnackBarBehavior.floating,
                        ),
                      );
                    },
                  ),
                  IconButton(
                    tooltip: 'Clear Logs',
                    icon: const Icon(Icons.clear_all_rounded, size: 18),
                    onPressed: () => _winService.clearLogs(),
                  ),
                ],
              ],
            ),
            const SizedBox(height: 14),

            // Live status metrics chips
            Wrap(
              spacing: 12,
              runSpacing: 8,
              children: [
                _buildDiagnosticPill(
                  label: 'Current App Version',
                  value: 'v${_winService.currentVersion}',
                  icon: Icons.info_outline_rounded,
                  color: const Color(0xFF3B82F6),
                  isDark: isDark,
                ),
                _buildDiagnosticPill(
                  label: 'Fetched Remote Version',
                  value: _winService.lastFetchedRemoteVersion ??
                      (_winService.latestRelease != null
                          ? _winService.latestRelease!.tagName
                          : 'Not fetched'),
                  icon: Icons.cloud_download_outlined,
                  color: const Color(0xFF8B5CF6),
                  isDark: isDark,
                ),
                _buildDiagnosticPill(
                  label: 'Status',
                  value: statusSummary,
                  icon: isError
                      ? Icons.error_outline_rounded
                      : (isAvailable
                          ? Icons.system_update_rounded
                          : Icons.check_circle_outline_rounded),
                  color: badgeColor,
                  isDark: isDark,
                ),
              ],
            ),

            const SizedBox(height: 14),

            // Live console output box
            Container(
              height: 180,
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: const Color(0xFF0B1120),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: const Color(0xFF1E293B)),
              ),
              child: logs.isEmpty
                  ? Center(
                      child: Text(
                        'Click "Check for Updates" to trigger live API check and view connection logs.',
                        style: TextStyle(
                          color: Colors.white.withAlpha(120),
                          fontFamily: 'monospace',
                          fontSize: 12,
                        ),
                        textAlign: TextAlign.center,
                      ),
                    )
                  : Scrollbar(
                      child: ListView.builder(
                        itemCount: logs.length,
                        itemBuilder: (context, index) {
                          final log = logs[index];
                          Color logColor = const Color(0xFFE2E8F0);
                          if (log.contains('Error') || log.contains('failed')) {
                            logColor = const Color(0xFFF87171);
                          } else if (log.contains('Update Available')) {
                            logColor = const Color(0xFF4ADE80);
                          } else if (log.contains('Up to date')) {
                            logColor = const Color(0xFF60A5FA);
                          } else if (log.contains('Current App Version') ||
                              log.contains('Fetched Remote Version')) {
                            logColor = const Color(0xFFFBBF24);
                          }

                          return Padding(
                            padding: const EdgeInsets.symmetric(vertical: 2),
                            child: Text(
                              log,
                              style: TextStyle(
                                fontFamily: 'monospace',
                                fontSize: 11.5,
                                color: logColor,
                                height: 1.3,
                              ),
                            ),
                          );
                        },
                      ),
                    ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildDiagnosticPill({
    required String label,
    required String value,
    required IconData icon,
    required Color color,
    required bool isDark,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: color.withAlpha(isDark ? 25 : 15),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: color.withAlpha(60)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 16, color: color),
          const SizedBox(width: 8),
          Text(
            '$label: ',
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w500,
              color: isDark ? Colors.white70 : Colors.black87,
            ),
          ),
          Text(
            value,
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.bold,
              color: color,
            ),
          ),
        ],
      ),
    );
  }
}
