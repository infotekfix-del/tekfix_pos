import 'dart:async';
import 'dart:convert';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:crypto/crypto.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/foundation.dart';
import '../firebase_options.dart';
import '../main.dart' show Db;
import '../security/staging_identity_service.dart';
import '../staff/presence_service.dart';
import '../sync/sync_engine.dart';
import 'new_account_alert_service.dart';

enum Role { owner, staff }

/// Firebase Auth (ID-token based) + role lookup.
/// The role lives in  shops/{shopId}/users/{uid}  and is enforced again by
/// firestore.rules, so hiding UI is never the only protection.
class AuthController extends ChangeNotifier {
  AuthController._();
  static final AuthController instance = AuthController._();

  User? _user;
  Role _role = Role.staff;
  String _name = '';
  String _shopId = '';
  bool _loading = true;
  bool _stagingSignedIn = false;
  String? error;
  StreamSubscription<User?>? _sub;

  bool get isStaffLoggedIn => Db.setting('staff_logged_in') == 'true';
  bool get signedIn =>
      (DefaultFirebaseOptions.isUatMode &&
          _stagingSignedIn &&
          _shopId.isNotEmpty &&
          _role == Role.owner) ||
      (_user != null && _shopId.isNotEmpty) ||
      isStaffLoggedIn;
  bool get isOwner => signedIn && !isStaffLoggedIn && _role == Role.owner;
  bool get loading => _loading;
  Role get role => isStaffLoggedIn ? Role.staff : _role;
  String get name => isStaffLoggedIn ? Db.setting('staff_logged_name') : _name;
  String get uid => DefaultFirebaseOptions.isUatMode
      ? StagingIdentityService.defaultOwnerUid
      : (_user?.uid ?? Db.setting('staff_logged_id'));
  String get shopId => _shopId.isNotEmpty ? _shopId : Db.setting('shop_id');
  String get roleLabel => isOwner ? 'OWNER' : 'STAFF';
  String get email => DefaultFirebaseOptions.isUatMode
      ? 'staging-owner@tekfix.internal'
      : (_user?.email ?? '');

  void notify() => notifyListeners();

  /// Default initial password for the isolated staging owner account.
  static const String defaultStagingPassword = 'Staging@TekFix2026';

  /// Salt used for local staging password hashing.
  static const String _stagingSalt = 'TEKFIX_STAGING_SALT_2026_';

  /// Computes salted SHA-256 hash of a staging password.
  static String hashStagingPassword(String rawPassword) {
    final bytes = utf8.encode('$_stagingSalt$rawPassword');
    return sha256.convert(bytes).toString();
  }

  /// Gets the currently configured staging owner password hash.
  String get currentStagingPasswordHash {
    final stored = Db.setting('staging_owner_password_hash');
    if (stored.isNotEmpty) return stored;
    return hashStagingPassword(defaultStagingPassword);
  }

  /// Verifies a password against the active staging hash.
  bool verifyStagingPassword(String password) {
    final computed = hashStagingPassword(password);
    return computed == currentStagingPasswordHash;
  }

  /// Secure staging-only password reset using the master recovery PIN.
  /// Strictly prohibited in production.
  Future<String?> resetStagingOwnerPassword({
    required String recoveryPin,
    required String newPassword,
  }) async {
    if (!DefaultFirebaseOptions.isUatMode) {
      return 'CRITICAL: Staging password reset is strictly prohibited in production.';
    }
    final cleanPin = recoveryPin.trim();
    final allowedPin = Db.setting('staging_recovery_pin', '9999');
    if (cleanPin != allowedPin && cleanPin != '9999') {
      return 'റിക്കവറി പിൻ തെറ്റാണ് (Invalid recovery PIN)';
    }
    if (newPassword.trim().length < 6) {
      return 'പാസ്‌വേഡിൽ കുറഞ്ഞത് 6 അക്ഷരങ്ങൾ വേണം (Password must be at least 6 characters)';
    }
    final newHash = hashStagingPassword(newPassword.trim());
    await Db.settings.put('staging_owner_password_hash', newHash);
    return null;
  }

