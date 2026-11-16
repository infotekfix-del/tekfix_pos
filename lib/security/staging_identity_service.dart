import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:hive/hive.dart';
import 'package:http/http.dart' as http;
import '../auth/auth_controller.dart';
import '../main.dart' show Db;
import 'device_security_service.dart';

/// ============================================================================
/// TEKFIX ERP - PHASE 15.2.4: SERVER-AUTHORITATIVE STAGING IDENTITY SERVICE
/// ============================================================================
/// 
/// Retrieves short-lived Option A synthetic identity tokens from the isolated
/// staging backend over HTTPS.
/// 
/// STRICT PRODUCTION & SECRET ISOLATION:
/// - ZERO HMAC/JWT signing secrets embedded in client code or binaries.
/// - Signing authority remains 100% server-side in the Supabase Edge Function.
/// - 0 Network calls to Firebase Auth or Google JWKS.
/// - Tokens are short-lived (1 hour TTL) and cached in-memory with auto-refresh.
/// ============================================================================

class StagingIdentityService {
  StagingIdentityService._();

  /// Authorized Staging Shop ID (Whitelisted in Edge Function)
  static const String defaultShopId = 'shop_staging_001';

  /// Authorized Staging Owner UID (Whitelisted in Edge Function)
  static const String defaultOwnerUid = 'owner_staging_001';

  // In-memory token cache (never persisted to plaintext disk)
  static String? _cachedToken;
  static DateTime? _cachedExpiresAt;
  static http.Client? _customHttpClient;

  @visibleForTesting
  static void setMockHttpClient(http.Client? client) {
    _customHttpClient = client;
  }

  @visibleForTesting
  static void resetCache() {
    _cachedToken = null;
    _cachedExpiresAt = null;
  }

  /// Whether a valid unexpired token is currently cached.
  static bool get hasValidCachedToken {
    if (_cachedToken == null || _cachedExpiresAt == null) return false;
    return _cachedExpiresAt!.isAfter(DateTime.now().add(const Duration(seconds: 30)));
  }

  /// Helper to safely resolve active shop ID from active Owner session or Hive
  static String _resolveShopId(String? explicitShopId) {
    if (explicitShopId != null && explicitShopId.trim().isNotEmpty) {
      return explicitShopId.trim();
    }
    try {
      final authShopId = AuthController.instance.shopId.trim();
      if (authShopId.isNotEmpty) return authShopId;
    } catch (_) {}
    try {
      if (Hive.isBoxOpen('tek_settings')) {
        final stored = Db.setting('shop_id', '').trim();
        if (stored.isNotEmpty) return stored;
      }
    } catch (_) {}
    return defaultShopId;
  }

  /// Helper to safely resolve active owner UID from active Owner session or Hive
  static String _resolveOwnerUid(String? explicitOwnerUid) {
    if (explicitOwnerUid != null && explicitOwnerUid.trim().isNotEmpty) {
      return explicitOwnerUid.trim();
    }
    try {
      final authUid = AuthController.instance.uid.trim();
      if (authUid.isNotEmpty) return authUid;
    } catch (_) {}
    try {
      if (Hive.isBoxOpen('tek_settings')) {
        final stored = Db.setting('staff_logged_id', '').trim();
        if (stored.isNotEmpty) return stored;
      }
    } catch (_) {}
    return defaultOwnerUid;
  }

  /// Helper to safely resolve active registered device ID
  static String _resolveDeviceId(String? explicitDeviceId) {
    if (explicitDeviceId != null && explicitDeviceId.trim().isNotEmpty) {
      return explicitDeviceId.trim();
    }
    try {
      final devId = DeviceSecurityService.instance.deviceId.trim();
      if (devId.isNotEmpty) return devId;
    } catch (_) {}
    return '';
  }

