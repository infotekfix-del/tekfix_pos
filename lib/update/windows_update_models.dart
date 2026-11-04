/// Semantic version representation and comparison for TekFix ERP.
class SemVer implements Comparable<SemVer> {
  final int major;
  final int minor;
  final int patch;
  final int build;
  final String raw;
  final bool isPrerelease;

  const SemVer({
    required this.major,
    required this.minor,
    required this.patch,
    this.build = 0,
    required this.raw,
    this.isPrerelease = false,
  });

  /// Parses strings like "v1.0.14", "1.0.14+14", "v2.1.0-beta.1"
  factory SemVer.parse(String input) {
    final clean = input.trim().replaceFirst(RegExp(r'^[vV]'), '');
    final isPre = clean.contains('-') ||
        clean.toLowerCase().contains('beta') ||
        clean.toLowerCase().contains('rc') ||
        clean.toLowerCase().contains('alpha');

    // Split build metadata after '+'
    final plusSplit = clean.split('+');
    final versionCore = plusSplit.first.split('-').first.trim();
    int buildNumber = 0;
    if (plusSplit.length > 1) {
      buildNumber = int.tryParse(plusSplit[1].trim()) ?? 0;
    }

    final parts =
        versionCore.split('.').map((e) => int.tryParse(e.trim()) ?? 0).toList();
    final maj = parts.isNotEmpty ? parts[0] : 0;
    final min = parts.length > 1 ? parts[1] : 0;
    final pat = parts.length > 2 ? parts[2] : 0;

    return SemVer(
      major: maj,
      minor: min,
      patch: pat,
      build: buildNumber,
      raw: input.trim(),
      isPrerelease: isPre,
    );
  }

  @override
  int compareTo(SemVer other) {
    if (major != other.major) return major.compareTo(other.major);
    if (minor != other.minor) return minor.compareTo(other.minor);
    if (patch != other.patch) return patch.compareTo(other.patch);
    if (build != other.build) return build.compareTo(other.build);
    return 0;
  }

  bool isGreaterThan(SemVer other) => compareTo(other) > 0;
  bool isLessThan(SemVer other) => compareTo(other) < 0;
  bool isEqualTo(SemVer other) => compareTo(other) == 0;

  @override
  String toString() => raw;
}

/// Information about a downloaded or downloadable release asset.
class GitHubReleaseAsset {
  final String name;
  final String downloadUrl;
  final int sizeBytes;
  final String contentType;

  const GitHubReleaseAsset({
    required this.name,
    required this.downloadUrl,
    required this.sizeBytes,
    required this.contentType,
  });

  factory GitHubReleaseAsset.fromJson(Map<String, dynamic> json) {
    return GitHubReleaseAsset(
      name: (json['name'] ?? '').toString(),
      downloadUrl: (json['browser_download_url'] ?? '').toString(),
      sizeBytes: json['size'] is int
          ? json['size']
          : int.tryParse(json['size']?.toString() ?? '0') ?? 0,
      contentType: (json['content_type'] ?? '').toString(),
    );
  }

  bool get isWindowsInstaller {
    final lower = name.toLowerCase();
    return (lower.endsWith('.exe') || lower.endsWith('.zip')) &&
        !lower.endsWith('.sha256') &&
        !lower.endsWith('.md5') &&
        !lower.contains('source');
  }

  bool get isChecksumFile {
    final lower = name.toLowerCase();
    return lower.endsWith('.sha256') ||
        lower == 'sha256sum.txt' ||
        lower.endsWith('.sha256.txt');
  }
}

/// Metadata parsed from GitHub Releases API.
class GitHubReleaseInfo {
  final String tagName;
  final String name;
  final String body;
  final DateTime publishedAt;
  final bool isPrerelease;
  final List<GitHubReleaseAsset> assets;
  final SemVer semVer;

  const GitHubReleaseInfo({
    required this.tagName,
    required this.name,
    required this.body,
    required this.publishedAt,
    required this.isPrerelease,
    required this.assets,
    required this.semVer,
  });

  factory GitHubReleaseInfo.fromJson(Map<String, dynamic> json) {
    final tag = (json['tag_name'] ?? '').toString().trim();
    final assetsList = (json['assets'] as List<dynamic>? ?? [])
        .map((a) => GitHubReleaseAsset.fromJson(a as Map<String, dynamic>))
        .toList();

    DateTime pubDate = DateTime.now();
    if (json['published_at'] != null) {
      pubDate =
          DateTime.tryParse(json['published_at'].toString()) ?? DateTime.now();
    }

    return GitHubReleaseInfo(
      tagName: tag,
      name: (json['name'] ?? tag).toString().trim(),
      body: (json['body'] ?? '').toString().trim(),
      publishedAt: pubDate,
      isPrerelease: json['prerelease'] == true,
      assets: assetsList,
      semVer: SemVer.parse(tag),
    );
  }

  /// Locates the primary Windows Inno Setup installer or release ZIP asset.
  GitHubReleaseAsset? get windowsInstallerAsset {
    // 1. Prefer Inno Setup .exe installer
    for (final a in assets) {
      if (a.isWindowsInstaller && a.name.toLowerCase().endsWith('.exe')) {
        return a;
      }
    }
    // 2. Fallback to windows release zip
    for (final a in assets) {
      if (a.isWindowsInstaller && a.name.toLowerCase().contains('windows')) {
        return a;
      }
    }
    // 3. Fallback to any windows asset
    for (final a in assets) {
      if (a.isWindowsInstaller) return a;
    }
    return null;
  }

