import 'dart:convert';
import 'package:http/http.dart' as http;

/// ============================================================================
/// TEKFIX ERP - PHASE 14.9.2: SECURE SUPABASE RECHARGE BRIDGE CLIENT
/// ZERO-COST BACKEND CLIENT FOR RECHARGE ACCOUNTING & TRUSTED DEVICES
/// ============================================================================
///
/// Communicates securely with the server-side Supabase Edge Function
/// (`recharge-bridge`) using authentic Firebase ID Tokens and hardware-bound
/// ECDSA P-256 signatures for EVERY financial operation.
/// ============================================================================

class SupabaseRechargeBridgeClient {
  final String edgeFunctionBaseUrl;
  final Future<String?> Function() getFirebaseIdToken;
  final http.Client _httpClient;

  SupabaseRechargeBridgeClient({
    required this.edgeFunctionBaseUrl,
    required this.getFirebaseIdToken,
    http.Client? httpClient,
  }) : _httpClient = httpClient ?? http.Client();

  /// Helper to send authenticated POST requests to the Edge Function
  Future<Map<String, dynamic>> _post(String endpoint, Map<String, dynamic> body) async {
    final token = await getFirebaseIdToken();
    if (token == null || token.trim().isEmpty) {
      throw StateError('[SupabaseRechargeBridgeClient] Authentication required: Missing Firebase ID Token.');
    }

    final url = Uri.parse('$edgeFunctionBaseUrl/$endpoint');
    final response = await _httpClient.post(
      url,
      headers: {
        'Content-Type': 'application/json',
        'Authorization': 'Bearer $token',
      },
      body: jsonEncode(body),
    );

    Map<String, dynamic> responseData = {};
    try {
      if (response.body.isNotEmpty) {
        responseData = jsonDecode(response.body) as Map<String, dynamic>;
      }
    } catch (_) {}

    if (response.statusCode >= 200 && response.statusCode < 300) {
      return responseData;
    }

    final errorMessage = responseData['error']?.toString() ??
        'HTTP ${response.statusCode}: ${response.reasonPhrase}';

    if (response.statusCode == 401) {
      throw StateError('Unauthenticated: $errorMessage');
    }
    if (response.statusCode == 403) {
      throw StateError('Permission Denied: $errorMessage');
    }
    if (response.statusCode == 400) {
      throw ArgumentError('Invalid Request: $errorMessage');
    }

    throw Exception('Server Error ($errorMessage)');
  }

  /// Request a short-lived challenge nonce (300s TTL) for device signing
  Future<({String nonce, String expiresAt})> requestChallenge({
    required String shopId,
    required String deviceId,
    String? ownerUid,
  }) async {
    final payload = <String, dynamic>{
      'shopId': shopId,
      'deviceId': deviceId,
    };
    if (ownerUid != null && ownerUid.isNotEmpty) {
      payload['ownerUid'] = ownerUid;
    }
    final res = await _post('request-challenge', payload);

    final nonce = res['nonce']?.toString() ?? '';
    final expiresAt = res['expiresAt']?.toString() ?? '';

    if (nonce.isEmpty) {
      throw StateError('Malformed server response: Missing challenge nonce.');
    }

    return (nonce: nonce, expiresAt: expiresAt);
  }

  /// Register an owner's trusted device (mobile or laptop) with cross-signing for 2nd device
  Future<Map<String, dynamic>> registerDevice({
    required String shopId,
    required String deviceId,
    required String deviceType,
    required String platform,
    required String deviceModel,
    required String publicKeyPem,
    String? authorizingDeviceId,
    String? authorizingSignature,
    String? nonce,
  }) async {
    return await _post('register-device', {
      'shopId': shopId,
      'deviceId': deviceId,
      'deviceType': deviceType,
      'platform': platform,
      'deviceModel': deviceModel,
      'publicKeyPem': publicKeyPem,
      if (authorizingDeviceId != null) 'authorizingDeviceId': authorizingDeviceId,
      if (authorizingSignature != null) 'authorizingSignature': authorizingSignature,
      if (nonce != null) 'nonce': nonce,
    });
  }

  /// Revoke a registered trusted device
  Future<Map<String, dynamic>> revokeDevice({
    required String shopId,
    required String deviceId,
    String reason = 'Revoked by owner',
  }) async {
    return await _post('revoke-device', {
      'shopId': shopId,
      'deviceId': deviceId,
      'reason': reason,
    });
  }

  /// Process an atomic recharge wallet debit with cryptographic device signature
  Future<Map<String, dynamic>> processDebit({
    required String shopId,
    required String walletId,
    required String rechargeId,
    required String idempotencyKey,
    required String operator,
    required int amountPaise,
    required num amount,
    required String fundingType,
    required String businessDate,
    required String deviceId,
    required String deviceSignature,
    required String nonce,
    String? customerPhone,
    String? serviceType,
    int commissionEarnedPaise = 0,
    String? notes,
    Map<String, dynamic>? rechargeData,
    String? paymentMode,
    int? retailAmountPaise,
    int? costPricePaise,
    dynamic partyKey,
    String? partyName,
  }) async {
    if (amountPaise <= 0) {
      throw ArgumentError('amountPaise must be a strictly positive integer.');
    }

    return await _post('process-debit', {
      'shopId': shopId,
      'walletId': walletId,
      'rechargeId': rechargeId,
      'idempotencyKey': idempotencyKey,
      'customerPhone': customerPhone ?? 'RECHARGE_COUNTER',
      'operator': operator,
      'serviceType': serviceType ?? 'mobile_recharge',
      'amountPaise': amountPaise,
      'amount': amount,
      'fundingType': fundingType,
      'commissionEarnedPaise': commissionEarnedPaise,
      'businessDate': businessDate,
      'deviceId': deviceId,
      'deviceSignature': deviceSignature,
      'nonce': nonce,
      'notes': notes,
      if (paymentMode != null) 'paymentMode': paymentMode,
      if (retailAmountPaise != null) 'retailAmountPaise': retailAmountPaise,
      if (costPricePaise != null) 'costPricePaise': costPricePaise,
      if (partyKey != null) 'partyKey': partyKey.toString(),
      if (partyName != null) 'partyName': partyName,
      if (rechargeData != null) 'rechargeData': rechargeData,
    });
  }

