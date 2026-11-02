import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:tekfix_erp_pos/update/windows_update_models.dart';
import 'package:tekfix_erp_pos/update/windows_update_service.dart';

void main() {
  group('TEST 1: Semantic Version Parsing & Comparison', () {
    test('handles standard semantic versions correctly', () {
      final v104 = SemVer.parse('v1.0.4');
      final v105 = SemVer.parse('v1.0.5');
      final v109 = SemVer.parse('1.0.9');
      final v110 = SemVer.parse('1.1.0');
      final v199 = SemVer.parse('1.9.9');
      final v200 = SemVer.parse('v2.0.0');

      expect(v105.isGreaterThan(v104), isTrue);
      expect(v104.isLessThan(v105), isTrue);

      expect(v110.isGreaterThan(v109), isTrue);
      expect(v109.isLessThan(v110), isTrue);

      expect(v200.isGreaterThan(v199), isTrue);
      expect(v199.isLessThan(v200), isTrue);

      // Same version is not greater
      expect(v105.isGreaterThan(v105), isFalse);
      expect(v105.isEqualTo(v105), isTrue);
    });

    test('handles build numbers and prefixes correctly', () {
      final vBuild13 = SemVer.parse('1.0.13+13');
      final vBuild14 = SemVer.parse('1.0.13+14');
      expect(vBuild14.isGreaterThan(vBuild13), isTrue);

      final vWithV = SemVer.parse('v1.0.14');
      final vWithoutV = SemVer.parse('1.0.14');
      expect(vWithV.isEqualTo(vWithoutV), isTrue);
    });

    test('identifies prerelease versions', () {
      final beta = SemVer.parse('v1.0.15-beta.1');
      final release = SemVer.parse('v1.0.15');

      expect(beta.isPrerelease, isTrue);
      expect(release.isPrerelease, isFalse);
    });
  });

  group('TEST 2: GitHub Release JSON Parsing & Windows Asset Filtering', () {
    const mockReleaseJson = '''
    {
      "tag_name": "v1.0.14",
      "name": "TekFix ERP v1.0.14",
      "body": "## What's New\\n- Daily Rent Management added\\n- Expense Management improved\\n\\nSHA256: e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
      "published_at": "2026-11-02T10:00:00Z",
      "prerelease": false,
      "draft": false,
      "assets": [
        {
          "name": "source-code.zip",
          "browser_download_url": "https://github.com/infotekfix-del/tekfix_pos/archive/refs/tags/v1.0.14.zip",
          "size": 5242880,
          "content_type": "application/zip"
        },
        {
          "name": "TekFixERP-Setup-v1.0.14.exe",
          "browser_download_url": "https://github.com/infotekfix-del/tekfix_pos/releases/download/v1.0.14/TekFixERP-Setup-v1.0.14.exe",
          "size": 45000000,
          "content_type": "application/x-msdownload"
        },
        {
          "name": "TekFixERP-Setup-v1.0.14.exe.sha256",
          "browser_download_url": "https://github.com/infotekfix-del/tekfix_pos/releases/download/v1.0.14/TekFixERP-Setup-v1.0.14.exe.sha256",
          "size": 95,
          "content_type": "text/plain"
        }
      ]
    }
    ''';

    test('correctly parses release info and picks windows installer', () {
      final data = json.decode(mockReleaseJson) as Map<String, dynamic>;
      final release = GitHubReleaseInfo.fromJson(data);

      expect(release.tagName, equals('v1.0.14'));
      expect(release.name, equals('TekFix ERP v1.0.14'));
      expect(release.isPrerelease, isFalse);

      final installer = release.windowsInstallerAsset;
      expect(installer, isNotNull);
      expect(installer!.name, equals('TekFixERP-Setup-v1.0.14.exe'));
      expect(installer.sizeBytes, equals(45000000));
      expect(installer.isWindowsInstaller, isTrue);

      final checksumAsset = release.checksumAsset;
      expect(checksumAsset, isNotNull);
      expect(checksumAsset!.name, equals('TekFixERP-Setup-v1.0.14.exe.sha256'));

      final hashFromBody = release.extractChecksumFromBody('TekFixERP-Setup-v1.0.14.exe');
      expect(hashFromBody, equals('e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855'));
    });
  });

  group('TEST 3: Checksum Validation & Corrupted Installer Rejection', () {
    test('verifies valid SHA-256 checksum correctly', () {
      final sampleBytes = utf8.encode('TekFix ERP Secure Windows Installer Binary Payload');
      final calculatedHash = sha256.convert(sampleBytes).toString().toLowerCase();

      expect(calculatedHash.length, equals(64));

      // Matches exact hash
      expect(calculatedHash, equals(sha256.convert(sampleBytes).toString().toLowerCase()));
    });

    test('rejects tampered or mismatched checksum bytes', () {
      final goodBytes = utf8.encode('Original Genuine Installer Payload');
      final tamperedBytes = utf8.encode('Tampered Incomplete Payload');

      final goodHash = sha256.convert(goodBytes).toString().toLowerCase();
      final badHash = sha256.convert(tamperedBytes).toString().toLowerCase();

      expect(goodHash, isNot(equals(badHash)));
    });
  });

  group('TEST 4: Silent Updater Batch Script Generation', () {
    test('generates valid Windows batch script with required silent flags', () {
      const installerPath = r'C:\Users\User\AppData\Local\Temp\tekfix_updates\TekFixERP-Setup-v1.0.14.exe';
      const executablePath = r'C:\Program Files\TekFix ERP\tekfix_pos.exe';

      final script = WindowsUpdateService.generateUpdaterBatchScript(
        installerPath: installerPath,
        executablePath: executablePath,
      );

      expect(script, contains('@echo off'));
      expect(script, contains('timeout /t 2 /nobreak >nul'));
      expect(script, contains('/VERYSILENT'));
      expect(script, contains('/SUPPRESSMSGBOXES'));
      expect(script, contains('/NORESTART'));
      expect(script, contains('/SP-'));
      expect(script, contains('/CLOSEAPPLICATIONS'));
      expect(script, contains('start "" "$executablePath"'));
    });
  });

  group('TEST 5: Check For Updates with Mock Client', () {
    test('detects new version when remote is greater than installed', () async {
      final mockClient = MockClient((request) async {
        if (request.url.path.endsWith('/releases/latest')) {
          return http.Response(
            json.encode({
              'tag_name': 'v1.0.14',
              'name': 'TekFix ERP v1.0.14',
              'body': 'What is new in 1.0.14',
              'published_at': '2026-11-02T10:00:00Z',
              'prerelease': false,
              'assets': [
                {
                  'name': 'TekFixERP-Setup-v1.0.14.exe',
                  'browser_download_url': 'https://example.com/setup.exe',
                  'size': 1024,
                  'content_type': 'application/x-msdownload'
                }
              ]
            }),
            200,
          );
        }
        return http.Response('Not found', 404);
      });

      final service = WindowsUpdateService.instance;
      final release = await service.checkForUpdates(
        client: mockClient,
        overrideCurrentVersion: '1.0.13',
        isManual: true,
      );

      expect(release, isNotNull);
      expect(release!.tagName, equals('v1.0.14'));
      expect(service.status, equals(WindowsUpdateStatus.updateAvailable));
      expect(service.isUpdateAvailable, isTrue);
    });

    test('reports up to date when current version is equal or newer', () async {
      final mockClient = MockClient((request) async {
        return http.Response(
          json.encode({
            'tag_name': 'v1.0.13',
            'name': 'TekFix ERP v1.0.13',
            'body': 'Current release',
            'published_at': '2026-11-01T10:00:00Z',
            'prerelease': false,
            'assets': []
          }),
          200,
        );
      });

      final service = WindowsUpdateService.instance;
      final release = await service.checkForUpdates(
        client: mockClient,
        overrideCurrentVersion: '1.0.13',
        isManual: true,
      );

      expect(release, isNull);
      expect(service.status, equals(WindowsUpdateStatus.upToDate));
      expect(service.isUpdateAvailable, isFalse);
    });
  });

  group('TEST 6: Download & Checksum Verification in Service', () {
    test('downloads and verifies valid file successfully', () async {
      final payload = utf8.encode('Simulated Windows Installer Binary Content For Verification');
      final payloadSha256 = sha256.convert(payload).toString().toLowerCase();

      final mockClient = MockClient((request) async {
        if (request.url.path.endsWith('/releases/latest')) {
          return http.Response(
            json.encode({
              'tag_name': 'v1.0.14',
              'name': 'TekFix ERP v1.0.14',
              'body': 'Release with hash\\nSHA256: $payloadSha256',
              'published_at': '2026-11-02T10:00:00Z',
              'prerelease': false,
              'assets': [
                {
                  'name': 'TekFixERP-Setup-v1.0.14.exe',
                  'browser_download_url': 'https://example.com/download/TekFixERP-Setup-v1.0.14.exe',
                  'size': payload.length,
                  'content_type': 'application/x-msdownload'
                }
              ]
            }),
            200,
          );
        } else if (request.url.path.contains('TekFixERP-Setup-v1.0.14.exe')) {
          return http.Response.bytes(payload, 200);
        }
        return http.Response('Not found', 404);
      });

      final service = WindowsUpdateService.instance;
      await service.checkForUpdates(
        client: mockClient,
        overrideCurrentVersion: '1.0.13',
        isManual: true,
      );

      final success = await service.downloadUpdate(client: mockClient);
      expect(success, isTrue);
      expect(service.status, equals(WindowsUpdateStatus.downloadComplete));
      expect(service.downloadedInstallerPath, isNotNull);

      // Verify downloaded file on disk
      final file = File(service.downloadedInstallerPath!);
      expect(await file.exists(), isTrue);
      final fileBytes = await file.readAsBytes();
      expect(fileBytes, equals(payload));

      // Cleanup
      await file.delete();
    });

    test('rejects download when SHA-256 checksum mismatches and deletes file', () async {
      final payload = utf8.encode('Corrupted Or Modified Installer Content');
      const bogusExpectedHash = '0000000000000000000000000000000000000000000000000000000000000000';

      final mockClient = MockClient((request) async {
        if (request.url.path.endsWith('/releases/latest')) {
          return http.Response(
            json.encode({
              'tag_name': 'v1.0.14',
              'name': 'TekFix ERP v1.0.14',
              'body': 'Release with bad hash\\nSHA256: $bogusExpectedHash',
              'published_at': '2026-11-02T10:00:00Z',
              'prerelease': false,
              'assets': [
                {
                  'name': 'TekFixERP-Setup-v1.0.14.exe',
                  'browser_download_url': 'https://example.com/download/TekFixERP-Setup-v1.0.14.exe',
                  'size': payload.length,
                  'content_type': 'application/x-msdownload'
                }
              ]
            }),
            200,
          );
        } else if (request.url.path.contains('TekFixERP-Setup-v1.0.14.exe')) {
          return http.Response.bytes(payload, 200);
        }
        return http.Response('Not found', 404);
      });

      final service = WindowsUpdateService.instance;
      await service.checkForUpdates(
        client: mockClient,
        overrideCurrentVersion: '1.0.13',
        isManual: true,
      );

      final success = await service.downloadUpdate(client: mockClient);
      expect(success, isFalse);
      expect(service.status, equals(WindowsUpdateStatus.failed));
      expect(service.errorMessage, contains('Checksum verification failed'));
    });
  });

  group('TEST 7: Offline & Network Error Handling', () {
    test('handles network failure gracefully without crashing', () async {
      final mockClient = MockClient((request) async {
        throw const SocketException('No address associated with hostname');
      });

      final service = WindowsUpdateService.instance;
      final release = await service.checkForUpdates(
        client: mockClient,
        overrideCurrentVersion: '1.0.13',
        isManual: true,
      );

      expect(release, isNull);
      expect(service.status, equals(WindowsUpdateStatus.failed));
      expect(service.errorMessage, contains('ഇന്റർനെറ്റ് കണക്ഷൻ ലഭ്യമല്ല'));
    });
  });

  group('TEST 8: Settings Persistence & Postponed Updates', () {
    test('serializes and deserializes settings faithfully', () {
      final now = DateTime.now();
      final settings = WindowsUpdateSettings(
        autoCheckUpdates: true,
        checkOnStartup: false,
        showReleaseNotifications: true,
        githubOwner: 'test-owner',
        githubRepo: 'test-repo',
        postponedVersion: 'v1.0.14',
        lastDismissedAt: now,
      );

      final map = settings.toMap();
      final recovered = WindowsUpdateSettings.fromMap(map);

      expect(recovered.autoCheckUpdates, isTrue);
      expect(recovered.checkOnStartup, isFalse);
      expect(recovered.showReleaseNotifications, isTrue);
      expect(recovered.githubOwner, equals('test-owner'));
      expect(recovered.githubRepo, equals('test-repo'));
      expect(recovered.postponedVersion, equals('v1.0.14'));
      expect(recovered.lastDismissedAt?.millisecondsSinceEpoch,
          equals(now.millisecondsSinceEpoch));
    });
  });
}