  /// Locates the corresponding SHA-256 checksum asset.
  GitHubReleaseAsset? get checksumAsset {
    for (final a in assets) {
      if (a.isChecksumFile) return a;
    }
    return null;
  }

  /// Extracts SHA-256 hash from release body if present (e.g., "SHA256: 4a3f..." or "[hash] TekFixERP-Setup...").
  String? extractChecksumFromBody(String installerFileName) {
    if (body.isEmpty) return null;

    // Pattern 1: e.g. "a1b2c3d4... TekFixERP-Setup-v1.0.14.exe"
    final escapedName = RegExp.escape(installerFileName);
    final regFile = RegExp(r'([a-fA-F0-9]{64})\s+[*]?\s*' + escapedName,
        caseSensitive: false);
    final matchFile = regFile.firstMatch(body);
    if (matchFile != null) return matchFile.group(1)?.toLowerCase();

    // Pattern 2: e.g. "SHA256: a1b2c3d4..."
    final regSha = RegExp(r'(?:SHA256|SHA-256|checksum)[\s:]+([a-fA-F0-9]{64})',
        caseSensitive: false);
    final matchSha = regSha.firstMatch(body);
    if (matchSha != null) return matchSha.group(1)?.toLowerCase();

    return null;
  }
}

/// Current status of the updater engine.
enum WindowsUpdateStatus {
  idle,
  checking,
  upToDate,
  updateAvailable,
  downloading,
  downloadComplete,
  installing,
  failed,
}

/// Download metrics for UI display.
class DownloadProgressInfo {
  final int downloadedBytes;
  final int totalBytes;
  final double progress; // 0.0 to 1.0
  final double speedBytesPerSec;
  final String statusText;

  const DownloadProgressInfo({
    this.downloadedBytes = 0,
    this.totalBytes = 0,
    this.progress = 0.0,
    this.speedBytesPerSec = 0.0,
    this.statusText = '',
  });

  String get downloadedFormatted => _formatBytes(downloadedBytes);
  String get totalFormatted => _formatBytes(totalBytes);
  String get speedFormatted => '${_formatBytes(speedBytesPerSec.toInt())}/s';
  int get percentage => (progress * 100).clamp(0, 100).toInt();

  static String _formatBytes(int bytes) {
    if (bytes <= 0) return '0 MB';
    final mb = bytes / (1024 * 1024);
    if (mb < 0.1) {
      final kb = bytes / 1024;
      return '${kb.toStringAsFixed(1)} KB';
    }
    return '${mb.toStringAsFixed(2)} MB';
  }
}

/// Persistent settings for auto-updating.
class WindowsUpdateSettings {
  final bool autoCheckUpdates;
  final bool checkOnStartup;
  final bool showReleaseNotifications;
  final String githubOwner;
  final String githubRepo;
  final String? postponedVersion;
  final DateTime? lastDismissedAt;
  final DateTime? lastCheckedAt;

  const WindowsUpdateSettings({
    this.autoCheckUpdates = true,
    this.checkOnStartup = true,
    this.showReleaseNotifications = true,
    this.githubOwner = 'infotekfix-del',
    this.githubRepo = 'tekfix_pos',
    this.postponedVersion,
    this.lastDismissedAt,
    this.lastCheckedAt,
  });

  WindowsUpdateSettings copyWith({
    bool? autoCheckUpdates,
    bool? checkOnStartup,
    bool? showReleaseNotifications,
    String? githubOwner,
    String? githubRepo,
    String? postponedVersion,
    DateTime? lastDismissedAt,
    DateTime? lastCheckedAt,
  }) {
    return WindowsUpdateSettings(
      autoCheckUpdates: autoCheckUpdates ?? this.autoCheckUpdates,
      checkOnStartup: checkOnStartup ?? this.checkOnStartup,
      showReleaseNotifications:
          showReleaseNotifications ?? this.showReleaseNotifications,
      githubOwner: githubOwner ?? this.githubOwner,
      githubRepo: githubRepo ?? this.githubRepo,
      postponedVersion: postponedVersion ?? this.postponedVersion,
      lastDismissedAt: lastDismissedAt ?? this.lastDismissedAt,
      lastCheckedAt: lastCheckedAt ?? this.lastCheckedAt,
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'autoCheckUpdates': autoCheckUpdates,
      'checkOnStartup': checkOnStartup,
      'showReleaseNotifications': showReleaseNotifications,
      'githubOwner': githubOwner,
      'githubRepo': githubRepo,
      'postponedVersion': postponedVersion,
      'lastDismissedAt': lastDismissedAt?.toIso8601String(),
      'lastCheckedAt': lastCheckedAt?.toIso8601String(),
    };
  }

  factory WindowsUpdateSettings.fromMap(Map<dynamic, dynamic>? map) {
    if (map == null) return const WindowsUpdateSettings();
    return WindowsUpdateSettings(
      autoCheckUpdates: map['autoCheckUpdates'] ?? true,
      checkOnStartup: map['checkOnStartup'] ?? true,
      showReleaseNotifications: map['showReleaseNotifications'] ?? true,
      githubOwner: (map['githubOwner'] ?? 'infotekfix-del').toString().trim(),
      githubRepo: (map['githubRepo'] ?? 'tekfix_pos').toString().trim(),
      postponedVersion: map['postponedVersion']?.toString(),
      lastDismissedAt: map['lastDismissedAt'] != null
          ? DateTime.tryParse(map['lastDismissedAt'].toString())
          : null,
      lastCheckedAt: map['lastCheckedAt'] != null
          ? DateTime.tryParse(map['lastCheckedAt'].toString())
          : null,
    );
  }
}