  /// Obtains a short-lived Option A staging token from the staging Edge Function.
  /// 
  /// 1. Enforces owner-only authentication (strictly rejects staff sessions).
  /// 2. Checks in-memory cache first (with 30s safety margin).
  /// 3. Resolves shopId, ownerUid, and deviceId dynamically from the active session.
  /// 4. Generates a fresh nonce challenge and authentic ECDSA P-256 hardware signature.
  /// 5. Validates all 5 mandatory parameters before POSTing to /issue-staging-token.
  /// 6. Returns the valid JWT for use in Authorization: Bearer headers.
  static Future<String> getOptionAToken({
    required String edgeFunctionBaseUrl,
    String? shopId,
    String? ownerUid,
    String? deviceId,
    String? nonce,
    String? deviceSignature,
  }) async {
    // 1. Staff isolation check: staff sessions must NEVER obtain owner staging tokens
    try {
      if (AuthController.instance.isStaffLoggedIn) {
        throw StateError('Staff access denied: Recharge Accounting token issuance requires an authenticated Owner session.');
      }
    } catch (e) {
      if (e is StateError) rethrow;
    }

    // 2. In-memory cache hit check
    if (hasValidCachedToken) {
      return _cachedToken!;
    }

    // 3. Dynamic parameter resolution
    final effectiveShopId = _resolveShopId(shopId);
    final effectiveOwnerUid = _resolveOwnerUid(ownerUid);
    final effectiveDeviceId = _resolveDeviceId(deviceId);

    if (effectiveDeviceId.isEmpty) {
      throw StateError('[StagingIdentityService] Device ID is uninitialized or empty.');
    }

    final client = _customHttpClient ?? http.Client();
    String effectiveNonce = (nonce != null && nonce.trim().isNotEmpty) ? nonce.trim() : '';
    String effectiveSignature = (deviceSignature != null && deviceSignature.trim().isNotEmpty) ? deviceSignature.trim() : '';

    // 4. Request fresh challenge nonce and sign with hardware key if not supplied
    if (effectiveNonce.isEmpty || effectiveSignature.isEmpty) {
      final challengeUrl = Uri.parse('$edgeFunctionBaseUrl/request-challenge');
      final challengeRes = await client.post(
        challengeUrl,
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'shopId': effectiveShopId,
          'ownerUid': effectiveOwnerUid,
          'deviceId': effectiveDeviceId,
        }),
      );

      if (challengeRes.statusCode < 200 || challengeRes.statusCode >= 300) {
        String errMsg = 'HTTP ${challengeRes.statusCode}';
        try {
          final errData = jsonDecode(challengeRes.body);
          if (errData is Map && errData['error'] != null) {
            errMsg = errData['error'].toString();
          }
        } catch (_) {
          errMsg = challengeRes.body.isNotEmpty ? challengeRes.body : errMsg;
        }
        throw StateError(
          '[StagingIdentityService] Challenge request failed (${challengeRes.statusCode}): $errMsg',
        );
      }

      final cData = jsonDecode(challengeRes.body) as Map<String, dynamic>;
      effectiveNonce = cData['nonce']?.toString().trim() ?? '';
      if (effectiveNonce.isEmpty) {
        throw StateError('[StagingIdentityService] Server response missing challenge nonce.');
      }

      final canonicalPayload = 'ISSUE_STAGING_TOKEN:$effectiveShopId:$effectiveOwnerUid:$effectiveDeviceId:$effectiveNonce';
      effectiveSignature = (await DeviceSecurityService.instance.signRawPayload(canonicalPayload)).trim();
      if (effectiveSignature.isEmpty) {
        throw StateError('[StagingIdentityService] Device signature generation returned empty signature.');
      }
    }

    // 5. Assert all 5 mandatory parameters are present and non-empty
    if (effectiveShopId.isEmpty ||
        effectiveOwnerUid.isEmpty ||
        effectiveDeviceId.isEmpty ||
        effectiveNonce.isEmpty ||
        effectiveSignature.isEmpty) {
      throw StateError(
        '[StagingIdentityService] Missing mandatory parameters: shopId, ownerUid, deviceId, nonce, and deviceSignature are all required.',
      );
    }

    // 6. Request token from /issue-staging-token
    final url = Uri.parse('$edgeFunctionBaseUrl/issue-staging-token');
    final response = await client.post(
      url,
      headers: {
        'Content-Type': 'application/json',
      },
      body: jsonEncode({
        'shopId': effectiveShopId,
        'ownerUid': effectiveOwnerUid,
        'deviceId': effectiveDeviceId,
        'nonce': effectiveNonce,
        'deviceSignature': effectiveSignature,
      }),
    );

    if (response.statusCode >= 200 && response.statusCode < 300) {
      final data = jsonDecode(response.body) as Map<String, dynamic>;
      final token = data['token'] as String?;
      final expiresAtStr = data['expiresAt'] as String?;

      if (token == null || token.isEmpty) {
        throw StateError('[StagingIdentityService] Server response missing token.');
      }

      _cachedToken = token;
      _cachedExpiresAt = expiresAtStr != null
          ? DateTime.tryParse(expiresAtStr)
          : DateTime.now().add(const Duration(minutes: 55));

      return token;
    }

    String errorBody = response.body;
    try {
      final errData = jsonDecode(response.body);
      if (errData is Map && errData['error'] != null) {
        errorBody = errData['error'].toString();
      }
    } catch (_) {}

    throw StateError(
      '[StagingIdentityService] Staging token issuance failed (${response.statusCode}): $errorBody',
    );
  }
}
