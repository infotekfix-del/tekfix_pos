# PHASE 15.4.5 — PHYSICAL ANDROID UAT RUNTIME CRASH INVESTIGATION & FIX REPORT

**Date:** 2026-11-11  
**Workspace:** `D:\tekfix_pos`  
**Application:** Single Unified Flutter Application (`lib/main.dart`)  
**Staging Target:** Supabase Mumbai (`mwhsvidbrfkryuiwhnev` - `ap-south-1`)  
**Production Firebase:** `tekfix-45b38` (**STRICTLY UNTOUCHED — 0 Reads, 0 Writes, 0 Auth, ₹0.00 Cost**)

---

## 1. EXECUTIVE SUMMARY & REAL ROOT EXCEPTION CAPTURE

Following the successful resolution of the login authentication flow in Phase 15.4.3 and APK delivery in Phase 15.4.4, physical testing on an Android device observed a crash screen with the Malayalam message:
> **ഒരു തകരാർ സംഭവിച്ചു (An Error Occurred)**  
> Visible stack trace snippet: `MultiChildRenderObjectElement`, `ComponentElement.performRebuild`, `Flutter framework`  
> Top banner: `⚠️ STAGING UAT MODE • PROD FIREBASE BLOCKED • SUPABASE ap-south-1 (mwhsvidbrfkryuiwhnev)`

### Root Cause Analysis:

Two distinct runtime exceptions were diagnosed and isolated:

1. **Root Cause #1 — Unguarded Firebase Calls inside `AttendanceService` on Dashboard Rebuild:**
   - **Exception Type:** `FirebaseException`
   - **Message:** `[core/no-app] No Firebase App '[DEFAULT]' has been created - call Firebase.initializeApp()`
   - **Origin:** `lib/ui/dashboard/dashboard_screen.dart:240` and `line 496` (`TekDashboardContent` / `HomeView()`), as well as `_AppShellPendingBadgeState` in `lib/main.dart:1215`.
   - **Mechanism:** In isolated staging UAT mode, production Firebase initialization is deliberately bypassed (`Firebase.apps.isEmpty == true`). When `AuthGate` authenticated the staging owner (`staging-owner@tekfix.internal`) and transitioned from `LoginScreen` to `AppShell`, `AppShell` immediately mounted `TekDashboardContent`. Inside `TekDashboardContent`, Flutter evaluated `AttendanceService.instance.streamPendingApprovals(auth.shopId)`. Because `AttendanceService` had no UAT guards, it unconditionally invoked `FirebaseFirestore.instance.collection('shops').doc(shopId)...`, throwing `[core/no-app]` during `Element.performRebuild` and triggering Flutter's `ErrorWidget.builder`.

2. **Root Cause #2 — Single-Subscription Stream Conflict (`Bad state: Stream has already been listened to`):**
   - **Exception Type:** `StateError`
   - **Message:** `Bad state: Stream has already been listened to.`
   - **Origin:** `lib/attendance/staff_attendance_screen.dart:612` (bottom navigation unread badge) and `line 903` (top app bar alerts icon).
   - **Mechanism:** When non-owner staff accounts or fallback views mounted, `StaffAttendanceScreen` attached two simultaneous `StreamBuilder<int>` listeners to `_unreadCountStream`. In UAT mode, `NotificationService.instance.streamUnreadCount` and `streamNotifications` returned `Stream.value(...)`, which in Dart is a **single-subscription stream**. When the second widget subscribed during the initial frame layout, Dart threw `Bad state: Stream has already been listened to`, which bubbled into `MultiChildRenderObjectElement.mount`.

---

## 2. ARCHITECTURAL REMEDIATIONS & ISOLATION HARDENING