  /// Process top-up / float deposit with mandatory hardware signature
  Future<Map<String, dynamic>> processTopup({
    required String shopId,
    required String walletId,
    required int amountPaise,
    required String deviceId,
    required String deviceSignature,
    required String nonce,
    String source = 'bank',
    String? staffId,
    String? staffName,
    String? referenceId,
    String? description,
  }) async {
    return await _post('process-topup', {
      'shopId': shopId,
      'walletId': walletId,
      'amountPaise': amountPaise,
      'source': source,
      'staffId': staffId,
      'staffName': staffName,
      'referenceId': referenceId,
      'description': description,
      'deviceId': deviceId,
      'deviceSignature': deviceSignature,
      'nonce': nonce,
    });
  }

  /// Process distributor load with mandatory hardware signature
  Future<Map<String, dynamic>> processDistributorLoad({
    required String shopId,
    required String walletId,
    required String distributorId,
    required int amountPaise,
    required String deviceId,
    required String deviceSignature,
    required String nonce,
    String? staffId,
    String? staffName,
    String? notes,
  }) async {
    return await _post('process-distributor-load', {
      'shopId': shopId,
      'walletId': walletId,
      'distributorId': distributorId,
      'amountPaise': amountPaise,
      'staffId': staffId,
      'staffName': staffName,
      'notes': notes,
      'deviceId': deviceId,
      'deviceSignature': deviceSignature,
      'nonce': nonce,
    });
  }

  /// Process distributor settlement payment with mandatory hardware signature
  Future<Map<String, dynamic>> processDistributorSettlement({
    required String shopId,
    required String distributorId,
    required String walletId,
    required int amountPaise,
    required String deviceId,
    required String deviceSignature,
    required String nonce,
    String paymentMode = 'cash',
    String? staffId,
    String? referenceId,
    String? notes,
  }) async {
    return await _post('process-distributor-settlement', {
      'shopId': shopId,
      'distributorId': distributorId,
      'walletId': walletId,
      'amountPaise': amountPaise,
      'paymentMode': paymentMode,
      'staffId': staffId,
      'referenceId': referenceId,
      'notes': notes,
      'deviceId': deviceId,
      'deviceSignature': deviceSignature,
      'nonce': nonce,
    });
  }

  /// Process customer refund with mandatory hardware signature
  Future<Map<String, dynamic>> processRefund({
    required String shopId,
    required String txnKey,
    required String reason,
    required String deviceId,
    required String deviceSignature,
    required String nonce,
    String refundMode = 'cash',
    String? staffId,
  }) async {
    return await _post('process-refund', {
      'shopId': shopId,
      'txnKey': txnKey,
      'refundMode': refundMode,
      'reason': reason,
      'staffId': staffId,
      'deviceId': deviceId,
      'deviceSignature': deviceSignature,
      'nonce': nonce,
    });
  }

  /// Process operator reversal with mandatory hardware signature
  Future<Map<String, dynamic>> processReversal({
    required String shopId,
    required String txnKey,
    required String reason,
    required String deviceId,
    required String deviceSignature,
    required String nonce,
    String? operatorReference,
    String? staffId,
  }) async {
    return await _post('process-reversal', {
      'shopId': shopId,
      'txnKey': txnKey,
      'operatorReference': operatorReference,
      'reason': reason,
      'staffId': staffId,
      'deviceId': deviceId,
      'deviceSignature': deviceSignature,
      'nonce': nonce,
    });
  }

  /// Process end-of-day daily reconciliation with mandatory hardware signature
  Future<Map<String, dynamic>> processDailyReconciliation({
    required String shopId,
    required String businessDate,
    required int actualPhysicalBalancePaise,
    required String deviceId,
    required String deviceSignature,
    required String nonce,
    String? reconciledBy,
  }) async {
    return await _post('process-reconciliation', {
      'shopId': shopId,
      'businessDate': businessDate,
      'actualPhysicalBalancePaise': actualPhysicalBalancePaise,
      'reconciledBy': reconciledBy,
      'deviceId': deviceId,
      'deviceSignature': deviceSignature,
      'nonce': nonce,
    });
  }

  /// Fetch wallet from PostgreSQL (Read-Only)
  Future<Map<String, dynamic>?> getWallet({
    required String shopId,
    required String walletId,
  }) async {
    final res = await _post('get-wallet', {
      'shopId': shopId,
      'walletId': walletId,
    });
    return res['wallet'] as Map<String, dynamic>?;
  }

  /// Fetch distributor from PostgreSQL (Read-Only)
  Future<Map<String, dynamic>?> getDistributor({
    required String shopId,
    required String distributorId,
  }) async {
    final res = await _post('get-distributor', {
      'shopId': shopId,
      'distributorId': distributorId,
    });
    return res['distributor'] as Map<String, dynamic>?;
  }

  /// Fetch trusted devices from PostgreSQL (Read-Only Owner Authenticated)
  Future<List<Map<String, dynamic>>> getDevices({
    required String shopId,
  }) async {
    final res = await _post('get-devices', {
      'shopId': shopId,
    });
    final list = res['devices'] as List<dynamic>?;
    if (list == null) return [];
    return list.cast<Map<String, dynamic>>();
  }
}
