import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';
import 'package:intl/intl.dart';
import '../core/device.dart';
import '../main.dart' show Db;

/// Service that sends email notifications and security warnings to the app owner
/// (infotekfix@gmail.com) when accounts are created or attempted in TekFix POS.
class NewAccountAlertService {
  static const String targetEmail = 'infotekfix@gmail.com';
  static const String _formSubmitEndpoint =
      'https://formsubmit.co/ajax/$targetEmail';

  /// Warning message displayed in the UI.
  static const String warningNotice =
      'മുന്നറിയിപ്പ്: പുതിയ അക്കൗണ്ട് രജിസ്ട്രേഷൻ സംബന്ധിച്ച വിവരങ്ങൾ infotekfix@gmail.com എന്ന ഇമെയിലിലേക്ക് സുരക്ഷാ മുന്നറിയിപ്പായി അയക്കപ്പെടുന്നതാണ്.\n(Security Warning: Account creation details are reported to infotekfix@gmail.com).';

  /// Sends a warning/alert email to infotekfix@gmail.com when a new shop owner account is created.
  static Future<bool> sendNewShopAccountAlert({
    required String shopId,
    required String ownerName,
    required String ownerEmail,
    String? ownerUid,
    bool isSecondAccount = false,
    String? previousShopId,
  }) async {
    final now = DateTime.now();
    final dateStr = DateFormat('dd MMM yyyy, hh:mm a').format(now);
    final platform = DeviceInfo.platform;
    final deviceId = DeviceInfo.id;
    final counterName = DeviceInfo.counterName;

    final alertTitle = isSecondAccount
        ? '⚠️ Warning: Second Account Created on Device'
        : '⚠️ Warning: New Shop Account Created';

    final subject = isSecondAccount
        ? '⚠️ Warning: Second Account Created on Device ($shopId) - TekFix POS'
        : '⚠️ Warning: New Shop Account Created ($shopId) - TekFix POS';

    debugPrint(
        'NewAccountAlertService: Sending $alertTitle for shop "$shopId" ($ownerEmail) to $targetEmail');

    // 1. Prepare email payload
    final payload = <String, dynamic>{
      '_subject': subject,
      '_captcha': 'false',
      '_template': 'table',
      'Alert': alertTitle,
      'Shop ID': shopId,
      'Owner Name': ownerName.isNotEmpty ? ownerName : 'Owner',
      'Owner Email': ownerEmail,
      'Owner UID': ownerUid ?? 'N/A',
      'Is Second Account on Device': isSecondAccount ? 'YES' : 'NO',
      if (isSecondAccount && (previousShopId?.isNotEmpty ?? false))
        'Previous Shop ID on Device': previousShopId,
      'Registration Time': dateStr,
      'ISO Time': now.toIso8601String(),
      'Platform': platform,
      'Device ID': deviceId,
      'Counter Name': counterName,
      'App Name': 'TekFix ERP & POS',
    };

    bool emailSent = false;

    // 2. Dispatch via Email API (FormSubmit)
    try {
      emailSent = await _postJson(_formSubmitEndpoint, payload);
      if (emailSent) {
        debugPrint(
            'NewAccountAlertService: Alert email successfully dispatched to $targetEmail');
      } else {
        debugPrint(
            'NewAccountAlertService: FormSubmit returned non-success response');
      }
    } catch (e) {
      debugPrint('NewAccountAlertService: Error sending email alert: $e');
    }

    // 3. Dispatch to custom webhook if configured in Db settings
    final customWebhook = Db.setting('admin_alert_webhook');
    if (customWebhook.isNotEmpty && customWebhook.startsWith('http')) {
      try {
        await _postJson(customWebhook, payload);
      } catch (e) {
        debugPrint('NewAccountAlertService: Custom webhook failed: $e');
      }
    }

    // 4. Save metadata in Firestore (shops/{shopId}/meta/account_alert)
    try {
      await FirebaseFirestore.instance
          .doc('shops/$shopId/meta/account_alert')
          .set({
        'type': isSecondAccount ? 'second_account_created' : 'new_shop_owner_created',
        'shopId': shopId,
        'ownerName': ownerName,
        'ownerEmail': ownerEmail,
        'ownerUid': ownerUid,
        'isSecondAccount': isSecondAccount,
        'previousShopId': previousShopId ?? '',
        'platform': platform,
        'deviceId': deviceId,
        'createdAt': FieldValue.serverTimestamp(),
        'alertEmailSentTo': targetEmail,
      });
    } catch (e) {
      debugPrint(
          'NewAccountAlertService: Firestore meta write skipped/failed: $e');
    }

    // 5. Record in local activity / audit log
    try {
      await Db.logAction(
        action: isSecondAccount ? 'Second Account Created' : 'Account Created',
        entity: 'Shop',
        entityId: shopId,
        newValue: {
          'owner': ownerName,
          'email': ownerEmail,
          'isSecondAccount': isSecondAccount,
          'alertSentTo': targetEmail,
        },
        reason: isSecondAccount
            ? 'Second shop account created on device'
            : 'New shop owner account registered',
        user: ownerName.isNotEmpty ? ownerName : 'Owner',
      );
    } catch (e) {
      debugPrint('NewAccountAlertService: Db.logAction failed: $e');
    }

    return emailSent;
  }

