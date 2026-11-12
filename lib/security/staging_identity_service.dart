import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
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

  /// Obtains a short-lived Option A staging token from the staging Edge Function.
  /// 
  /// 1. Checks in-memory cache first (with 30s safety margin).
  /// 2. If missing or nearing expiry, requests a new token from /issue-staging-token over HTTPS.
  /// 3. Returns the valid JWT for use in Authorization: Bearer headers.
  static Future<String> getOptionAToken({
    required String edgeFunctionBaseUrl,
    String? shopId,
    String? ownerUid,
    String? deviceId,
    String? nonce,
    String? deviceSignature,
  }) async {
    final effectiveShopId = shopId ?? defaultShopId;
    final effectiveOwnerUid = ownerUid ?? defaultOwnerUid;

    if (hasValidCachedToken) {
      return _cachedToken!;
    }

    final client = _customHttpClient ?? http.Client();
    final effectiveDeviceId = deviceId ?? DeviceSecurityService.instance.deviceId;
    String effectiveNonce = nonce ?? '';
    String effectiveSignature = deviceSignature ?? '';

    // If nonce or signature not explicitly provided, request challenge and sign with hardware key
    if (effectiveNonce.isEmpty || effectiveSignature.isEmpty) {
      try {
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
        if (challengeRes.statusCode >= 200 && challengeRes.statusCode < 300) {
          final cData = jsonDecode(challengeRes.body) as Map<String, dynamic>;
          effectiveNonce = cData['nonce']?.toString() ?? '';
          if (effectiveNonce.isNotEmpty) {
            final canonicalPayload = 'ISSUE_STAGING_TOKEN:$effectiveShopId:$effectiveOwnerUid:$effectiveDeviceId:$effectiveNonce';
            effectiveSignature = await DeviceSecurityService.instance.signRawPayload(canonicalPayload);
          }
        }
      } catch (e) {
        debugPrint('[StagingIdentityService] Challenge request notice: $e');
      }
    }

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

    final errorBody = response.body;
    throw StateError(
      '[StagingIdentityService] Staging token issuance failed (${response.statusCode}): $errorBody',
    );
  }
}
