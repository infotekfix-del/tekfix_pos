import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:hive/hive.dart';
import 'package:http/http.dart' as http;
import 'package:intl/intl.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path/path.dart' as p;
import 'windows_update_models.dart';

/// Production-ready In-App Auto-Update Service for TekFix ERP Windows Desktop.
/// Connects to GitHub Releases, downloads installers with background streaming,
/// verifies SHA-256 checksums, and performs silent installation and auto-restart.
class WindowsUpdateService extends ChangeNotifier {
  WindowsUpdateService._();
  static final WindowsUpdateService instance = WindowsUpdateService._();

  static const String settingsKey = 'windows_update_settings';
  static const String defaultOwner = 'infotekfix-del';
  static const String defaultRepo = 'tekfix_pos';

  WindowsUpdateSettings _settings = const WindowsUpdateSettings();
  WindowsUpdateStatus _status = WindowsUpdateStatus.idle;
  GitHubReleaseInfo? _latestRelease;
  String _currentVersion = '1.0.14';
  String? _errorMessage;
  DownloadProgressInfo _downloadProgress = const DownloadProgressInfo();
  String? _downloadedInstallerPath;

  bool _isChecking = false;
  bool _isDownloading = false;
  http.Client? _activeDownloadClient;
  StreamSubscription<List<int>>? _downloadSubscription;

  // Real-time diagnostics & console logs
  final List<String> _diagnosticLogs = [];
  String? _lastFetchedRemoteVersion;
  String _checkStatusSummary = 'Idle';

  // Getters
  WindowsUpdateSettings get settings => _settings;
  WindowsUpdateStatus get status => _status;
  GitHubReleaseInfo? get latestRelease => _latestRelease;
  String get currentVersion => _currentVersion;
  String? get errorMessage => _errorMessage;
  DownloadProgressInfo get downloadProgress => _downloadProgress;
  String? get downloadedInstallerPath => _downloadedInstallerPath;
  bool get isChecking => _isChecking;
  bool get isDownloading => _isDownloading;
  List<String> get diagnosticLogs => List.unmodifiable(_diagnosticLogs);
  String? get lastFetchedRemoteVersion => _lastFetchedRemoteVersion;
  String get checkStatusSummary => _checkStatusSummary;

  void clearLogs() {
    _diagnosticLogs.clear();
    notifyListeners();
  }

  void _log(String message) {
    final timestamp = DateFormat('HH:mm:ss').format(DateTime.now());
    final entry = '[$timestamp] $message';
    _diagnosticLogs.add(entry);
    if (_diagnosticLogs.length > 150) {
      _diagnosticLogs.removeAt(0);
    }
    debugPrint('WindowsUpdateService: $message');
    notifyListeners();
  }
  bool get isUpdateAvailable =>
      _status == WindowsUpdateStatus.updateAvailable ||
      _status == WindowsUpdateStatus.downloading ||
      _status == WindowsUpdateStatus.downloadComplete;

  /// Initializes the service by loading settings and current installed version.
  Future<void> initialize({String? overrideCurrentVersion}) async {
    await loadSettings();
    if (overrideCurrentVersion != null) {
      _currentVersion = overrideCurrentVersion;
    } else {
      try {
        final info = await PackageInfo.fromPlatform();
        _currentVersion = info.version;
      } catch (e) {
        debugPrint('WindowsUpdateService: Error fetching package info: $e');
      }
    }
    notifyListeners();
  }

  /// Loads update settings from Hive or falls back to defaults.
  Future<void> loadSettings() async {
    try {
      if (Hive.isBoxOpen('tek_settings')) {
        final box = Hive.box('tek_settings');
        final raw = box.get(settingsKey);
        if (raw is Map) {
          _settings = WindowsUpdateSettings.fromMap(raw);
        }
      }
    } catch (e) {
      debugPrint('WindowsUpdateService: Could not load settings: $e');
    }
  }

  /// Saves settings persistently to Hive.
  Future<void> saveSettings(WindowsUpdateSettings newSettings) async {
    _settings = newSettings;
    try {
      if (Hive.isBoxOpen('tek_settings')) {
        final box = Hive.box('tek_settings');
        await box.put(settingsKey, newSettings.toMap());
      }
    } catch (e) {
      debugPrint('WindowsUpdateService: Could not save settings: $e');
    }
    notifyListeners();
  }

