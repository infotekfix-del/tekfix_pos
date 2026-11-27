import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// ============================================================================
/// TEKFIX ERP - PHASE 14.7.1: STANDALONE ANDROID HARDWARE SECURITY AUDIT
/// ============================================================================
/// 
/// Independent, local-only Android Keystore verification tool.
/// ZERO remote database connections, ZERO Firebase calls, ZERO production credentials.
/// ============================================================================

class HardwareAuditScreen extends StatefulWidget {
  const HardwareAuditScreen({super.key});

  @override
  State<HardwareAuditScreen> createState() => _HardwareAuditScreenState();
}

class _HardwareAuditScreenState extends State<HardwareAuditScreen> {
  static const MethodChannel _keystoreChannel =
      MethodChannel('com.example.tekfix_pos/keystore');

  bool _isRunning = false;
  Map<String, dynamic>? _deviceInfo;
  final List<_AuditTestStep> _testSteps = [];
  String _finalDecision = 'NOT_RUN';
  String _detailedReportJson = '';

  @override
  void initState() {
    super.initState();
    _loadDeviceInformation();
  }

  Future<void> _loadDeviceInformation() async {
    try {
      final info = await _keystoreChannel.invokeMapMethod<String, dynamic>('getDeviceHardwareInfo');
      if (mounted) {
        setState(() {
          _deviceInfo = info != null ? Map<String, dynamic>.from(info) : null;
        });
      }
    } catch (e) {
      debugPrint('[HardwareAudit] Error loading device info: $e');
    }
  }

  /// Byte-safe signature parser handling both Base64 and Hex encodings.
  /// Prevents radix-16 FormatException when Android Keystore returns Base64 (starts with "ME...").
  Uint8List _parseSignatureBytes(String rawSig) {
    final trimmed = rawSig.trim();
    // If it is hexadecimal (starts with ASN.1 sequence 0x30, even length, valid hex characters)
    final hexRegex = RegExp(r'^[0-9a-fA-F]+$');
    if (trimmed.length % 2 == 0 && hexRegex.hasMatch(trimmed) && trimmed.startsWith('30')) {
      final bytes = <int>[];
      for (var i = 0; i < trimmed.length; i += 2) {
        bytes.add(int.parse(trimmed.substring(i, i + 2), radix: 16));
      }
      return Uint8List.fromList(bytes);
    }

    // Standard Android Keystore ASN.1 DER signature in Base64 (starts with "ME...")
    try {
      return Uint8List.fromList(base64Decode(trimmed));
    } catch (_) {
      // Fallback: attempt hex parsing if base64 decoding fails
      try {
        final bytes = <int>[];
        for (var i = 0; i < trimmed.length; i += 2) {
          bytes.add(int.parse(trimmed.substring(i, i + 2), radix: 16));
        }
        return Uint8List.fromList(bytes);
      } catch (_) {
        return Uint8List(0);
      }
    }
  }