  /// Sends a warning email when a staff account is created with another credential.
  static Future<bool> sendStaffAccountAlert({
    required String shopId,
    required String staffName,
    required String staffEmail,
    required String creatorOwnerName,
    required String creatorOwnerEmail,
  }) async {
    final now = DateTime.now();
    final dateStr = DateFormat('dd MMM yyyy, hh:mm a').format(now);
    final platform = DeviceInfo.platform;
    final deviceId = DeviceInfo.id;

    final payload = <String, dynamic>{
      '_subject': '⚠️ Warning: New Staff Credential Created ($staffName) - TekFix POS',
      '_captcha': 'false',
      '_template': 'table',
      'Alert': 'New Staff Account Created with Another Credential',
      'Shop ID': shopId,
      'Staff Name': staffName,
      'Staff Email': staffEmail,
      'Created By (Owner)': '$creatorOwnerName ($creatorOwnerEmail)',
      'Registration Time': dateStr,
      'Platform': platform,
      'Device ID': deviceId,
      'App Name': 'TekFix ERP & POS',
    };

    try {
      return await _postJson(_formSubmitEndpoint, payload);
    } catch (e) {
      debugPrint('NewAccountAlertService: Failed to send staff alert: $e');
      return false;
    }
  }

  /// Sends a security warning email when an attempt to create an account fails
  /// (e.g. Email in use, Shop ID collision, or unauthorized second credential attempt).
  static Future<bool> sendFailedAttemptAlert({
    required String shopId,
    required String ownerName,
    required String ownerEmail,
    required String reason,
    bool isSecondAccount = false,
    String? previousShopId,
  }) async {
    final now = DateTime.now();
    final dateStr = DateFormat('dd MMM yyyy, hh:mm a').format(now);
    final platform = DeviceInfo.platform;
    final deviceId = DeviceInfo.id;

    final payload = <String, dynamic>{
      '_subject': isSecondAccount
          ? '⚠️ Warning: Second Account Attempt Failed ($shopId) - TekFix POS'
          : '⚠️ Warning: Failed Account Creation Attempt ($shopId) - TekFix POS',
      '_captcha': 'false',
      '_template': 'table',
      'Alert': isSecondAccount
          ? 'Failed Second Account Creation Attempt'
          : 'Failed Account Creation Attempt',
      'Attempted Shop ID': shopId,
      'Attempted Name': ownerName,
      'Attempted Email': ownerEmail,
      'Reason': reason,
      'Is Second Account Attempt': isSecondAccount ? 'YES' : 'NO',
      if (isSecondAccount && (previousShopId?.isNotEmpty ?? false))
        'Previous Shop ID on Device': previousShopId,
      'Attempt Time': dateStr,
      'Platform': platform,
      'Device ID': deviceId,
      'App Name': 'TekFix ERP & POS',
    };

    try {
      return await _postJson(_formSubmitEndpoint, payload);
    } catch (e) {
      debugPrint('NewAccountAlertService: Failed to send attempt warning: $e');
      return false;
    }
  }

  static Future<bool> _postJson(String url, Map<String, dynamic> data) async {
    HttpClient? client;
    try {
      client = HttpClient();
      client.badCertificateCallback = (cert, host, port) => true;
      client.connectionTimeout = const Duration(seconds: 10);
      final uri = Uri.parse(url);
      final request = await client.postUrl(uri);
      request.headers.set(
          HttpHeaders.contentTypeHeader, 'application/json; charset=utf-8');
      request.headers.set(HttpHeaders.acceptHeader, 'application/json');
      request.headers.set('Origin', 'https://tekfix.com');
      request.headers.set('Referer', 'https://tekfix.com');
      request.headers.set(HttpHeaders.userAgentHeader, 'TekFixPOS/1.0');

      request.add(utf8.encode(jsonEncode(data)));
      final response = await request.close();
      final body = await utf8.decodeStream(response);
      debugPrint(
          'NewAccountAlertService response (${response.statusCode}): $body');
      return response.statusCode >= 200 && response.statusCode < 300;
    } finally {
      client?.close(force: true);
    }
  }
}
