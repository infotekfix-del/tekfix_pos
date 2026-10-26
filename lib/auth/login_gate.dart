import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../attendance/staff_attendance_screen.dart';
import '../main.dart' show AppShell, Db, kPrimary;
import '../update/app_update_service.dart';
import '../utils/tek_helpers.dart';
import 'auth_controller.dart';

Map<String, dynamic> _m(dynamic v) => tekM(v);

/// Shows login until a verified session exists, then the normal AppShell or StaffAttendanceScreen.
class AuthGate extends StatefulWidget {
  const AuthGate({super.key});

  @override
  State<AuthGate> createState() => _AuthGateState();
}

class _AuthGateState extends State<AuthGate> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      AppUpdateService.instance.checkForUpdate(context, autoShowDialog: true);
    });
  }

  @override
  Widget build(BuildContext context) {
    final a = context.watch<AuthController>();
    if (a.loading) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    if (a.isStaffLoggedIn) {
      return StaffAttendanceScreen(
        shopId: a.shopId,
        staffId: a.uid,
        staffName: a.name,
      );
    }
    return a.signedIn ? const AppShell() : const LoginScreen();
  }
}

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});
  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _shop = TextEditingController(text: Db.setting('shop_id'));
  final _name = TextEditingController();
  final _email = TextEditingController();
  final _pass = TextEditingController();

  int _mode = 0; // 0 = Owner Sign In, 1 = Staff Login
  bool _create = false, _busy = false, _hide = true;
  String? _err;

  @override
  void dispose() {
    for (final c in [_shop, _name, _email, _pass]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _go() async {
    final shopId = _shop.text.trim().toLowerCase();
    if (shopId.isEmpty) {
      setState(() => _err = 'Shop ID നൽകുക (Enter Shop ID)');
      return;
    }

    if (_mode == 1) {
      // Staff Login: Shop ID, Email Address, Password
      final email = _email.text.trim().toLowerCase();
      final pass = _pass.text;
      if (email.isEmpty || pass.isEmpty) {
        setState(() => _err =
            'ഇമെയിലും പാസ്‌വേഡും നൽകുക (Enter email address and password)');
        return;
      }
      setState(() {
        _busy = true;
        _err = null;
      });

      UserCredential? cred;
      try {
        // 1. Authenticate credentials with Firebase Auth
        cred = await FirebaseAuth.instance.signInWithEmailAndPassword(
          email: email,
          password: pass,
        );
      } on FirebaseAuthException catch (e) {
        if (e.code == 'network-request-failed') {
          debugPrint('Network request failed, checking offline approval');
        } else {
          setState(() {
            _busy = false;
            _err = _msg(e);
          });
          return;
        }
      } catch (e) {
        debugPrint('Staff sign in error: $e');
      }

      // 2. If online authentication succeeded, verify Shop ID and Owner Authorization in Firestore
      if (cred?.user != null) {
        final uid = cred!.user!.uid;
        try {
          final userDoc = await FirebaseFirestore.instance
              .doc('shops/$shopId/users/$uid')
              .get();

          if (!userDoc.exists) {
            await FirebaseAuth.instance.signOut();
            setState(() {
              _busy = false;
              _err =
                  'ഈ സ്റ്റാഫ് അക്കൗണ്ട് "$shopId" ഷോപ്പിൽ രജിസ്റ്റർ ചെയ്തിട്ടില്ല.\n(Staff account not registered under Shop ID "$shopId")';
            });
            return;
          }

          final userData = userDoc.data() ?? {};
          if (userData['role'] != 'staff') {
            await FirebaseAuth.instance.signOut();
            setState(() {
              _busy = false;
              _err = 'ഇത് ഒരു സ്റ്റാഫ് അക്കൗണ്ട് അല്ല (Not a staff account)';
            });
            return;
          }

          // Owner Authorization & Approval Check
          final bool isApproved =
              userData['approved'] != false && userData['active'] != false;
          if (!isApproved) {
            await FirebaseAuth.instance.signOut();
            setState(() {
              _busy = false;
              _err =
                  'ഈ സ്റ്റാഫ് അക്കൗണ്ടിന് ഉടമസ്ഥന്റെ അനുമതിയില്ല (Account not approved by Shop Owner)';
            });
            return;
          }

          // Successfully authenticated & verified
          await Db.settings.put('shop_id', shopId);
          await Db.settings.put('staff_logged_in', 'true');
          await Db.settings.put('staff_logged_id', uid);
          await Db.settings
              .put('staff_logged_name', '${userData['name'] ?? email}');
          await Db.settings.put('staff_logged_email', email);
          await Db.settings.put('auth_role', 'staff');

          // Cache to local owner-approved staff list
          final approvedList = List<String>.from(Db.settings
              .get('approved_staff_emails', defaultValue: <String>[]));
          if (!approvedList.contains(email)) {
            approvedList.add(email);
            await Db.settings.put('approved_staff_emails', approvedList);
          }

          if (mounted) context.read<AuthController>().notify();
          return;
        } catch (e) {
          debugPrint('Error loading staff user doc: $e');
          // If Firestore read fails due to network glitch but Auth passed:
          await Db.settings.put('shop_id', shopId);
          await Db.settings.put('staff_logged_in', 'true');
          await Db.settings.put('staff_logged_id', uid);
          await Db.settings.put('staff_logged_name', email);
          await Db.settings.put('staff_logged_email', email);
          await Db.settings.put('auth_role', 'staff');
          if (mounted) context.read<AuthController>().notify();
          return;
        }
      }

      // 3. Offline Verification: Validate against owner-approved staff emails
      final approvedList = List<String>.from(Db.settings
          .get('approved_staff_emails', defaultValue: <String>[]));

      Map<String, dynamic>? localStaff;
      for (final v in Db.staff.values) {
        final m = _m(v);
        if ('${m['email']}'.trim().toLowerCase() == email) {
          localStaff = m;
          break;
        }
      }

      final isLocallyApproved = approvedList.contains(email) ||
          (localStaff != null &&
              localStaff['approved'] != false &&
              localStaff['active'] != false);

      if (isLocallyApproved) {
        await Db.settings.put('shop_id', shopId);
        await Db.settings.put('staff_logged_in', 'true');
        await Db.settings.put('staff_logged_id',
            localStaff != null ? '${localStaff['_id'] ?? email}' : email);
        await Db.settings.put('staff_logged_name',
            localStaff != null ? '${localStaff['name'] ?? 'Staff'}' : email);
        await Db.settings.put('staff_logged_email', email);
        await Db.settings.put('auth_role', 'staff');
        if (mounted) context.read<AuthController>().notify();
        return;
      }

      setState(() {
        _busy = false;
        _err =
            'ഈ ഇമെയിലിന് ഉടമസ്ഥന്റെ അനുമതിയില്ല അല്ലെങ്കിൽ ഇന്റർനെറ്റ് ഇല്ല (Email not approved by Shop Owner or offline)';
      });
      return;
    }

    // Owner Login
    if (_email.text.trim().isEmpty || _pass.text.isEmpty) {
      setState(() => _err = 'എല്ലാ വിവരങ്ങളും നൽകുക (Fill all fields)');
      return;
    }
    setState(() {
      _busy = true;
      _err = null;
    });
    final a = context.read<AuthController>();
    final e = _create
        ? await a.createShopOwner(shopId,
            _name.text.isEmpty ? 'Owner' : _name.text, _email.text, _pass.text)
        : await a.signIn(shopId, _email.text, _pass.text);
    if (mounted) {
      setState(() {
        _busy = false;
        _err = e ?? a.error;
      });
    }
  }

  String _msg(FirebaseAuthException e) {
    switch (e.code) {
      case 'invalid-credential':
      case 'wrong-password':
      case 'user-not-found':
        return 'ഇമെയിൽ അല്ലെങ്കിൽ പാസ്‌വേഡ് തെറ്റാണ്, അല്ലെങ്കിൽ ഉടമസ്ഥൻ അക്കൗണ്ട് രജിസ്റ്റർ ചെയ്തിട്ടില്ല.\n(Invalid email/password, or account not yet registered by Owner)';
      case 'network-request-failed':
        return 'ഇന്റർനെറ്റ് ഇല്ല (No internet connection)';
      case 'email-already-in-use':
        return 'ഇമെയിൽ ഇതിനകം ഉണ്ട് (Email already in use)';
      case 'weak-password':
        return 'പാസ്‌വേഡ് കുറഞ്ഞത് 6 അക്ഷരം (Min 6 characters)';
      default:
        return e.message ?? e.code;
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(20),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 400),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.storefront_rounded, size: 56, color: cs.primary),
                const SizedBox(height: 8),
                const Text('TEKFIX ERP & POS',
                    style:
                        TextStyle(fontSize: 22, fontWeight: FontWeight.w800)),
                const SizedBox(height: 4),
                Text(_mode == 1
                    ? 'ജീവനക്കാരുടെ ലോഗിൻ (Staff Portal)'
                    : (_create
                        ? 'പുതിയ ഷോപ്പ് (Create shop owner)'
                        : 'ഷോപ്പ് ഉടമ (Owner Sign in)')),
                const SizedBox(height: 16),

                // Mode Selector
                SegmentedButton<int>(
                  showSelectedIcon: false,
                  segments: const [
                    ButtonSegment(
                        value: 0,
                        icon: Icon(Icons.admin_panel_settings_rounded, size: 16),
                        label: Text('Owner')),
                    ButtonSegment(
                        value: 1,
                        icon: Icon(Icons.badge_rounded, size: 16),
                        label: Text('Staff Login')),
                  ],
                  selected: {_mode},
                  onSelectionChanged: (s) => setState(() {
                    _mode = s.first;
                    _err = null;
                  }),
                ),
                const SizedBox(height: 16),

                TextField(
                  controller: _shop,
                  decoration: const InputDecoration(
                    labelText: 'Shop ID (ഷോപ്പ് കോഡ്)',
                    prefixIcon: Icon(Icons.store),
                  ),
                ),
                const SizedBox(height: 10),

                if (_mode == 0 && _create) ...[
                  TextField(
                    controller: _name,
                    decoration: const InputDecoration(
                      labelText: 'Owner name (പേര്)',
                      prefixIcon: Icon(Icons.person),
                    ),
                  ),
                  const SizedBox(height: 10),
                ],

                TextField(
                  controller: _email,
                  keyboardType: TextInputType.emailAddress,
                  decoration: InputDecoration(
                    labelText: _mode == 1
                        ? 'Staff Email (അംഗീകൃത ഇമെയിൽ)'
                        : 'Owner Email',
                    prefixIcon: const Icon(Icons.email_rounded),
                  ),
                ),
                const SizedBox(height: 10),

                TextField(
                  controller: _pass,
                  obscureText: _hide,
                  onSubmitted: (_) => _go(),
                  decoration: InputDecoration(
                    labelText: _mode == 1
                        ? 'Staff Password (പാസ്‌വേഡ്)'
                        : 'Password (പാസ്‌വേഡ്)',
                    prefixIcon: const Icon(Icons.lock_rounded),
                    suffixIcon: IconButton(
                      icon: Icon(_hide
                          ? Icons.visibility
                          : Icons.visibility_off),
                      onPressed: () => setState(() => _hide = !_hide),
                    ),
                  ),
                ),

                if (_err != null)
                  Container(
                    margin: const EdgeInsets.only(top: 12),
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: Colors.red.shade50,
                      border:
                          Border.all(color: Colors.red.shade400, width: 1.5),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Row(
                      children: [
                        Icon(Icons.error_outline_rounded,
                            color: Colors.red.shade700, size: 20),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            _err!,
                            style: TextStyle(
                              color: Colors.red.shade900,
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                const SizedBox(height: 16),
                SizedBox(
                  width: double.infinity,
                  height: 48,
                  child: FilledButton(
                    style: FilledButton.styleFrom(
                      backgroundColor: kPrimary,
                      foregroundColor: Colors.white,
                    ),
                    onPressed: _busy ? null : _go,
                    child: _busy
                        ? const SizedBox(
                            width: 22,
                            height: 22,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: Colors.white,
                            ),
                          )
                        : Text(_mode == 1
                            ? 'ലോഗിൻ ചെയ്യുക (Staff Login)'
                            : (_create ? 'Create & Sign in' : 'Sign in')),
                  ),
                ),
                if (_mode == 0)
                  TextButton(
                    onPressed: () => setState(() {
                      _create = !_create;
                      _err = null;
                    }),
                    child: Text(_create
                        ? 'Already have an account? Sign in'
                        : 'First time? Create shop owner account'),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