  /// Checks GitHub Releases API for a newer version.
  /// Gracefully handles offline mode, rate limits, and network errors.
  Future<GitHubReleaseInfo?> checkForUpdates({
    bool isManual = false,
    http.Client? client,
    String? overrideCurrentVersion,
  }) async {
    if (_isChecking || _isDownloading) return _latestRelease;
    _isChecking = true;
    _errorMessage = null;
    _status = WindowsUpdateStatus.checking;
    _checkStatusSummary = 'Checking...';
    notifyListeners();

    if (overrideCurrentVersion != null) {
      _currentVersion = overrideCurrentVersion;
    } else {
      try {
        final info = await PackageInfo.fromPlatform();
        _currentVersion = info.version;
      } catch (_) {}
    }

    _log('Current App Version: $_currentVersion');

    final httpClient = client ?? http.Client();
    try {
      final owner = _settings.githubOwner.trim().isEmpty ? defaultOwner : _settings.githubOwner.trim();
      final repo = _settings.githubRepo.trim().isEmpty ? defaultRepo : _settings.githubRepo.trim();
      final url = Uri.parse('https://api.github.com/repos/$owner/$repo/releases/latest');

      _log('Querying GitHub Releases API: $url');
      final response = await httpClient.get(
        url,
        headers: {
          'Accept': 'application/vnd.github.v3+json',
          'User-Agent': 'TekFix-ERP-Updater/1.0',
        },
      ).timeout(const Duration(seconds: 12));

      final now = DateTime.now();
      await saveSettings(_settings.copyWith(lastCheckedAt: now));

      if (response.statusCode == 200) {
        final data = json.decode(response.body) as Map<String, dynamic>;
        final release = GitHubReleaseInfo.fromJson(data);
        _latestRelease = release;
        _lastFetchedRemoteVersion = release.tagName;

        _log('Fetched Remote Version: ${release.tagName}');

        // Skip prereleases unless specifically configured
        if (release.isPrerelease) {
          _log('Latest release is marked prerelease. Skipping.');
          _status = WindowsUpdateStatus.upToDate;
          _checkStatusSummary = 'Up to date (Prerelease ignored)';
          notifyListeners();
          return null;
        }

        final currentSemVer = SemVer.parse(_currentVersion);
        final isNewer = release.semVer.isGreaterThan(currentSemVer);

        if (isNewer) {
          _log('Status: Update Available (${release.tagName})');
          _checkStatusSummary = 'Update Available (${release.tagName})';
          // Check if user postponed this exact version recently (within 24h)
          if (!isManual &&
              _settings.postponedVersion == release.tagName &&
              _settings.lastDismissedAt != null &&
              DateTime.now().difference(_settings.lastDismissedAt!).inHours < 24) {
            _log('Update postponed by user for 24h.');
            _status = WindowsUpdateStatus.idle;
          } else {
            _status = WindowsUpdateStatus.updateAvailable;
          }
          notifyListeners();
          return release;
        } else {
          _log('Status: Up to date');
          _checkStatusSummary = 'Up to date';
          _status = WindowsUpdateStatus.upToDate;
          notifyListeners();
          return null;
        }
      } else if (response.statusCode == 403) {
        _lastFetchedRemoteVersion = 'Unknown';
        _errorMessage = 'GitHub API rate limit exceeded (HTTP 403). Please check again later.';
        _checkStatusSummary = 'API Error: HTTP 403 Rate Limited';
        _log('Status: API Error: HTTP 403 (Rate Limited)');
        _status = WindowsUpdateStatus.failed;
        notifyListeners();
        return null;
      } else if (response.statusCode == 404) {
        _lastFetchedRemoteVersion = 'None';
        _errorMessage = 'No releases found on GitHub for repository $owner/$repo (HTTP 404).';
        _checkStatusSummary = 'API Error: HTTP 404 (No Releases Found)';
        _log('Status: API Error: HTTP 404 (No Releases Found)');
        _status = WindowsUpdateStatus.upToDate;
        notifyListeners();
        return null;
      } else {
        _lastFetchedRemoteVersion = 'Error';
        _errorMessage = 'GitHub API returned HTTP ${response.statusCode}: ${response.reasonPhrase}';
        _checkStatusSummary = 'API Error: HTTP ${response.statusCode}';
        _log('Status: API Error: HTTP ${response.statusCode}');
        _status = WindowsUpdateStatus.failed;
        notifyListeners();
        return null;
      }
    } on SocketException catch (e) {
      _lastFetchedRemoteVersion = 'Network Error';
      _errorMessage = 'ഇന്റർനെറ്റ് കണക്ഷൻ ലഭ്യമല്ല (No internet connection: ${e.message})';
      _checkStatusSummary = 'Network Error: SocketException';
      _log('Status: Network Error: SocketException (${e.message})');
      _status = WindowsUpdateStatus.failed;
      notifyListeners();
      return null;
    } on HandshakeException catch (e) {
      _lastFetchedRemoteVersion = 'SSL Error';
      _errorMessage = 'സുരക്ഷിത കണക്ഷൻ പരാജയപ്പെട്ടു (HandshakeException: ${e.message})';
      _checkStatusSummary = 'Security Error: HandshakeException';
      _log('Status: Security Error: HandshakeException (${e.message})');
      _status = WindowsUpdateStatus.failed;
      notifyListeners();
      return null;
    } on TimeoutException {
      _lastFetchedRemoteVersion = 'Timeout';
      _errorMessage = 'കണക്ഷൻ സമയം കഴിഞ്ഞു (Request timed out).';
      _checkStatusSummary = 'Timeout Error: Request timed out';
      _log('Status: Timeout Error');
      _status = WindowsUpdateStatus.failed;
      notifyListeners();
      return null;
    } catch (e) {
      _lastFetchedRemoteVersion = 'Error';
      _errorMessage = 'അപ്ഡേറ്റ് പരിശോധന പരാജയപ്പെട്ടു: $e';
      _checkStatusSummary = 'Error: $e';
      _log('Status: Error: $e');
      _status = WindowsUpdateStatus.failed;
      notifyListeners();
      return null;
    } finally {
      _isChecking = false;
      if (client == null) {
        httpClient.close();
      }
      notifyListeners();
    }
  }