### Remediation 1: Enhanced Global Diagnostics & Custom On-Screen Error Widget
Updated `lib/main.dart` with structured diagnostics and actionable recovery controls:
- **`FlutterError.onError`**: Captures and logs `[TekFix RootException Type]`, `[TekFix RootException Message]`, and `[TekFix RootException Origin]`.
- **`PlatformDispatcher.instance.onError`** & **`runZonedGuarded`**: Log uncaught async errors with exact runtime type, message, and stack trace without process termination.
- **Enhanced `ErrorWidget.builder`**: If any widget tree construction or rebuild fails in the future, it renders a high-visibility diagnostic screen featuring:
  - Exact Exception Type badge (e.g. `[FirebaseException]`, `[StateError]`)
  - Exception Summary text with exact error message
  - Originating Widget / Library context
  - Scrollable monospace stack trace container
  - Action buttons: **"റീലോഡ് ചെയ്യുക (Reload App)"** and **"ലോഗിൻ സ്‌ക്രീൻ (Return to Login)"** to clear stuck session state.

### Remediation 2: Zero-Firebase Guards in `AttendanceService`
Hardened all methods and streams in `lib/attendance/attendance_service.dart` with `DefaultFirebaseOptions.isUatMode || Firebase.apps.isEmpty`:
- `streamPendingApprovals`: Returns `Stream.value(<AttendanceRecord>[]).asBroadcastStream()`
- `streamTodayAttendance`: Returns `Stream.value(getCachedTodayAttendance(staffId)).asBroadcastStream()`
- `streamStaffAttendanceHistory`: Returns `Stream.value(<AttendanceRecord>[]).asBroadcastStream()`
- `streamAllTodayAttendance`: Returns `Stream.value(<AttendanceRecord>[]).asBroadcastStream()`
- `streamMonthAttendance`: Returns `Stream.value(<AttendanceRecord>[]).asBroadcastStream()`
- `recordAttendance`: Offline local Hive caching with synthetic record return in UAT mode.
- `saveShiftConfig`, `autoCloseForgottenCheckOut`, `syncOfflineQueue`, `approveAttendance`, `adjustAttendance`, `rejectAttendance`, `ownerManualEntry`, `bulkApprovePending`, `_logAudit`: Guaranteed no-op when Firebase is uninitialized.
- `FirebaseAuth.instance.currentUser?.uid`: Guarded by `(Firebase.apps.isNotEmpty && !DefaultFirebaseOptions.isUatMode)`.

### Remediation 3: Multi-Subscription Broadcast Streams across Core Services
- In `lib/notifications/notification_service.dart`: Added `.asBroadcastStream()` to both `streamNotifications` and `streamUnreadCount`.
- In `lib/attendance/staff_attendance_screen.dart`: Applied `.asBroadcastStream()` to `_attendanceStream`, `_unreadCountStream`, and `_historyStream`.
- In `lib/pos/pos_service.dart`: Added `DefaultFirebaseOptions.isUatMode` check and `.asBroadcastStream()` to `streamCatalogItems`.

### Remediation 4: Zero-Firebase Guards across Ancillary Services
- In `lib/pos/daily_register_service.dart`: Guarded `getSalesForDate`, `getOpeningCashForDate`, `closeRegister`, and `getClosedRegister` against Firestore access in UAT mode.
- In `lib/inventory/consumables_service.dart`: Guarded Firestore item stock synchronization in UAT mode.
- In `lib/orders/staff_orders_screen.dart`: Guarded `FirebaseAuth.instance.currentUser?.uid` access.
- In `lib/ui/dashboard/dashboard_screen.dart`: Added defense-in-depth UAT checks on dashboard pending approval streams.
- In `lib/ui/dashboard/weather_card.dart`: Bypassed external HTTP API calls during UAT and test execution.

---

## 3. AUTOMATED REGRESSION & ISOLATION VERIFICATION

All tests passed with zero regressions:

### 1. `test/dashboard_uat_isolation_test.dart` (10/10 Passed)
Command: `flutter test test/dashboard_uat_isolation_test.dart --dart-define=TEKFIX_UAT=true`
- `✓ 1. UAT mode detection or zero-Firebase fallback active`
- `✓ 2. AttendanceService streamPendingApprovals returns safe empty stream in UAT mode`
- `✓ 3. AttendanceService streamTodayAttendance returns null/cached in UAT mode without throwing`
- `✓ 4. AttendanceService streamAllTodayAttendance returns empty stream in UAT mode`
- `✓ 5. AttendanceService streamMonthAttendance returns empty stream in UAT mode`
- `✓ 6. PosService streamCatalogItems returns local catalog in UAT mode without Firestore calls`
- `✓ 7. DailyRegisterService reads sales, opening cash, and closed register locally in UAT mode`
- `✓ 8. NotificationService streamUnreadCount is a multi-subscription broadcast stream`
- `✓ 9. AttendanceService streams are multi-subscription broadcast streams`
- `✓ 10. AttendanceService recordAttendance and saveShiftConfig operate cleanly in UAT mode`