  Future<void> _runHardwareSecurityAudit() async {
    setState(() {
      _isRunning = true;
      _testSteps.clear();
      _finalDecision = 'RUNNING';
      _detailedReportJson = '';
    });

    final testAlias = 'tekfix_audit_p256_${DateTime.now().millisecondsSinceEpoch}';
    final report = <String, dynamic>{
      'auditId': 'TEKFIX_AUDIT_${DateTime.now().toIso8601String().replaceAll(':', '-')}',
      'timestamp': DateTime.now().toIso8601String(),
      'deviceInfo': _deviceInfo ?? {},
      'tests': <Map<String, dynamic>>[],
      'finalDecision': 'NOT_VERIFIED',
    };

    try {
      // ----------------------------------------------------------------------
      // TEST 1: Device Telemetry & OS Security Patch
      // ----------------------------------------------------------------------
      final hasStrongBox = _deviceInfo?['hasStrongBoxFeature'] == true;
      final sdkInt = (_deviceInfo?['sdkInt'] as num?)?.toInt() ?? 0;
      final patch = _deviceInfo?['securityPatch'] ?? 'unknown';

      _addStep(
        name: 'Device Telemetry & OS Baseline',
        status: sdkInt >= 28 ? _TestStatus.passed : _TestStatus.warning,
        details: 'Android ${_deviceInfo?['androidVersion'] ?? 'N/A'} (API $sdkInt), Patch: $patch, StrongBox Feature: $hasStrongBox',
      );
      report['tests'].add({
        'testName': 'Device Telemetry',
        'passed': true,
        'details': _testSteps.last.details,
      });

      // ----------------------------------------------------------------------
      // TEST 2: EC P-256 Key Generation in AndroidKeyStore
      // ----------------------------------------------------------------------
      final keyResult = await _keystoreChannel.invokeMapMethod<String, dynamic>(
        'generateKey',
        {'alias': testAlias},
      );
      final pubPem = keyResult?['publicKeyPem'] as String? ?? '';
      final reportedLevel = keyResult?['securityLevel'] as String? ?? 'software_sandboxed';

      final hasValidPubPem = pubPem.contains('-----BEGIN PUBLIC KEY-----');
      _addStep(
        name: 'NIST P-256 (secp256r1) Key Generation',
        status: hasValidPubPem ? _TestStatus.passed : _TestStatus.failed,
        details: hasValidPubPem
            ? 'Key generated successfully. SubjectPublicKeyInfo (SPKI) X.509 PEM received (${pubPem.length} chars).'
            : 'Key generation failed to return valid public key PEM.',
      );
      report['tests'].add({
        'testName': 'Key Generation',
        'passed': hasValidPubPem,
        'securityLevelReported': reportedLevel,
      });

      // ----------------------------------------------------------------------
      // TEST 3: Hardware Enclave & KeyInfo Inspection
      // ----------------------------------------------------------------------
      final extractTest = await _keystoreChannel.invokeMapMethod<String, dynamic>(
        'verifyPrivateKeyNonExtractable',
        {'alias': testAlias},
      );
      final isInsideSecureHardware = extractTest?['isInsideSecureHardware'] == true;
      final keySecurityLevel = extractTest?['securityLevel'] as String? ?? reportedLevel;

      _TestStatus enclaveStatus = _TestStatus.failed;
      if (keySecurityLevel == 'STRONGBOX_BACKED') {
        enclaveStatus = _TestStatus.passed;
      } else if (keySecurityLevel == 'TEE_BACKED' || isInsideSecureHardware) {
        enclaveStatus = _TestStatus.passed;
      } else {
        enclaveStatus = _TestStatus.warning;
      }

      _addStep(
        name: 'Hardware Enclave Classification',
        status: enclaveStatus,
        details: 'KeyInfo Security Level: $keySecurityLevel (Secure Hardware: $isInsideSecureHardware)',
      );
      report['tests'].add({
        'testName': 'Hardware Enclave Classification',
        'passed': isInsideSecureHardware,
        'keySecurityLevel': keySecurityLevel,
      });

      // ----------------------------------------------------------------------
      // TEST 4: Private Key Non-Extractability Test
      // ----------------------------------------------------------------------
      final isNonExtractable = extractTest?['isNonExtractable'] == true;
      final keyFormat = extractTest?['format'] as String? ?? 'NONE';

      _addStep(
        name: 'Private Key Non-Extractability Barrier',
        status: isNonExtractable ? _TestStatus.passed : _TestStatus.failed,
        details: isNonExtractable
            ? 'PrivateKey.encoded is NULL. Key material is non-exportable and locked inside hardware enclave.'
            : 'CRITICAL FAILURE: Private key bytes were extractable (Format: $keyFormat)!',
      );
      report['tests'].add({
        'testName': 'Private Key Non-Extractability',
        'passed': isNonExtractable,
        'format': keyFormat,
      });

      // ----------------------------------------------------------------------
      // TEST 5: Native SHA256withECDSA Signing
      // ----------------------------------------------------------------------
      final challengePayload = 'TEKFIX_AUDIT_CHALLENGE_${DateTime.now().toIso8601String()}';
      final payloadBytes = Uint8List.fromList(utf8.encode(challengePayload));

      final rawSignature = await _keystoreChannel.invokeMethod<String>(
        'signPayload',
        {'alias': testAlias, 'payload': payloadBytes},
      );
      final hasSignature = rawSignature != null && rawSignature.isNotEmpty;
      Uint8List sigBytes = Uint8List(0);
      String sigBase64 = '';
      String sigHex = '';
      bool isValidAsn1 = false;

      if (hasSignature) {
        sigBytes = _parseSignatureBytes(rawSignature);
        sigBase64 = base64Encode(sigBytes);
        sigHex = sigBytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
        // Check ASN.1 DER Header: 0x30 (SEQUENCE tag)
        isValidAsn1 = sigBytes.isNotEmpty && sigBytes[0] == 0x30;
      }

      final sigPrefix = sigBase64.length >= 4 ? sigBase64.substring(0, 4) : sigBase64;
      _addStep(
        name: 'Native SHA256withECDSA Signing',
        status: (hasSignature && isValidAsn1) ? _TestStatus.passed : _TestStatus.failed,
        details: (hasSignature && isValidAsn1)
            ? 'Generated ${sigBytes.length}-byte ASN.1 DER ECDSA signature natively (DER Header 0x30, Base64 prefix "$sigPrefix").'
            : 'Signing operation failed or returned malformed signature.',
      );
      report['tests'].add({
        'testName': 'Native Signing',
        'passed': hasSignature && isValidAsn1,
        'signatureLengthBytes': sigBytes.length,
        'asn1HeaderValid': isValidAsn1,
        'sigHex': sigHex,
      });

      // ----------------------------------------------------------------------
      // TEST 6: Asymmetric Signature Verification (Authentic Payload)
      // ----------------------------------------------------------------------
      bool isSigValid = false;
      if (hasSignature && isValidAsn1) {
        isSigValid = await _keystoreChannel.invokeMethod<bool>(
          'verifySignatureNatively',
          {
            'alias': testAlias,
            'payload': payloadBytes,
            'signatureBase64': sigBase64,
          },
        ) ?? false;
      }

      _addStep(
        name: 'Asymmetric Signature Verification',
        status: isSigValid ? _TestStatus.passed : _TestStatus.failed,
        details: isSigValid
            ? 'Signature mathematically verified against enrolled X.509 Public Key.'
            : 'Signature failed mathematical verification.',
      );
      report['tests'].add({
        'testName': 'Signature Verification',
        'passed': isSigValid,
      });

      // ----------------------------------------------------------------------
      // TEST 7: Tampered Payload Rejection (Data Integrity)
      // ----------------------------------------------------------------------
      bool tamperedPayloadRejected = false;
      if (isSigValid) {
        final tamperedPayload = Uint8List.fromList(utf8.encode('${challengePayload}_TAMPERED'));
        final tamperedPayloadVerified = await _keystoreChannel.invokeMethod<bool>(
          'verifySignatureNatively',
          {
            'alias': testAlias,
            'payload': tamperedPayload,
            'signatureBase64': sigBase64,
          },
        ) ?? false;
        tamperedPayloadRejected = !tamperedPayloadVerified;
      }

      _addStep(
        name: 'Tampered Payload Rejection (Data Integrity)',
        status: tamperedPayloadRejected ? _TestStatus.passed : _TestStatus.failed,
        details: tamperedPayloadRejected
            ? 'Mutated payload correctly rejected by native ECDSA verifier.'
            : 'CRITICAL FAILURE: Native verifier accepted a tampered payload!',
      );
      report['tests'].add({
        'testName': 'Tampered Payload Rejection',
        'passed': tamperedPayloadRejected,
      });

      // ----------------------------------------------------------------------
      // TEST 8: Tampered Signature Rejection (Signature Integrity)
      // ----------------------------------------------------------------------
      bool tamperedSigRejected = false;
      if (isSigValid && sigBytes.isNotEmpty) {
        final mutatedSigBytes = Uint8List.fromList(sigBytes);
        final mid = mutatedSigBytes.length ~/ 2;
        mutatedSigBytes[mid] = (mutatedSigBytes[mid] ^ 0xFF);
        final mutatedSigBase64 = base64Encode(mutatedSigBytes);

        final tamperedSigVerified = await _keystoreChannel.invokeMethod<bool>(
          'verifySignatureNatively',
          {
            'alias': testAlias,
            'payload': payloadBytes,
            'signatureBase64': mutatedSigBase64,
          },
        ) ?? false;
        tamperedSigRejected = !tamperedSigVerified;
      }

      _addStep(
        name: 'Tampered Signature Rejection (Signature Integrity)',
        status: tamperedSigRejected ? _TestStatus.passed : _TestStatus.failed,
        details: tamperedSigRejected
            ? 'Mutated signature correctly rejected by native ECDSA verifier.'
            : 'CRITICAL FAILURE: Native verifier accepted a tampered signature!',
      );
      report['tests'].add({
        'testName': 'Tampered Signature Rejection',
        'passed': tamperedSigRejected,
      });

      // ----------------------------------------------------------------------
      // TEST 9: Persistence Verification in AndroidKeyStore
      // ----------------------------------------------------------------------
      final hasKey = await _keystoreChannel.invokeMethod<bool>('hasKey', {'alias': testAlias}) ?? false;
      _addStep(
        name: 'Hardware Key Persistence',
        status: hasKey ? _TestStatus.passed : _TestStatus.failed,
        details: hasKey
            ? 'Key alias verified present in AndroidKeyStore provider.'
            : 'Key alias could not be re-located in Keystore.',
      );
      report['tests'].add({
        'testName': 'Key Persistence',
        'passed': hasKey,
      });

      // ----------------------------------------------------------------------
      // TEST 10: Key Revocation & Deletion Lifecycle
      // ----------------------------------------------------------------------
      await _keystoreChannel.invokeMethod('deleteKey', {'alias': testAlias});
      final hasKeyAfterDelete = await _keystoreChannel.invokeMethod<bool>('hasKey', {'alias': testAlias}) ?? false;
      final deletePassed = !hasKeyAfterDelete;

      _addStep(
        name: 'Key Revocation & Clean Wipe',
        status: deletePassed ? _TestStatus.passed : _TestStatus.failed,
        details: deletePassed
            ? 'Key deleted from hardware storage. Re-query confirmed absence.'
            : 'Key deletion failed; alias still present.',
      );
      report['tests'].add({
        'testName': 'Key Deletion Lifecycle',
        'passed': deletePassed,
      });

      // ----------------------------------------------------------------------
      // FINAL DECISION DETERMINATION
      // ----------------------------------------------------------------------
      final allCoreTestsPassed = hasValidPubPem &&
          isNonExtractable &&
          hasSignature &&
          isValidAsn1 &&
          isSigValid &&
          tamperedPayloadRejected &&
          tamperedSigRejected &&
          hasKey &&
          deletePassed;

      if (allCoreTestsPassed) {
        if (keySecurityLevel == 'STRONGBOX_BACKED' || keySecurityLevel == 'hardware_strongbox') {
          _finalDecision = 'STRONGBOX_BACKED';
        } else if (keySecurityLevel == 'TEE_BACKED' || keySecurityLevel == 'hardware_tee' || isInsideSecureHardware) {
          _finalDecision = 'TEE_BACKED';
        } else {
          _finalDecision = 'SOFTWARE_BACKED';
        }
      } else {
        _finalDecision = 'FAILED';
      }

      report['finalDecision'] = _finalDecision;
      _detailedReportJson = const JsonEncoder.withIndent('  ').convert(report);

    } catch (e) {
      _addStep(
        name: 'Audit Execution Exception',
        status: _TestStatus.failed,
        details: 'Exception caught: $e',
      );
      _finalDecision = 'FAILED';
      report['finalDecision'] = 'FAILED';
      report['error'] = e.toString();
      _detailedReportJson = const JsonEncoder.withIndent('  ').convert(report);
    } finally {
      if (mounted) {
        setState(() {
          _isRunning = false;
        });
      }
    }
  }