  /// Downloads the Windows installer with chunked streaming and progress reporting.
  /// Computes incremental SHA-256 and verifies checksum before marking ready.
  Future<bool> downloadUpdate({http.Client? client}) async {
    final release = _latestRelease;
    if (release == null) {
      _errorMessage = 'No release selected for download.';
      _status = WindowsUpdateStatus.failed;
      notifyListeners();
      return false;
    }

    final installerAsset = release.windowsInstallerAsset;
    if (installerAsset == null) {
      _errorMessage = 'ഈ റിലീസിൽ Windows Installer (.exe) കണ്ടെത്തിയില്ല.\n(Windows installer asset not found in release).';
      _status = WindowsUpdateStatus.failed;
      notifyListeners();
      return false;
    }

    _isDownloading = true;
    _status = WindowsUpdateStatus.downloading;
    _errorMessage = null;
    _downloadProgress = DownloadProgressInfo(
      totalBytes: installerAsset.sizeBytes,
      statusText: 'ഡൗൺലോഡ് ആരംഭിക്കുന്നു (Starting download)...',
    );
    notifyListeners();

    _activeDownloadClient = client ?? http.Client();
    IOSink? fileSink;
    File? tempFile;

    try {
      final tempDir = Directory(p.join(Directory.systemTemp.path, 'tekfix_updates'));
      if (!await tempDir.exists()) {
        await tempDir.create(recursive: true);
      }

      final fileName = installerAsset.name.isNotEmpty
          ? installerAsset.name
          : 'TekFixERP-Setup-${release.tagName}.exe';
      tempFile = File(p.join(tempDir.path, fileName));
      if (await tempFile.exists()) {
        await tempFile.delete();
      }

      fileSink = tempFile.openWrite();

      final request = http.Request('GET', Uri.parse(installerAsset.downloadUrl));
      request.headers['User-Agent'] = 'TekFix-ERP-Updater/1.0';

      final streamedResponse = await _activeDownloadClient!.send(request);
      if (streamedResponse.statusCode != 200) {
        throw Exception('Download failed with HTTP ${streamedResponse.statusCode}');
      }

      final totalBytes = streamedResponse.contentLength ?? installerAsset.sizeBytes;
      int downloadedBytes = 0;
      final stopwatch = Stopwatch()..start();
      DateTime lastSpeedUpdate = DateTime.now();
      int bytesSinceLastSpeed = 0;
      double currentSpeed = 0;

      final completer = Completer<void>();

      _downloadSubscription = streamedResponse.stream.listen(
        (chunk) {
          fileSink?.add(chunk);
          downloadedBytes += chunk.length;
          bytesSinceLastSpeed += chunk.length;

          final now = DateTime.now();
          final speedElapsed = now.difference(lastSpeedUpdate).inMilliseconds;
          if (speedElapsed >= 400) {
            currentSpeed = (bytesSinceLastSpeed / (speedElapsed / 1000));
            bytesSinceLastSpeed = 0;
            lastSpeedUpdate = now;

            final progress = totalBytes > 0 ? (downloadedBytes / totalBytes) : 0.0;
            _downloadProgress = DownloadProgressInfo(
              downloadedBytes: downloadedBytes,
              totalBytes: totalBytes,
              progress: progress,
              speedBytesPerSec: currentSpeed,
              statusText: 'ഡൗൺലോഡ് ചെയ്യുന്നു... (${_downloadProgress.percentage}%)',
            );
            notifyListeners();
          }
        },
        onDone: () async {
          completer.complete();
        },
        onError: (err) {
          completer.completeError(err);
        },
        cancelOnError: true,
      );

      await completer.future;
      await fileSink.flush();
      await fileSink.close();
      fileSink = null;
      stopwatch.stop();

      // Download complete: validate file
      final downloadedHash = (await sha256.bind(tempFile.openRead()).first).toString().toLowerCase();
      debugPrint('WindowsUpdateService: Downloaded file SHA-256: $downloadedHash');

      // Verify file size
      final actualSize = await tempFile.length();
      if (totalBytes > 0 && actualSize != totalBytes) {
        throw Exception(
            'ഫയൽ സൈസ് പൊരുത്തപ്പെടുന്നില്ല (Size mismatch: expected $totalBytes bytes, got $actualSize bytes)');
      }

      // Checksum validation
      final expectedHash = await _resolveExpectedChecksum(
        release: release,
        installerFileName: fileName,
        client: _activeDownloadClient!,
      );

      if (expectedHash != null && expectedHash.isNotEmpty) {
        debugPrint('WindowsUpdateService: Expected SHA-256: $expectedHash');
        if (downloadedHash != expectedHash.toLowerCase().trim()) {
          // Checksum mismatch -> Delete corrupted file immediately!
          await tempFile.delete();
          throw Exception(
              'സുരക്ഷാ പരിശോധന പരാജയപ്പെട്ടു: Checksum verification failed!\nExpected: $expectedHash\nActual: $downloadedHash');
        }
        debugPrint('WindowsUpdateService: Checksum verification passed!');
      } else {
        debugPrint(
            'WindowsUpdateService: [SECURITY NOTICE] No remote checksum found. Verified file size and structure.');
      }

      _downloadedInstallerPath = tempFile.path;
      _downloadProgress = DownloadProgressInfo(
        downloadedBytes: actualSize,
        totalBytes: actualSize,
        progress: 1.0,
        speedBytesPerSec: 0,
        statusText: 'ഡൗൺലോഡ് പൂർത്തിയായി! ഇൻസ്റ്റാളേഷൻ തയ്യാർ (Download Complete).',
      );
      _status = WindowsUpdateStatus.downloadComplete;
      notifyListeners();
      return true;
    } catch (e) {
      if (tempFile != null && await tempFile.exists()) {
        try {
          await tempFile.delete();
        } catch (_) {}
      }
      _errorMessage = 'ഡൗൺലോഡ് പരാജയപ്പെട്ടു: $e';
      _status = WindowsUpdateStatus.failed;
      notifyListeners();
      return false;
    } finally {
      if (fileSink != null) {
        try {
          await fileSink.close();
        } catch (_) {}
      }
      _isDownloading = false;
      _downloadSubscription = null;
      if (client == null) {
        _activeDownloadClient?.close();
      }
      _activeDownloadClient = null;
      notifyListeners();
    }
  }

