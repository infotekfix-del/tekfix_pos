import 'package:flutter/foundation.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'supabase_storage_bridge_client.dart';

/// ============================================================================
/// TEKFIX ERP - PHASE 13.3.0: UNIFIED STORAGE BRIDGE
/// ============================================================================
///
/// Encapsulates environment routing between:
/// 1. PRODUCTION (`tekfix-45b38`): Native Firebase Storage SDK (`gs://` & GCS).
/// 2. STAGING (`tekfix-staging`): Supabase Storage Bridge (`financial-records`).
///
/// Supports dual-scheme resolution so legacy Firebase Storage URLs and new
/// Supabase paths coexist seamlessly without broken image links or regressions.
/// ============================================================================

enum StorageEnvironment {
  production,
  staging,
  localMock,
}

class StorageBridge {
  static StorageEnvironment _environment = StorageEnvironment.production;
  static SupabaseStorageBridgeClient? _supabaseClient;
  static bool _initialized = false;

  /// Current configured environment
  static StorageEnvironment get environment => _environment;
  static bool get isStaging => _environment == StorageEnvironment.staging;
  static bool get isProduction => _environment == StorageEnvironment.production;
  static bool get isInitialized => _initialized;

  /// Configure the global Storage Bridge
  static void configure({
    required StorageEnvironment environment,
    SupabaseStorageBridgeClient? supabaseClient,
  }) {
    _environment = environment;
    _supabaseClient = supabaseClient;
    _initialized = true;
    debugPrint('[StorageBridge] Configured for environment: ${_environment.name}');
  }

  /// Reset to default production state (for testing or tear down)
  @visibleForTesting
  static void reset() {
    _environment = StorageEnvironment.production;
    _supabaseClient = null;
    _initialized = false;
  }

  /// Upload a financial attachment (expense receipt, purchase bill, rent receipt).
  ///
  /// In Production: Routes to Firebase Storage.
  /// In Staging: Routes to Supabase Storage Bridge.
  static Future<String> uploadFinancialDocument({
    required String shopId,
    required StorageCategory category,
    required String documentId,
    required String originalFileName,
    required Uint8List bytes,
    required String mimeType,
  }) async {
    final cleanName = originalFileName.replaceAll(RegExp(r'[^a-zA-Z0-9._-]'), '_');

    // 1. STAGING ROUTE -> Supabase Storage Bridge
    if (_environment == StorageEnvironment.staging) {
      if (_supabaseClient == null) {
        throw StateError(
          '[StorageBridge] Staging environment requires an initialized SupabaseStorageBridgeClient.',
        );
      }

      final canonicalPath = await _supabaseClient!.uploadFinancialFile(
        shopId: shopId,
        category: category,
        fileName: '${documentId}_$cleanName',
        bytes: bytes,
        mimeType: mimeType,
      );

      return canonicalPath;
    }

    // 2. PRODUCTION ROUTE -> Native Firebase Storage SDK
    // (Untouched, exact existing behavior)
    final ref = FirebaseStorage.instance
        .ref()
        .child('shops/$shopId/${category.value}/${documentId}_$cleanName');

    final task = await ref.putData(
      bytes,
      SettableMetadata(contentType: mimeType),
    );

    return await task.ref.getDownloadURL();
  }

  /// Resolve a viewable/downloadable URL from either a legacy Firebase URL
  /// or a Supabase storage path.
  static Future<String> resolveDownloadUrl({
    required String shopId,
    required String rawUrlOrPath,
    int expiresInSeconds = 3600,
  }) async {
    if (rawUrlOrPath.trim().isEmpty) return '';

    // Legacy Firebase URLs or public HTTPS URLs
    if (rawUrlOrPath.startsWith('http://') ||
        rawUrlOrPath.startsWith('https://firebasestorage.googleapis.com') ||
        rawUrlOrPath.startsWith('gs://')) {
      // Direct pass-through for legacy Firebase URLs
      return rawUrlOrPath;
    }

    // Staging / Supabase path resolution (e.g. "shops/tekfix/expense_receipts/...")
    if (_environment == StorageEnvironment.staging && _supabaseClient != null) {
      return await _supabaseClient!.getSignedDownloadUrl(
        shopId: shopId,
        storagePath: rawUrlOrPath,
        expiresInSeconds: expiresInSeconds,
      );
    }

    // Fallback: If in production or mock, return raw path
    return rawUrlOrPath;
  }
}

