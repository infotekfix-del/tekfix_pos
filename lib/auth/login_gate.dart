import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import '../attendance/staff_attendance_screen.dart';
import '../main.dart' show AppShell, Db;
import '../theme/tek_tokens.dart';
import '../update/app_update_service.dart';
import '../utils/tek_helpers.dart';
import 'auth_controller.dart';

Map<String, dynamic> _m(dynamic v) => tekM(v);

/// Shows login until a verified session exists, then routes strictly by role.
/// Owner -> AppShell (Desktop / Tablet ERP)
/// Staff -> StaffAttendanceScreen (Mobile-first Staff Portal)
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
      // Auto-check for updates only on Android mobile devices (Staff App).
      // On Windows Desktop ERP, cashier/owner workflow is never interrupted at login.
      if (!kIsWeb && Platform.isAndroid) {
        AppUpdateService.instance.checkForUpdate(context, autoShowDialog: true);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final a = context.watch<AuthController>();
    if (a.loading) {
      return const Scaffold(
        backgroundColor: TekColors.bgMain,
        body: Center(
          child: CircularProgressIndicator(
            color: TekColors.primary,
          ),
        ),
      );
    }

    // Role-based authorization gate:
    // If staff session is detected, route strictly to StaffAttendanceScreen.
    if (a.isStaffLoggedIn || (a.signedIn && a.role == Role.staff)) {
      return StaffAttendanceScreen(
        shopId: a.shopId,
        staffId: a.uid,
        staffName: a.name,
      );
    }

    // Unauthorized staff members are completely blocked from entering AppShell.
    // Only verified owners with valid owner credentials can access AppShell.
    if (a.signedIn && a.isOwner) {
      return const AppShell();
    }

    return const LoginScreen();
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

  int _mode = 1; // Default to Staff Login for the Staff Portal (0 = Owner, 1 = Staff)
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
      setState(() => _err = 'Shop ID നൽകുക (Please enter Shop ID)');
      return;
    }

    if (_mode == 1) {
      // -----------------------------------------------------------------------
      // STAFF LOGIN FLOW: Firebase Auth + Trusted Firestore RBAC
      // -----------------------------------------------------------------------
      final email = _email.text.trim().toLowerCase();
      final pass = _pass.text;
      if (email.isEmpty || pass.isEmpty) {
        setState(() => _err =
            'ഇമെയിലും പാസ്‌വേഡും നൽകുക (Please enter staff email and password)');
        return;
      }

      setState(() {
        _busy = true;
        _err = null;
      });

      UserCredential? cred;
      try {
        // 1. Authenticate credentials against existing Firebase Authentication
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
        debugPrint('Staff sign-in error: $e');
      }

      // 2. If online authentication succeeded, verify role and approval in Firestore
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
                  'ഈ സ്റ്റാഫ് അക്കൗണ്ട് "$shopId" ഷോപ്പിൽ രജിസ്റ്റർ ചെയ്തിട്ടില്ല.\n(Staff account is not registered under Shop ID "$shopId")';
            });
            return;
          }

          final userData = userDoc.data() ?? {};
          // Verify trusted role field
          if (userData['role'] != 'staff') {
            await FirebaseAuth.instance.signOut();
            setState(() {
              _busy = false;
              _err = 'ഈ അക്കൗണ്ടിന് സ്റ്റാഫ് അനുമതിയില്ല (Not authorized as staff role)';
            });
            return;
          }

          // Owner Authorization & Active Status Check
          final bool isApproved =
              userData['approved'] != false && userData['active'] != false;
          if (!isApproved) {
            await FirebaseAuth.instance.signOut();
            setState(() {
              _busy = false;
              _err =
                  'ഈ സ്റ്റാഫ് അക്കൗണ്ട് പ്രവർത്തനരഹിതമാണ് അല്ലെങ്കിൽ ഉടമസ്ഥന്റെ അനുമതിയില്ല.\n(Staff account is deactivated or not approved by Shop Owner)';
            });
            return;
          }

          // Successfully authenticated & verified from trusted Firestore data
          await Db.settings.put('shop_id', shopId);
          await Db.settings.put('staff_logged_in', 'true');
          await Db.settings.put('staff_logged_id', uid);
          await Db.settings
              .put('staff_logged_name', '${userData['name'] ?? email}');
          await Db.settings.put('staff_logged_email', email);
          await Db.settings.put('auth_role', 'staff');

          // Cache verified email to local owner-approved staff list
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
          // If Firestore read fails due to offline/network glitch but Auth token is valid:
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

      // 3. Offline Verification: Validate against cached owner-approved staff records
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
            'ഈ ഇമെയിലിന് ഉടമസ്ഥന്റെ അനുമതിയില്ല അല്ലെങ്കിൽ ഇന്റർനെറ്റ് ഇല്ല.\n(Email is not approved by Shop Owner or device is offline)';
      });
      return;
    }

    // -------------------------------------------------------------------------
    // OWNER LOGIN FLOW
    // -------------------------------------------------------------------------
    if (_email.text.trim().isEmpty || _pass.text.isEmpty) {
      setState(() => _err = 'എല്ലാ വിവരങ്ങളും നൽകുക (Please fill in all fields)');
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
        return 'ഇമെയിൽ അല്ലെങ്കിൽ പാസ്‌വേഡ് തെറ്റാണ്, അല്ലെങ്കിൽ ഉടമസ്ഥൻ രജിസ്റ്റർ ചെയ്തിട്ടില്ല.\n(Invalid email/password, or account not yet registered by Owner)';
      case 'network-request-failed':
        return 'ഇന്റർനെറ്റ് കണക്ഷൻ ലഭ്യമല്ല (No internet connection)';
      case 'email-already-in-use':
        return 'ഈ ഇമെയിൽ ഇതിനകം ഉപയോഗത്തിലാണ് (Email already in use)';
      case 'weak-password':
        return 'പാസ്‌വേഡിൽ കുറഞ്ഞത് 6 അക്ഷരങ്ങൾ വേണം (Password must be at least 6 characters)';
      default:
        return e.message ?? e.code;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: TekColors.bgMain,
      body: Stack(
        children: [
          // Background ambient gradient glow
          Positioned(
            top: -100,
            left: MediaQuery.of(context).size.width / 2 - 200,
            child: Container(
              width: 400,
              height: 400,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: RadialGradient(
                  colors: [
                    TekColors.primary.withValues(alpha: 0.18),
                    Colors.transparent,
                  ],
                ),
              ),
            ),
          ),
          Positioned(
            bottom: -80,
            right: -80,
            child: Container(
              width: 320,
              height: 320,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: RadialGradient(
                  colors: [
                    TekColors.secondary.withValues(alpha: 0.12),
                    Colors.transparent,
                  ],
                ),
              ),
            ),
          ),

          // Main Login Content
          SafeArea(
            child: Center(
              child: SingleChildScrollView(
                physics: const BouncingScrollPhysics(),
                padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 420),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      // Brand Header & Avatar
                      Container(
                        width: 76,
                        height: 76,
                        decoration: BoxDecoration(
                          gradient: TekColors.heroGradient,
                          borderRadius: BorderRadius.circular(24),
                          border: Border.all(
                            color: TekColors.electricCyan.withValues(alpha: 0.4),
                            width: 1.5,
                          ),
                          boxShadow: [
                            BoxShadow(
                              color: TekColors.primaryBlue.withValues(alpha: 0.35),
                              blurRadius: 20,
                              offset: const Offset(0, 6),
                            ),
                          ],
                        ),
                        child: const Icon(
                          Icons.bolt_rounded,
                          size: 44,
                          color: Colors.white,
                        ),
                      ),
                      const SizedBox(height: 16),
                      Text(
                        'TEKFIX ERP',
                        style: TekTypography.titleLarge.copyWith(
                          fontSize: 26,
                          fontWeight: FontWeight.w900,
                          letterSpacing: 1.0,
                          color: TekColors.textPrimary,
                        ),
                      ),
                      const SizedBox(height: 2),
                      const Text(
                        'Tekfix Digital • Irumbuzhi, Kerala',
                        style: TextStyle(
                          color: TekColors.electricCyan,
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          letterSpacing: 0.4,
                        ),
                      ),
                      const SizedBox(height: 4),
                      const Text(
                        '"Smarter Business. Greater Growth."',
                        style: TextStyle(
                          color: TekColors.textSecondary,
                          fontSize: 12.5,
                          fontStyle: FontStyle.italic,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        _mode == 1
                            ? 'ജീവനക്കാരുടെ പോർട്ടൽ • Staff Portal'
                            : (_create
                                ? 'ഷോപ്പ് ഉടമ രജിസ്ട്രേഷൻ • Owner Setup'
                                : 'ഷോപ്പ് ഉടമ ലോഗിൻ • Owner Sign-in'),
                        textAlign: TextAlign.center,
                        style: TekTypography.bodySecondary.copyWith(
                          color: TekColors.textSecondary,
                          fontSize: 12.5,
                        ),
                      ),
                      const SizedBox(height: 22),

                      // Mode Switcher (Staff vs Owner)
                      Container(
                        padding: const EdgeInsets.all(4),
                        decoration: BoxDecoration(
                          color: TekColors.bgSecondary,
                          borderRadius: BorderRadius.circular(16),
                          border: Border.all(color: TekColors.border, width: 1.2),
                        ),
                        child: Row(
                          children: [
                            Expanded(
                              child: _buildModeTab(
                                index: 1,
                                icon: Icons.badge_rounded,
                                label: 'Staff Portal',
                                malayalamLabel: 'സ്റ്റാഫ്',
                              ),
                            ),
                            Expanded(
                              child: _buildModeTab(
                                index: 0,
                                icon: Icons.admin_panel_settings_rounded,
                                label: 'Owner Sign In',
                                malayalamLabel: 'ഷോപ്പ് ഉടമ',
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 20),

                      // Card Form Container
                      Container(
                        padding: const EdgeInsets.all(24),
                        decoration: BoxDecoration(
                          color: TekColors.bgCard,
                          borderRadius: BorderRadius.circular(24),
                          border: Border.all(color: TekColors.border, width: 1.2),
                          boxShadow: TekColors.cardShadow,
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            // Shop ID Input
                            _buildInputLabel(
                              'Shop ID',
                              'ഷോപ്പ് കോഡ്',
                              Icons.storefront_rounded,
                            ),
                            const SizedBox(height: 6),
                            TextField(
                              controller: _shop,
                              textInputAction: TextInputAction.next,
                              style: const TextStyle(
                                color: TekColors.textPrimary,
                                fontWeight: FontWeight.w600,
                              ),
                              decoration: const InputDecoration(
                                hintText: 'ഉദാ: tekfix01',
                                prefixIcon: Icon(
                                  Icons.store_mall_directory_rounded,
                                  color: TekColors.secondary,
                                  size: 20,
                                ),
                              ),
                            ),
                            const SizedBox(height: 16),

                            // Owner Name Input (Only on Owner Create)
                            if (_mode == 0 && _create) ...[
                              _buildInputLabel(
                                'Owner Name',
                                'ഉടമസ്ഥന്റെ പേര്',
                                Icons.person_rounded,
                              ),
                              const SizedBox(height: 6),
                              TextField(
                                controller: _name,
                                textInputAction: TextInputAction.next,
                                style: const TextStyle(
                                  color: TekColors.textPrimary,
                                  fontWeight: FontWeight.w600,
                                ),
                                decoration: const InputDecoration(
                                  hintText: 'ഉടമസ്ഥന്റെ പേര് നൽകുക',
                                  prefixIcon: Icon(
                                    Icons.person_outline_rounded,
                                    color: TekColors.secondary,
                                    size: 20,
                                  ),
                                ),
                              ),
                              const SizedBox(height: 16),
                            ],

                            // Email Address Input
                            _buildInputLabel(
                              _mode == 1 ? 'Staff Email' : 'Owner Email',
                              _mode == 1 ? 'അംഗീകൃത ഇമെയിൽ' : 'ഇമെയിൽ വിലാസം',
                              Icons.alternate_email_rounded,
                            ),
                            const SizedBox(height: 6),
                            TextField(
                              controller: _email,
                              keyboardType: TextInputType.emailAddress,
                              textInputAction: TextInputAction.next,
                              style: const TextStyle(
                                color: TekColors.textPrimary,
                                fontWeight: FontWeight.w600,
                              ),
                              decoration: InputDecoration(
                                hintText: _mode == 1
                                    ? 'staff@tekfix.com'
                                    : 'owner@tekfix.com',
                                prefixIcon: const Icon(
                                  Icons.mail_outline_rounded,
                                  color: TekColors.secondary,
                                  size: 20,
                                ),
                              ),
                            ),
                            const SizedBox(height: 16),

                            // Password Input
                            _buildInputLabel(
                              'Password',
                              'പാസ്‌വേഡ്',
                              Icons.lock_outline_rounded,
                            ),
                            const SizedBox(height: 6),
                            TextField(
                              controller: _pass,
                              obscureText: _hide,
                              onSubmitted: (_) => _go(),
                              style: const TextStyle(
                                color: TekColors.textPrimary,
                                fontWeight: FontWeight.w600,
                              ),
                              decoration: InputDecoration(
                                hintText: '••••••••',
                                prefixIcon: const Icon(
                                  Icons.lock_rounded,
                                  color: TekColors.secondary,
                                  size: 20,
                                ),
                                suffixIcon: IconButton(
                                  icon: Icon(
                                    _hide
                                        ? Icons.visibility_outlined
                                        : Icons.visibility_off_outlined,
                                    color: TekColors.textSecondary,
                                    size: 20,
                                  ),
                                  onPressed: () =>
                                      setState(() => _hide = !_hide),
                                ),
                              ),
                            ),

                            // Error Message Banner
                            if (_err != null) ...[
                              const SizedBox(height: 16),
                              Container(
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 14, vertical: 12),
                                decoration: BoxDecoration(
                                  color: TekColors.error.withValues(alpha: 0.12),
                                  border: Border.all(
                                    color: TekColors.error.withValues(alpha: 0.5),
                                    width: 1.2,
                                  ),
                                  borderRadius: BorderRadius.circular(12),
                                ),
                                child: Row(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    const Icon(
                                      Icons.error_outline_rounded,
                                      color: TekColors.error,
                                      size: 20,
                                    ),
                                    const SizedBox(width: 10),
                                    Expanded(
                                      child: Text(
                                        _err!,
                                        style: const TextStyle(
                                          color: Color(0xFFFECDD3),
                                          fontSize: 12.5,
                                          height: 1.35,
                                          fontWeight: FontWeight.w500,
                                          fontFamilyFallback:
                                              TekTypography.malayalamFallback,
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ],

                            const SizedBox(height: 22),

                            // Submit Action Button
                            GestureDetector(
                              behavior: HitTestBehavior.opaque,
                              onTap: _busy ? null : _go,
                              child: Container(
                                height: 50,
                                decoration: BoxDecoration(
                                  gradient: _busy
                                      ? null
                                      : TekColors.primaryGradient,
                                  color: _busy ? TekColors.primaryDark : null,
                                  borderRadius: BorderRadius.circular(14),
                                  boxShadow: _busy ? null : TekColors.primaryGlow,
                                ),
                                child: Center(
                                  child: _busy
                                      ? const SizedBox(
                                          width: 22,
                                          height: 22,
                                          child: CircularProgressIndicator(
                                            strokeWidth: 2.2,
                                            color: Colors.white,
                                          ),
                                        )
                                      : Row(
                                          mainAxisAlignment:
                                              MainAxisAlignment.center,
                                          children: [
                                            Flexible(
                                              child: Text(
                                                _mode == 1
                                                    ? 'പ്രവേശിക്കുക (Staff Login)'
                                                    : (_create
                                                        ? 'ഷോപ്പ് രജിസ്റ്റർ ചെയ്യുക (Create)'
                                                        : 'പ്രവേശിക്കുക (Sign In)'),
                                                maxLines: 1,
                                                overflow: TextOverflow.ellipsis,
                                                style: const TextStyle(
                                                  color: Colors.white,
                                                  fontSize: 14.5,
                                                  fontWeight: FontWeight.bold,
                                                  letterSpacing: 0.3,
                                                  fontFamilyFallback:
                                                      TekTypography.malayalamFallback,
                                                ),
                                              ),
                                            ),
                                            const SizedBox(width: 8),
                                            const Icon(
                                              Icons.arrow_forward_rounded,
                                              color: Colors.white,
                                              size: 18,
                                            ),
                                          ],
                                        ),
                                ),
                              ),
                            ),

                            // Owner mode alternate registration toggle
                            if (_mode == 0) ...[
                              const SizedBox(height: 14),
                              TextButton(
                                onPressed: () => setState(() {
                                  _create = !_create;
                                  _err = null;
                                }),
                                child: Text(
                                  _create
                                      ? 'നിലവിൽ അക്കൗണ്ട് ഉണ്ടോ? Sign in'
                                      : 'ആദ്യമായാണോ? Create Shop Owner Account',
                                  textAlign: TextAlign.center,
                                  style: const TextStyle(
                                    color: TekColors.secondary,
                                    fontSize: 12.5,
                                    fontFamilyFallback:
                                        TekTypography.malayalamFallback,
                                  ),
                                ),
                              ),
                            ],
                          ],
                        ),
                      ),

                      const SizedBox(height: 20),

                      // Security & Role Reassurance Badge
                      Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          const Icon(
                            Icons.shield_outlined,
                            size: 14,
                            color: TekColors.textMuted,
                          ),
                          const SizedBox(width: 6),
                          Flexible(
                            child: Text(
                              _mode == 1
                                  ? 'Role-Based Authorization • Offline-Ready'
                                  : 'Shop Owner Administrative Access',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontSize: 11,
                                color: TekColors.textMuted,
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      Text(
                        'TEKFIX DIGITAL v1.0.2',
                        style: TextStyle(
                          fontSize: 10.5,
                          color: TekColors.textMuted.withValues(alpha: 0.7),
                          letterSpacing: 0.8,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildModeTab({
    required int index,
    required IconData icon,
    required String label,
    required String malayalamLabel,
  }) {
    final isSelected = _mode == index;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () {
        HapticFeedback.selectionClick();
        setState(() {
          _mode = index;
          _err = null;
        });
      },
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeOutCubic,
        padding: const EdgeInsets.symmetric(vertical: 10),
        decoration: BoxDecoration(
          gradient: isSelected ? TekColors.primaryGradient : null,
          color: isSelected ? null : Colors.transparent,
          borderRadius: BorderRadius.circular(12),
          boxShadow: isSelected ? TekColors.primaryGlow : null,
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              icon,
              size: 18,
              color: isSelected ? Colors.white : TekColors.textSecondary,
            ),
            const SizedBox(width: 6),
            Flexible(
              child: Text(
                '$malayalamLabel ($label)',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: isSelected ? FontWeight.bold : FontWeight.w500,
                  color: isSelected ? Colors.white : TekColors.textSecondary,
                  fontFamilyFallback: TekTypography.malayalamFallback,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildInputLabel(String en, String ml, IconData icon) {
    return Row(
      children: [
        Icon(icon, size: 14, color: TekColors.secondary),
        const SizedBox(width: 6),
        Text(
          ml,
          style: const TextStyle(
            color: TekColors.textPrimary,
            fontSize: 12.5,
            fontWeight: FontWeight.w600,
            fontFamilyFallback: TekTypography.malayalamFallback,
          ),
        ),
        const SizedBox(width: 4),
        Text(
          '($en)',
          style: const TextStyle(
            color: TekColors.textSecondary,
            fontSize: 11.5,
          ),
        ),
      ],
    );
  }
}