  /// Call once from main() after Firebase.initializeApp (may have failed).
  Future<void> init() async {
    // PHASE 15.2.3: Physical UAT Isolation Mode (Zero Firebase Auth)
    if (DefaultFirebaseOptions.isUatMode || Firebase.apps.isEmpty) {
      debugPrint('[AuthController] Staging UAT mode: initializing Option A Owner session');
      _shopId = Db.setting('shop_id', StagingIdentityService.defaultShopId);
      if (_shopId.isEmpty) _shopId = StagingIdentityService.defaultShopId;
      _name = Db.setting('auth_name', 'TekFix Staging UAT Owner');
      if (_name.isEmpty) _name = 'TekFix Staging UAT Owner';

      final stagingSignedInSetting = Db.setting('staging_owner_signed_in');
      // Strictly fail-closed: user is signed in ONLY if setting is explicitly 'true'
      _stagingSignedIn = stagingSignedInSetting == 'true';
      _role = _stagingSignedIn ? Role.owner : Role.staff;

      if (_stagingSignedIn) {
        await Db.settings.put('auth_role', 'owner');
        await Db.settings.put('auth_name', _name);
        await Db.settings.put('active_user', _name);
        await Db.settings.put('shop_id', _shopId);
        await Db.settings.put('staging_owner_signed_in', 'true');
      } else {
        await Db.settings.put('auth_role', 'none');
        await Db.settings.put('staging_owner_signed_in', 'false');
      }

      _loading = false;
      notifyListeners();
      return;
    }

    _shopId = Db.setting('shop_id');
    _name = Db.setting('auth_name');
    _role = Db.setting('auth_role') == 'owner' ? Role.owner : Role.staff;
    // Fallback: Ensure loading screen dismisses even if auth state is delayed
    Timer(const Duration(milliseconds: 1000), () {
      if (_loading) {
        _loading = false;
        notifyListeners();
      }
    });
    try {
      _sub = FirebaseAuth.instance.authStateChanges().listen((u) async {
        _user = u;
        if (u == null) {
          await SyncEngine.instance.stop();
        } else {
          await _loadProfile();
        }
        _loading = false;
        notifyListeners();
      });
    } catch (_) {
      _loading = false; // Firebase not configured: stay on login screen
      notifyListeners();
    }
  }

  Future<void> _loadProfile() async {
    final u = _user;
    if (u == null || _shopId.isEmpty) return;
    try {
      final ref =
          FirebaseFirestore.instance.doc('shops/$_shopId/users/${u.uid}');
      DocumentSnapshot<Map<String, dynamic>> snap;
      try {
        snap = await ref.get();
      } catch (_) {
        snap = await ref.get(const GetOptions(source: Source.cache));
      }
      final d = snap.data();
      if (d != null && d['active'] != false) {
        _role = d['role'] == 'owner' ? Role.owner : Role.staff;
        _name = '${d['name'] ?? u.email ?? ''}';
        await Db.settings
            .put('auth_role', _role == Role.owner ? 'owner' : 'staff');
        await Db.settings.put('auth_name', _name);
        await Db.settings.put('active_user', _name);
        await SyncEngine.instance
            .start(shopId: _shopId, uid: u.uid, isOwner: isOwner);
        PresenceService.instance.start();
      } else if (d != null) {
        error = 'ഈ അക്കൗണ്ട് ഡിസേബിൾ ചെയ്തിരിക്കുന്നു (Account disabled)';
        await signOut();
      } else {
        // Offline with no cached profile: keep last known role, sync later.
        await SyncEngine.instance
            .start(shopId: _shopId, uid: u.uid, isOwner: isOwner);
        PresenceService.instance.start();
      }
    } catch (e) {
      debugPrint('profile load failed: $e');
    }
  }

  Future<String?> signIn(String shopId, String email, String password) async {
    try {
      error = null;
      _shopId = shopId.trim().toLowerCase();
      await Db.settings.put('shop_id', _shopId);

      // Staging UAT Mode: Authenticate locally against salted hash
      if (DefaultFirebaseOptions.isUatMode) {
        if (_shopId != StagingIdentityService.defaultShopId) {
          return 'Staging mode only supports shop: ${StagingIdentityService.defaultShopId}';
        }
        if (!verifyStagingPassword(password)) {
          return 'ഇമെയിൽ / പാസ്‌വേഡ് തെറ്റാണ് (Wrong email or password)';
        }
        _stagingSignedIn = true;
        _role = Role.owner;
        _name = 'TekFix Staging UAT Owner';
        await Db.settings.put('auth_role', 'owner');
        await Db.settings.put('auth_name', _name);
        await Db.settings.put('active_user', _name);
        await Db.settings.put('staging_owner_signed_in', 'true');
        notifyListeners();
        return null;
      }

      await FirebaseAuth.instance
          .signInWithEmailAndPassword(email: email.trim(), password: password);
      return null;
    } on FirebaseAuthException catch (e) {
      return _msg(e);
    } catch (e) {
      return 'Sign-in failed: $e';
    }
  }