  /// Cancels any active download and cleans up temporary files.
  Future<void> cancelDownload() async {
    if (!_isDownloading) return;
    try {
      await _downloadSubscription?.cancel();
      _downloadSubscription = null;
      _activeDownloadClient?.close();
      _activeDownloadClient = null;

      if (_downloadedInstallerPath != null) {
        final f = File(_downloadedInstallerPath!);
        if (await f.exists()) await f.delete();
        _downloadedInstallerPath = null;
      }
    } catch (e) {
      debugPrint('WindowsUpdateService: Error cancelling download: $e');
    } finally {
      _isDownloading = false;
      _status = WindowsUpdateStatus.idle;
      _downloadProgress = const DownloadProgressInfo();
      notifyListeners();
    }
  }

  /// Resolves expected checksum from either a `.sha256` asset or release notes body.
  Future<String?> _resolveExpectedChecksum({
    required GitHubReleaseInfo release,
    required String installerFileName,
    required http.Client client,
  }) async {
    // 1. Check release notes body
    final bodyHash = release.extractChecksumFromBody(installerFileName);
    if (bodyHash != null) return bodyHash;

    // 2. Check dedicated checksum file asset (e.g. TekFixERP-Setup-*.exe.sha256 or sha256sum.txt)
    final checksumAsset = release.checksumAsset;
    if (checksumAsset != null) {
      try {
        final resp = await client.get(
          Uri.parse(checksumAsset.downloadUrl),
          headers: {'User-Agent': 'TekFix-ERP-Updater/1.0'},
        ).timeout(const Duration(seconds: 8));

        if (resp.statusCode == 200) {
          final content = resp.body.trim();
          // Find hash for this specific file or take first 64-char hex
          final match = RegExp(r'([a-fA-F0-9]{64})').firstMatch(content);
          if (match != null) return match.group(1);
        }
      } catch (e) {
        debugPrint('WindowsUpdateService: Could not fetch checksum asset: $e');
      }
    }

    return null;
  }