### 2. `test/staging_password_auth_test.dart` (6/6 Passed)
Command: `flutter test test/staging_password_auth_test.dart --dart-define=TEKFIX_UAT=true`
- `✓ 1. Default staging password verifies against default hash`
- `✓ 2. Password reset fails closed on invalid master recovery PIN`
- `✓ 3. Password reset fails closed on short password (< 6 chars)`
- `✓ 4. Password reset succeeds with PIN 9999 and updates active password`
- `✓ 5. Staging UAT mode sign-in succeeds with valid credentials and updates session`
- `✓ 6. Regression: Zero Firebase access during UAT Sign-In with Firebase uninitialized`

### 3. Static Analysis (`flutter analyze lib/`)
- Total issues in `lib/`: **0 errors**

---

## 4. VERIFIED STAGING APK DELIVERY

The updated staging release APK was built via Gradle `assembleStagingRelease` and copied to the delivery folder:

| Attribute | Specification / Verification Value |
|---|---|
| **Delivery Path** | `Output\staging_uat\app-staging-release.apk` |
| **Source Build Path** | `build\app\outputs\flutter-apk\app-staging-release.apk` |
| **Package Name** | `com.example.tekfix_pos.staging` |
| **Version Code** | `28` |
| **Version Name** | `1.0.28-staging` |
| **File Size** | `78,000,108 bytes (74.38 MB)` |
| **Build Timestamp** | `11-11-2026 13:36:55 IST` |
| **SHA-256 Checksum** | `2FA32E62CC87BC48173D9AA0EBB78326BD8C4110E4A2B0D6FA74F38ED65FE3D8` |

### Package Verification (via AAPT):
```text
package: name='com.example.tekfix_pos.staging' versionCode='28' versionName='1.0.28-staging'
platformBuildVersionName='16' platformBuildVersionCode='36' compileSdkVersion='36' compileSdkVersionCodename='16'
```

---

## 5. PHYSICAL DEVICE INSTALLATION & TESTING INSTRUCTIONS

### Step 1: Install Updated Staging APK
Connect the Android test device via USB with USB debugging enabled, or copy the APK to the device:
```powershell
adb install -r D:\tekfix_pos\Output\staging_uat\app-staging-release.apk
```

### Step 2: Verify Checksum Prior to Install
```powershell
Get-FileHash -Path "D:\tekfix_pos\Output\staging_uat\app-staging-release.apk" -Algorithm SHA256
# Expected: 2FA32E62CC87BC48173D9AA0EBB78326BD8C4110E4A2B0D6FA74F38ED65FE3D8
```

### Step 3: Owner Sign-In Verification
1. Launch **TekFix ERP Staging**.
2. Verify red isolation banner at top:  
   `⚠️ STAGING UAT MODE • PROD FIREBASE BLOCKED • SUPABASE ap-south-1 (mwhsvidbrfkryuiwhnev)`
3. Enter credentials:
   - **Shop ID:** `shop_staging_001`
   - **Email:** `staging-owner@tekfix.internal`
   - **Password:** `Staging@TekFix2026`
4. Tap **പ്രവേശിക്കുക (Sign In)**.
5. **Expected Outcome:** The screen transitions cleanly into the **Owner Dashboard (`AppShell`)** without the red `ഒരു തകരാർ സംഭവിച്ചു` error screen. All stat cards, navigation tabs, quick actions, and recent activity render smoothly.

---

## 6. PRODUCTION ISOLATION AFFIRMATION

- **Production Firebase `tekfix-45b38`:** 100% UNTOUCHED.
- **Production Firestore Reads/Writes:** 0
- **Production Authentication Requests:** 0
- **Production Billing/Cost:** ₹0.00
- **Real Telecom Recharge Execution:** STRICTLY PROHIBITED & DISABLED
- **Unified Single Codebase:** Preserved via `lib/main.dart`.