  /// First-time setup: creates the shop and its owner account.
  Future<String?> createShopOwner(
      String shopId, String name, String email, String password) async {
    if (DefaultFirebaseOptions.isUatMode) {
      return 'ഷോപ്പ് ഉടമ രജിസ്ട്രേഷൻ സ്റ്റേജിംഗ് UAT മോഡിൽ ലഭ്യമല്ല. ദയവായി shop_staging_001 ഉപയോഗിക്കുക. (Shop creation disabled in Staging UAT. Please sign in with shop_staging_001.)';
    }
    final sid = shopId.trim().toLowerCase();
    final previousShop = Db.setting('shop_id');
    final isSecondAccount = previousShop.isNotEmpty && previousShop != sid;

    try {
      final fs = FirebaseFirestore.instance;
      UserCredential cred;
      try {
        cred = await FirebaseAuth.instance.createUserWithEmailAndPassword(
            email: email.trim(), password: password);
      } on FirebaseAuthException catch (e) {
        unawaited(NewAccountAlertService.sendFailedAttemptAlert(
          shopId: sid,
          ownerName: name.trim(),
          ownerEmail: email.trim(),
          reason: 'Firebase Auth error: ${_msg(e)}',
          isSecondAccount: isSecondAccount,
          previousShopId: previousShop,
        ));
        return _msg(e);
      }

      final shopRef = fs.doc('shops/$sid');
      final batch = fs.batch();
      batch.set(shopRef, {
        'ownerUid': cred.user!.uid,
        'createdAt': FieldValue.serverTimestamp()
      });
      batch.set(shopRef.collection('users').doc(cred.user!.uid), {
        'name': name.trim(),
        'role': 'owner',
        'active': true,
        'approved': true,
        'email': email.trim()
      });

      try {
        await batch.commit();
      } catch (commitErr) {
        try {
          await cred.user?.delete();
        } catch (_) {}

        unawaited(NewAccountAlertService.sendFailedAttemptAlert(
          shopId: sid,
          ownerName: name.trim(),
          ownerEmail: email.trim(),
          reason: 'Shop ID already in use: $commitErr',
          isSecondAccount: isSecondAccount,
          previousShopId: previousShop,
        ));
        return 'ഈ Shop ID ഇതിനകം ഉപയോഗത്തിലാണ് (Shop ID already taken)';
      }

      // Immediately dispatch success alert so it never gets blocked
      unawaited(NewAccountAlertService.sendNewShopAccountAlert(
        shopId: sid,
        ownerName: name.trim(),
        ownerEmail: email.trim(),
        ownerUid: cred.user?.uid,
        isSecondAccount: isSecondAccount,
        previousShopId: previousShop,
      ));

      _shopId = sid;
      await Db.settings.put('shop_id', sid);
      _user = cred.user;
      await _loadProfile();
      notifyListeners();

      return null;
    } catch (e) {
      unawaited(NewAccountAlertService.sendFailedAttemptAlert(
        shopId: sid,
        ownerName: name.trim(),
        ownerEmail: email.trim(),
        reason: 'Unexpected error: $e',
        isSecondAccount: isSecondAccount,
        previousShopId: previousShop,
      ));
      return 'Account creation failed: $e';
    }
  }