  void _addStep({
    required String name,
    required _TestStatus status,
    required String details,
  }) {
    _testSteps.add(_AuditTestStep(name: name, status: status, details: details));
  }

  Future<void> _shareReport() async {
    if (_detailedReportJson.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please run the hardware audit first.')),
      );
      return;
    }

    try {
      await _keystoreChannel.invokeMethod('shareTextReport', {
        'title': 'TekFix Android Hardware Security Audit Report',
        'reportText': _detailedReportJson,
      });
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed to share report: $e')),
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
        title: const Text(
          'TekFix Hardware Security Audit',
          style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18),
        ),
        backgroundColor: isDark ? const Color(0xFF1E293B) : Colors.white,
        elevation: 1,
        actions: [
          IconButton(
            icon: const Icon(Icons.share),
            tooltip: 'Share Audit Report',
            onPressed: _detailedReportJson.isNotEmpty ? _shareReport : null,
          ),
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // 1. Device Info Card
            _buildSectionHeader('DEVICE INFORMATION', Icons.phone_android),
            const SizedBox(height: 8),
            _buildDeviceInfoCard(isDark),

            const SizedBox(height: 20),

            // 2. Action & Decision Banner
            _buildDecisionBanner(),

            const SizedBox(height: 16),

            // Run Audit Button
            ElevatedButton.icon(
              onPressed: _isRunning ? null : _runHardwareSecurityAudit,
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF2563EB),
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(vertical: 14),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
              ),
              icon: _isRunning
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2),
                    )
                  : const Icon(Icons.security),
              label: Text(
                _isRunning ? 'RUNNING ON-DEVICE AUDIT...' : 'RUN HARDWARE AUDIT',
                style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15),
              ),
            ),

            const SizedBox(height: 24),

            // 3. Test Steps List
            if (_testSteps.isNotEmpty) ...[
              _buildSectionHeader('TEST RESULTS', Icons.fact_check),
              const SizedBox(height: 8),
              ..._testSteps.map((step) => _buildTestStepTile(step, isDark)),
              const SizedBox(height: 20),
            ],

            // 4. Export & Share Button
            if (_detailedReportJson.isNotEmpty) ...[
              OutlinedButton.icon(
                onPressed: _shareReport,
                style: OutlinedButton.styleFrom(
                  foregroundColor: const Color(0xFF2563EB),
                  side: const BorderSide(color: Color(0xFF2563EB), width: 1.5),
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                ),
                icon: const Icon(Icons.ios_share),
                label: const Text(
                  'EXPORT & SHARE AUDIT REPORT (JSON)',
                  style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
                ),
              ),
              const SizedBox(height: 24),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildSectionHeader(String title, IconData icon) {
    return Row(
      children: [
        Icon(icon, size: 20, color: const Color(0xFF2563EB)),
        const SizedBox(width: 8),
        Text(
          title,
          style: const TextStyle(
            fontWeight: FontWeight.bold,
            fontSize: 13,
            letterSpacing: 1.1,
            color: Color(0xFF64748B),
          ),
        ),
      ],
    );
  }

  Widget _buildDeviceInfoCard(bool isDark) {
    final manufacturer = _deviceInfo?['manufacturer'] ?? 'Probing...';
    final model = _deviceInfo?['model'] ?? '';
    final version = _deviceInfo?['androidVersion'] ?? 'N/A';
    final sdk = _deviceInfo?['sdkInt'] ?? 'N/A';
    final patch = _deviceInfo?['securityPatch'] ?? 'N/A';
    final strongBox = _deviceInfo?['hasStrongBoxFeature'] == true ? 'Supported' : 'Not Supported';

    return Card(
      elevation: 0,
      color: isDark ? const Color(0xFF1E293B) : Colors.white,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: isDark ? const Color(0xFF334155) : const Color(0xFFE2E8F0)),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          children: [
            _buildInfoRow('Device', '$manufacturer $model'),
            const Divider(height: 16),
            _buildInfoRow('Android OS', 'Android $version (API $sdk)'),
            const Divider(height: 16),
            _buildInfoRow('Security Patch', patch.toString()),
            const Divider(height: 16),
            _buildInfoRow('StrongBox Feature', strongBox),
          ],
        ),
      ),
    );
  }

  Widget _buildInfoRow(String label, String value) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(label, style: const TextStyle(color: Color(0xFF64748B), fontSize: 13)),
        Text(value, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
      ],
    );
  }

  Widget _buildDecisionBanner() {
    Color bg;
    Color fg;
    String label;
    IconData icon;

    switch (_finalDecision) {
      case 'STRONGBOX_BACKED':
        bg = const Color(0xFFECFDF5);
        fg = const Color(0xFF059669);
        label = 'VERIFIED: STRONGBOX HARDWARE BACKED';
        icon = Icons.verified_user;
        break;
      case 'TEE_BACKED':
        bg = const Color(0xFFF0FDF4);
        fg = const Color(0xFF16A34A);
        label = 'VERIFIED: TEE (TRUSTZONE) HARDWARE BACKED';
        icon = Icons.security;
        break;
      case 'SOFTWARE_BACKED':
        bg = const Color(0xFFFEF3C7);
        fg = const Color(0xFFD97706);
        label = 'CAUTION: SOFTWARE SANDBOXED ONLY';
        icon = Icons.warning_amber;
        break;
      case 'FAILED':
        bg = const Color(0xFFFEF2F2);
        fg = const Color(0xFFDC2626);
        label = 'AUDIT FAILED';
        icon = Icons.error_outline;
        break;
      case 'RUNNING':
        bg = const Color(0xFFEFF6FF);
        fg = const Color(0xFF2563EB);
        label = 'RUNNING HARDWARE TESTS...';
        icon = Icons.hourglass_top;
        break;
      default:
        bg = const Color(0xFFF1F5F9);
        fg = const Color(0xFF475569);
        label = 'STATUS: NOT VERIFIED (TAP RUN AUDIT)';
        icon = Icons.info_outline;
        break;
    }

    return Container(
      padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 16),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: fg.withAlpha(77)),
      ),
      child: Row(
        children: [
          Icon(icon, color: fg, size: 24),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              label,
              style: TextStyle(
                color: fg,
                fontWeight: FontWeight.bold,
                fontSize: 13,
                letterSpacing: 0.5,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTestStepTile(_AuditTestStep step, bool isDark) {
    Color iconColor;
    IconData iconData;

    switch (step.status) {
      case _TestStatus.passed:
        iconColor = const Color(0xFF16A34A);
        iconData = Icons.check_circle;
        break;
      case _TestStatus.warning:
        iconColor = const Color(0xFFD97706);
        iconData = Icons.warning;
        break;
      case _TestStatus.failed:
        iconColor = const Color(0xFFDC2626);
        iconData = Icons.cancel;
        break;
    }

    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF1E293B) : Colors.white,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: isDark ? const Color(0xFF334155) : const Color(0xFFE2E8F0),
        ),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(iconData, color: iconColor, size: 20),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  step.name,
                  style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
                ),
                const SizedBox(height: 2),
                Text(
                  step.details,
                  style: TextStyle(
                    fontSize: 12,
                    color: isDark ? const Color(0xFF94A3B8) : const Color(0xFF64748B),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

enum _TestStatus { passed, warning, failed }

class _AuditTestStep {
  final String name;
  final _TestStatus status;
  final String details;

  _AuditTestStep({
    required this.name,
    required this.status,
    required this.details,
  });
}