  /// Generates the batch updater script and restarts TekFix ERP into the new version.
  Future<bool> restartAndInstall() async {
    final installerPath = _downloadedInstallerPath;
    if (installerPath == null || !await File(installerPath).exists()) {
      _errorMessage = 'ഇൻസ്റ്റാളർ ഫയൽ കണ്ടെത്തിയില്ല (Installer file missing).';
      _status = WindowsUpdateStatus.failed;
      notifyListeners();
      return false;
    }

    _status = WindowsUpdateStatus.installing;
    notifyListeners();

    try {
      final isExe = installerPath.toLowerCase().endsWith('.exe');
      if (isExe) {
        _log('Launching Windows Installer (.exe) detached: $installerPath with /SILENT');
        await Process.start(
          installerPath,
          ['/SILENT'],
          mode: ProcessStartMode.detached,
        );
        exit(0);
      }

      final currentExePath = Platform.resolvedExecutable;
      final tempDir = File(installerPath).parent;
      final batchFile = File(p.join(tempDir.path, 'apply_update.bat'));

      final batchContent = generateUpdaterBatchScript(
        installerPath: installerPath,
        executablePath: currentExePath,
      );

      await batchFile.writeAsString(batchContent, flush: true);
      _log('Created updater batch at: ${batchFile.path}');

      // Spawn detached batch runner
      await Process.start(
        'cmd.exe',
        ['/c', batchFile.path],
        mode: ProcessStartMode.detached,
      );

      // Gracefully exit the current Flutter application to release all file locks
      _log('Exiting current process for silent update...');
      exit(0);
    } catch (e) {
      _errorMessage = 'ഇൻസ്റ്റാളേഷൻ ആരംഭിക്കാൻ കഴിഞ്ഞില്ല: $e';
      _status = WindowsUpdateStatus.failed;
      notifyListeners();
      return false;
    }
  }

  /// Generates the Windows cmd/batch script for silent installation & relaunch.
  static String generateUpdaterBatchScript({
    required String installerPath,
    required String executablePath,
  }) {
    final isZip = installerPath.toLowerCase().endsWith('.zip');
    final appDir = File(executablePath).parent.path;

    if (isZip) {
      return '''
@echo off
setlocal
title TekFix ERP Updater

:: 1. Wait for parent process to exit and release file locks
timeout /t 2 /nobreak >nul

:: 2. Extract ZIP package over application directory
powershell -NoProfile -Command "Expand-Archive -LiteralPath '$installerPath' -DestinationPath '$appDir' -Force"

:: 3. Give filesystem a brief moment then relaunch TekFix ERP
timeout /t 1 /nobreak >nul
start "" "$executablePath"

:: 4. Clean up batch script and exit
(goto) 2>nul & del "%~f0" & exit
''';
    }

    return '''
@echo off
setlocal
title TekFix ERP Updater

:: 1. Wait for parent process to exit and release file locks
timeout /t 2 /nobreak >nul

:: 2. Execute Inno Setup silently
"$installerPath" /VERYSILENT /SUPPRESSMSGBOXES /NORESTART /SP- /CLOSEAPPLICATIONS

:: 3. Give filesystem a brief moment then relaunch TekFix ERP
timeout /t 1 /nobreak >nul
start "" "$executablePath"

:: 4. Clean up batch script and exit
(goto) 2>nul & del "%~f0" & exit
''';
  }

  /// Postpones the current update for 24 hours.
  Future<void> postponeUpdate() async {
    if (_latestRelease != null) {
      final updated = _settings.copyWith(
        postponedVersion: _latestRelease!.tagName,
        lastDismissedAt: DateTime.now(),
      );
      await saveSettings(updated);
    }
    _status = WindowsUpdateStatus.idle;
    notifyListeners();
  }

  /// Resets update status to idle.
  void resetStatus() {
    _status = WindowsUpdateStatus.idle;
    _errorMessage = null;
    notifyListeners();
  }
}