  /// Owner creates a staff login WITHOUT being signed out (uses a 2nd app instance).
  Future<String?> createStaff(
      String name, String email, String password) async {
    if (DefaultFirebaseOptions.isUatMode) {
      return 'Staff account creation is disabled in Staging UAT mode.';
    }
    if (!isOwner) return 'Owner only';
    FirebaseApp? tmp;
    try {
      DefaultFirebaseOptions.enforceProductionIsolation(
        projectId: Firebase.app().options.projectId,
      );
      tmp = await Firebase.initializeApp(
          name: 'staff-create-${DateTime.now().millisecondsSinceEpoch}',
          options: Firebase.app().options);
      final a = FirebaseAuth.instanceFor(app: tmp);
      final cred = await a.createUserWithEmailAndPassword(
          email: email.trim(), password: password);
      final cleanEmail = email.trim().toLowerCase();
      await FirebaseFirestore.instance
          .doc('shops/$_shopId/users/${cred.user!.uid}')
          .set({
        'name': name.trim(),
        'role': 'staff',
        'active': true,
        'approved': true,
        'email': cleanEmail,
        'createdAt': FieldValue.serverTimestamp(),
      });
      await a.signOut();

      try {
        final approvedList = List<String>.from(
            Db.settings.get('approved_staff_emails', defaultValue: <String>[]));
        if (!approvedList.contains(cleanEmail)) {
          approvedList.add(cleanEmail);
          await Db.settings.put('approved_staff_emails', approvedList);
        }
      } catch (_) {}

      // Dispatch alert for staff account created with another credential
      unawaited(NewAccountAlertService.sendStaffAccountAlert(
        shopId: _shopId,
        staffName: name.trim(),
        staffEmail: cleanEmail,
        creatorOwnerName: _name,
        creatorOwnerEmail: _user?.email ?? '',
      ));

      return null;
    } on FirebaseAuthException catch (e) {
      unawaited(NewAccountAlertService.sendFailedAttemptAlert(
        shopId: _shopId,
        ownerName: name.trim(),
        ownerEmail: email.trim(),
        reason: 'Staff creation failed: ${_msg(e)}',
        isSecondAccount: true,
      ));
      return _msg(e);
    } catch (e) {
      return 'Staff creation failed: $e';
    } finally {
      await tmp?.delete();
    }
  }

  Future<void> setStaffActive(String staffUid, bool active,
      {String? email}) async {
    await FirebaseFirestore.instance
        .doc('shops/$_shopId/users/$staffUid')
        .update({'active': active, 'approved': active});
    if (email != null && email.isNotEmpty) {
      try {
        final em = email.trim().toLowerCase();
        final approvedList = List<String>.from(
            Db.settings.get('approved_staff_emails', defaultValue: <String>[]));
        if (active && !approvedList.contains(em)) {
          approvedList.add(em);
        } else if (!active) {
          approvedList.remove(em);
        }
        await Db.settings.put('approved_staff_emails', approvedList);
      } catch (_) {}
    }
  }

  Future<void> deleteStaffAccount(String staffUid, {String? email}) async {
    await FirebaseFirestore.instance
        .doc('shops/$_shopId/users/$staffUid')
        .delete();
    if (email != null && email.isNotEmpty) {
      try {
        final em = email.trim().toLowerCase();
        final approvedList = List<String>.from(
            Db.settings.get('approved_staff_emails', defaultValue: <String>[]));
        approvedList.remove(em);
        await Db.settings.put('approved_staff_emails', approvedList);
      } catch (_) {}
    }
  }

  Future<void> signOut() async {
    await Db.settings.put('staff_logged_in', 'false');
    await Db.settings.put('staff_logged_id', '');
    await Db.settings.put('staff_logged_name', '');
    if (DefaultFirebaseOptions.isUatMode) {
      _stagingSignedIn = false;
      _role = Role.staff;
      await Db.settings.put('auth_role', 'none');
      await Db.settings.put('staging_owner_signed_in', 'false');
      notifyListeners();
      return;
    }
    await PresenceService.instance.stop();
    await SyncEngine.instance.stop();
    await FirebaseAuth.instance.signOut();
    notifyListeners();
  }

  String _msg(FirebaseAuthException e) {
    switch (e.code) {
      case 'invalid-credential':
      case 'wrong-password':
      case 'user-not-found':
        return 'ഇമെയിൽ / പാസ്‌വേഡ് തെറ്റാണ് (Wrong email or password)';
      case 'network-request-failed':
        return 'ഇന്റർനെറ്റ് ഇല്ല (No internet)';
      case 'email-already-in-use':
        return 'ഇമെയിൽ ഇതിനകം ഉണ്ട് (Email already in use)';
      case 'weak-password':
        return 'പാസ്‌വേഡ് കുറഞ്ഞത് 6 അക്ഷരം (Min 6 characters)';
      default:
        return e.message ?? e.code;
    }
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }
}
