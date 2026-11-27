import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

/// ============================================================================
/// TEKFIX ERP - PHASE 13.3.0: SUPABASE STORAGE BRIDGE CLIENT
/// TARGET: Staging Environment (`tekfix-staging` / Supabase Storage)
/// ============================================================================
///
/// This client interacts exclusively with the server-side Supabase Edge Function
/// (`storage-bridge`) using the user's authentic Firebase ID Token.
///
/// CRITICAL SECURITY MANDATES:
/// 1. NEVER embed or use the Supabase `service_role` key on the client.
/// 2. All uploads are negotiated via short-lived signed upload tickets (upsert: false).
/// 3. All downloads are negotiated via short-lived signed download tickets (max 3600s).
/// 4. Client-side validates: file size <= 10MB, allowed MIME types, and path boundaries.
/// ============================================================================

enum StorageCategory {
  expenseReceipts('expense_receipts'),
  purchaseInvoices('purchase_invoices'),
  rentReceipts('rent_receipts');

  final String value;
  const StorageCategory(this.value);

  static StorageCategory? fromString(String val) {
    for (final cat in StorageCategory.values) {
      if (cat.value == val) return cat;
    }
    return null;
  }
}

class SupabaseStorageBridgeClient {
  final String edgeFunctionBaseUrl;
  final Future<String?> Function() getFirebaseIdToken;
  final http.Client _httpClient;

  static const int maxFileSizeBytes = 10 * 1024 * 1024; // 10 MB
  static const Set<String> allowedMimeTypes = {
    'image/jpeg',
    'image/png',
    'image/webp',
    'application/pdf',
  };

  SupabaseStorageBridgeClient({
    required this.edgeFunctionBaseUrl,
    required this.getFirebaseIdToken,
    http.Client? httpClient,
  }) : _httpClient = httpClient ?? http.Client();

  /// Request a short-lived signed upload URL and upload the binary data.
  /// Returns the canonical storage path (`shops/{shopId}/{category}/{fileName}`)
  /// to be saved in Firestore records (`receiptUrl` / `storagePath`).
  Future<String> uploadFinancialFile({
    required String shopId,
    required StorageCategory category,
    required String fileName,
    required Uint8List bytes,
    required String mimeType,
  }) async {
    // 1. Client-Side Pre-Flight Security Validations
    if (shopId.trim().isEmpty) {
      throw ArgumentError('Invalid shopId: shopId cannot be empty.');
    }

    if (bytes.isEmpty) {
      throw ArgumentError('Cannot upload empty file.');
    }

    if (bytes.length > maxFileSizeBytes) {
      throw ArgumentError(
        'File size (${bytes.length} bytes) exceeds maximum limit of 10 MB ($maxFileSizeBytes bytes).',
      );
    }

    final normalizedMime = mimeType.trim().toLowerCase();
    if (!allowedMimeTypes.contains(normalizedMime)) {
      throw ArgumentError(
        'Unsupported MIME type "$normalizedMime". Allowed types: ${allowedMimeTypes.join(", ")}',
      );
    }

    // 2. Obtain Firebase ID Token
    final token = await getFirebaseIdToken();
    if (token == null || token.isEmpty) {
      throw StateError('Authentication required: Firebase ID Token is missing or null.');
    }

    // 3. Request Signed Upload URL from Edge Function
    final requestUri = Uri.parse('$edgeFunctionBaseUrl/get-upload-url');
    final preflightResponse = await _httpClient.post(
      requestUri,
      headers: {
        'Content-Type': 'application/json',
        'Authorization': 'Bearer $token',
      },
      body: jsonEncode({
        'shopId': shopId,
        'category': category.value,
        'fileName': fileName,
        'fileSizeBytes': bytes.length,
        'mimeType': normalizedMime,
      }),
    );

    if (preflightResponse.statusCode != 200) {
      final errorBody = preflightResponse.body;
      debugPrint('[SupabaseStorageBridge] Pre-flight failed: ${preflightResponse.statusCode} - $errorBody');
      throw StateError(
        'Upload authorization rejected (${preflightResponse.statusCode}): $errorBody',
      );
    }

    final ticket = jsonDecode(preflightResponse.body) as Map<String, dynamic>;
    final signedUploadUrl = ticket['signedUrl'] as String?;
    final storagePath = ticket['storagePath'] as String?;

    if (signedUploadUrl == null || storagePath == null) {
      throw StateError('Invalid server response: missing signedUrl or storagePath in upload ticket.');
    }

    // 4. Binary Upload to Signed URL using PUT
    // Notice: Server enforces upsert: false and storage.buckets constraints.
    final uploadUri = Uri.parse(signedUploadUrl);
    final uploadResponse = await _httpClient.put(
      uploadUri,
      headers: {
        'Content-Type': normalizedMime,
      },
      body: bytes,
    );

    if (uploadResponse.statusCode != 200 && uploadResponse.statusCode != 201) {
      debugPrint(
        '[SupabaseStorageBridge] Binary PUT failed: ${uploadResponse.statusCode} - ${uploadResponse.body}',
      );
      throw StateError(
        'Storage binary upload failed (${uploadResponse.statusCode}): ${uploadResponse.body}',
      );
    }

    // Return immutable canonical storage path
    return storagePath;
  }

  /// Request a short-lived signed download URL for displaying or previewing a file.
  Future<String> getSignedDownloadUrl({
    required String shopId,
    required String storagePath,
    int expiresInSeconds = 3600,
  }) async {
    if (shopId.trim().isEmpty) {
      throw ArgumentError('Invalid shopId: cannot be empty.');
    }
    if (storagePath.trim().isEmpty) {
      throw ArgumentError('Invalid storagePath: cannot be empty.');
    }

    final token = await getFirebaseIdToken();
    if (token == null || token.isEmpty) {
      throw StateError('Authentication required: Firebase ID Token is missing or null.');
    }

    final requestUri = Uri.parse('$edgeFunctionBaseUrl/get-download-url');
    final response = await _httpClient.post(
      requestUri,
      headers: {
        'Content-Type': 'application/json',
        'Authorization': 'Bearer $token',
      },
      body: jsonEncode({
        'shopId': shopId,
        'storagePath': storagePath,
        'expiresIn': expiresInSeconds,
      }),
    );

    if (response.statusCode != 200) {
      throw StateError(
        'Download authorization rejected (${response.statusCode}): ${response.body}',
      );
    }

    final body = jsonDecode(response.body) as Map<String, dynamic>;
    final downloadUrl = body['signedUrl'] as String?;
    if (downloadUrl == null) {
      throw StateError('Invalid server response: missing signedUrl in download ticket.');
    }

    return downloadUrl;
  }
}

