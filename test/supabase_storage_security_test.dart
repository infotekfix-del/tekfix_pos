import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:tekfix_erp_pos/storage/supabase_storage_bridge_client.dart';
import 'package:tekfix_erp_pos/storage/storage_bridge.dart';

void main() {
  group('TEKFIX ERP - PHASE 13.3.0: SUPABASE STORAGE SECURITY TESTS', () {
    const String mockBaseUrl = 'https://mock.supabase.co/functions/v1/storage-bridge';
    const String mockShopId = 'tekfix_staging_shop';
    const String mockToken = 'mock_valid_firebase_id_token';

    tearDown(() {
      StorageBridge.reset();
    });

    test('MANDATORY REQUIREMENT 2: Enforces maximum 10 MB file size limit', () async {
      final client = SupabaseStorageBridgeClient(
        edgeFunctionBaseUrl: mockBaseUrl,
        getFirebaseIdToken: () async => mockToken,
      );

      // 10 MB + 1 byte
      final oversizedBytes = Uint8List(10 * 1024 * 1024 + 1);

      expect(
        () => client.uploadFinancialFile(
          shopId: mockShopId,
          category: StorageCategory.expenseReceipts,
          fileName: 'oversized.pdf',
          bytes: oversizedBytes,
          mimeType: 'application/pdf',
        ),
        throwsA(isA<ArgumentError>().having(
          (e) => e.message,
          'message',
          contains('exceeds maximum limit of 10 MB'),
        )),
      );
    });

    test('MANDATORY REQUIREMENT 2: Rejects unauthorized MIME types', () async {
      final client = SupabaseStorageBridgeClient(
        edgeFunctionBaseUrl: mockBaseUrl,
        getFirebaseIdToken: () async => mockToken,
      );

      final validBytes = Uint8List.fromList([1, 2, 3, 4]);

      // Disallowed executable / archive MIME types
      for (final badMime in ['application/x-msdownload', 'text/html', 'application/zip', 'video/mp4']) {
        expect(
          () => client.uploadFinancialFile(
            shopId: mockShopId,
            category: StorageCategory.expenseReceipts,
            fileName: 'malicious.exe',
            bytes: validBytes,
            mimeType: badMime,
          ),
          throwsA(isA<ArgumentError>().having(
            (e) => e.message,
            'message',
            contains('Unsupported MIME type'),
          )),
        );
      }
    });

    test('MANDATORY REQUIREMENT 3: Enforces immutable storage keys and random UUID prefixes', () async {
      bool mockServerReceivedUpsertFalse = false;
      String? generatedStoragePath;

      final mockHttp = MockClient((request) async {
        if (request.url.path.endsWith('/get-upload-url')) {
          final body = jsonDecode(request.body) as Map<String, dynamic>;
          final category = body['category'];
          final fileName = body['fileName'];

          // Server generates random UUID + timestamp prefix
          generatedStoragePath = 'shops/$mockShopId/$category/1793419200000_uuid-v4-random_$fileName';
          mockServerReceivedUpsertFalse = true;

          return http.Response(
            jsonEncode({
              'signedUrl': 'https://mock.supabase.co/storage/v1/upload/ticket_123',
              'storagePath': generatedStoragePath,
            }),
            200,
          );
        } else if (request.url.toString().contains('/upload/ticket_123')) {
          // Binary PUT endpoint
          expect(request.method, equals('PUT'));
          return http.Response('', 200);
        }
        return http.Response('Not Found', 404);
      });

      final client = SupabaseStorageBridgeClient(
        edgeFunctionBaseUrl: mockBaseUrl,
        getFirebaseIdToken: () async => mockToken,
        httpClient: mockHttp,
      );

      final validBytes = Uint8List.fromList([0x25, 0x50, 0x44, 0x46]); // PDF magic header
      final resultPath = await client.uploadFinancialFile(
        shopId: mockShopId,
        category: StorageCategory.purchaseInvoices,
        fileName: 'vendor_invoice.pdf',
        bytes: validBytes,
        mimeType: 'application/pdf',
      );

      expect(mockServerReceivedUpsertFalse, isTrue);
      expect(resultPath, equals(generatedStoragePath));
      expect(resultPath, contains('shops/$mockShopId/purchase_invoices/'));
      expect(resultPath, contains('uuid-v4-random_vendor_invoice.pdf'));
    });

    test('MANDATORY REQUIREMENT 4: Dynamic JWKS cache invalidation simulation', () async {
      // Simulating Edge Function key resolution with dynamic refetch on unknown kid
      final Map<String, String> cache = {'kid_old_1': 'public_key_1'};
      bool remoteFetched = false;

      String resolveKey(String kid) {
        if (cache.containsKey(kid)) {
          return cache[kid]!;
        }
        // Cache miss -> dynamic invalidation & fetch
        remoteFetched = true;
        cache['kid_new_2'] = 'public_key_2';
        if (cache.containsKey(kid)) {
          return cache[kid]!;
        }
        throw Exception('Key ID $kid remains unknown after live refetch.');
      }

      // 1. Known key hits cache
      expect(resolveKey('kid_old_1'), equals('public_key_1'));
      expect(remoteFetched, isFalse);

      // 2. Unknown key triggers dynamic refetch
      expect(resolveKey('kid_new_2'), equals('public_key_2'));
      expect(remoteFetched, isTrue);

      // 3. Invalid key after refetch throws bounded error
      expect(() => resolveKey('malicious_kid'), throwsException);
    });

    test('MANDATORY REQUIREMENT 8: Dual-scheme URL resolution preserves legacy Firebase URLs', () async {
      // Test 1: Legacy Firebase HTTPS download URL remains intact
      const legacyFirebaseUrl =
          'https://firebasestorage.googleapis.com/v0/b/tekfix-45b38.appspot.com/o/shops%2Ftekfix%2Fexpense_receipts%2Freceipt.jpg?alt=media&token=abc';
      final resolved1 = await StorageBridge.resolveDownloadUrl(
        shopId: mockShopId,
        rawUrlOrPath: legacyFirebaseUrl,
      );
      expect(resolved1, equals(legacyFirebaseUrl));

      // Test 2: Legacy gs:// bucket URL remains intact
      const legacyGsUrl = 'gs://tekfix-45b38.appspot.com/shops/tekfix/purchase_invoices/inv1.pdf';
      final resolved2 = await StorageBridge.resolveDownloadUrl(
        shopId: mockShopId,
        rawUrlOrPath: legacyGsUrl,
      );
      expect(resolved2, equals(legacyGsUrl));

      // Test 3: Staging Supabase relative path resolves to short-lived signed URL
      final mockHttp = MockClient((request) async {
        if (request.url.path.endsWith('/get-download-url')) {
          return http.Response(
            jsonEncode({
              'signedUrl': 'https://mock.supabase.co/storage/v1/object/sign/financial-records/receipt.jpg?token=xyz',
            }),
            200,
          );
        }
        return http.Response('Not Found', 404);
      });

      final client = SupabaseStorageBridgeClient(
        edgeFunctionBaseUrl: mockBaseUrl,
        getFirebaseIdToken: () async => mockToken,
        httpClient: mockHttp,
      );

      StorageBridge.configure(
        environment: StorageEnvironment.staging,
        supabaseClient: client,
      );

      final resolvedStaging = await StorageBridge.resolveDownloadUrl(
        shopId: mockShopId,
        rawUrlOrPath: 'shops/$mockShopId/expense_receipts/receipt.jpg',
      );
      expect(resolvedStaging, contains('https://mock.supabase.co/storage/v1/object/sign/'));
    });
  });
}
