# TEKFIX ERP — ANDROID MOBILE LOGOUT BUTTON FIX & PHYSICAL UAT VERIFICATION REPORT
**Phase:** Urgent Bug Fix — Android Mobile Logout Visibility & Session Lifecycle  
**Date:** November 14, 2026  
**Target Package:** `com.example.tekfix_pos.staging`  
**Test Device:** Physical TECNO Spark Go (TECNO_KM9), Android 14 (API 34, Resolution: 1080x2400)  
**Branch:** `phase-16-4-7-4-verification`  
**Status:** **100% VERIFIED & PASSED**

---

## 1. Executive Summary

A critical UI regression was reported where the **Logout button was not accessible on Android mobile screens** in the Staging application.

### Root Cause Analysis:
1. **Responsive Shell Architecture:** In `lib/main.dart`, wide/desktop screens (width ≥ 900dp) render `TekTopBar` at the top of the window, which houses the user profile avatar and the logout menu item.
2. **Mobile Screen Omission:** On Android phone screens (width < 900dp), the layout switches to `_mobileLayout`. In mobile layout, `TekTopBar` is intentionally omitted to conserve vertical screen space for POS operations, relying instead on a bottom navigation bar with 5 tabs:
   - Tab 1: Home (`[0,2086][216,2296]`)
   - Tab 2: Sale (`[216,2086][432,2296]`)
   - Tab 3: Daily (`[432,2086][648,2296]`)
   - Tab 4: Staff (`[648,2086][864,2296]`)
   - Tab 5: More (`[864,2086][1080,2296]`)
3. **Missing Navigation Anchors:** The `MoreView` (Tab 5) previously listed only ERP module cards without an Owner Profile card or sign-out trigger. Additionally, `SettingsView` (module 25) did not have a dedicated session termination tile. Consequently, on mobile devices, an authenticated Owner had no UI path to sign out.

---

## 2. Implementation Summary

All modifications were confined strictly to `lib/main.dart` with zero disruption to backup branch `wip-backup-20261112`, commit `050c29d`, or underlying Hive/Firestore business data.

### 2.1. Confirmation Dialog (`_showOwnerSignOutDialog`)
- **Bilingual Dark Dialog:** Matches the TekFix dark design system (`TekColors.bgCard`, rounded corners).
- **Clear Prompts:**
  - Title: `ലോഗൗട്ട് ചെയ്യണോ?` with red logout icon.
  - Body: `സെഷൻ അവസാനിപ്പിച്ച് ലോഗിൻ സ്‌ക്രീനിലേക്ക് മടങ്ങാൻ ആഗ്രഹിക്കുന്നുവോ?`
  - Actions: `Cancel (റദ്ദാക്കുക)` and red `Sign Out (ലോഗൗട്ട്)` filled button.
- **Fail-Safe Route Clean-up:** On confirmation, pops all intermediate routes to root (`Navigator.of(context).popUntil((route) => route.isFirst)`) before executing `AuthController.instance.signOut()`.

### 2.2. Top Owner Profile Card in `MoreView`
- **Location:** Top of `MoreView` (Tab 5), immediately visible upon opening.
- **Role-Guarded:** Rendered conditionally under `if (isOwner) ...`.
- **Identity Elements:**
  - Amber `OWNER` shield badge.
  - Active Shop Name (`Db.setting('shop_name', 'TEKFIX')`).
  - Owner display name (`auth.name`).
  - Owner email (`staging-owner@tekfix.internal`).
  - Dedicated Logout `IconButton` (`Icons.logout_rounded`, tooltip `'Sign Out (ലോഗൗട്ട്)'`, color `0xFFEF4444`).

### 2.3. Bottom Sign Out Action Card in `MoreView`
- **Location:** Bottom of `MoreView` list, following all ERP modules.
- **Design:** Distinctive red-tinted card (`Color(0xFFEF4444).withAlpha(18)`), featuring:
  - Title: `ലോഗൗട്ട് ചെയ്യുക (Sign Out)`
  - Subtitle: `സെഷൻ അവസാനിപ്പിച്ച് ലോഗിൻ സ്‌ക്രീനിലേക്ക് മടങ്ങുക`
  - Tapping opens `_showOwnerSignOutDialog`.

### 2.4. Account & Session Section in `SettingsView`
- Added section `അക്കൗണ്ട് & സെഷൻ (Account & Session)` in `SettingsView` with a red sign-out tile hooking into `_showOwnerSignOutDialog`.

---

## 3. Automated Test Verification

Two test suites were executed to verify authentication isolation and mobile logout widget rendering:

### 3.1. Mobile Logout Unit Tests (`test/owner_auth_mobile_logout_test.dart`)
Command:
```powershell
flutter test test/owner_auth_mobile_logout_test.dart --dart-define=TEKFIX_UAT=true
```
**Results: 9/9 Tests PASSED (0 failures)**
- `1. Initial unauthenticated state defaults to signed out` — **PASS**
- `2. Successful owner sign-in sets signed-in state and persists to Hive` — **PASS**
- `3. signOut clears session, resets role to staff, and persists staging_owner_signed_in = 'false'` — **PASS**
- `4. init() respects stored staging_owner_signed_in = 'false'` — **PASS**
- `5. init() restores session only when staging_owner_signed_in = 'true'` — **PASS**
- `6. Staging password verification rejects wrong password` — **PASS**
- `7. Staging recovery PIN resets password and updates hash` — **PASS**
- `8. Mobile MoreView renders Owner Profile Card and Logout triggers when authenticated as owner` — **PASS**
- `9. MoreView does NOT render Owner Profile Card or Logout triggers for non-owners` — **PASS**

### 3.2. Firebase Fail-Closed Unit Tests (`test/firebase_isolation_failclosed_test.dart`)
Command:
```powershell
flutter test test/firebase_isolation_failclosed_test.dart
```
**Results: 8/8 Tests PASSED (0 failures)**

---

## 4. Physical Device Verification (TECNO Android 14)

### Device Details:
- **Model:** TECNO Spark Go (TECNO_KM9)
- **Serial:** `1536731587023055`
- **OS:** Android 14 (API 34)
- **Display:** 1080 x 2400 (Portrait)

### 4.1. Build & Installation
```powershell
flutter build apk --flavor staging -t lib/main.dart --dart-define=TEKFIX_ENV=staging_uat --dart-define=TEKFIX_UAT=true
adb install -r "D:\tekfix_pos\build\app\outputs\flutter-apk\app-staging-release.apk"
```
**Result:** Built `app-staging-release.apk` (74.6 MB) and installed successfully (`Success`).

### 4.2. Runtime UI Navigation & Logout Verification
1. **Navigate to More Tab:**
   - Coordinates: `(972, 2191)` (Tab 5 of 5, bounds: `[864,2086][1080,2296]`).
   - UI dump verified `MoreView` active with top Owner Profile Card (`[42,297][1038,586]`).
2. **Verify Logout Button Visibility:**
   - Button bounds: `[867,357][993,483]` (Center: `930, 420`).
   - Content description: `Sign Out (ലോഗൗട്ട്)`.
   - Status: **VISIBLE & CLICKABLE**.
3. **Trigger Logout Confirmation Dialog:**
   - Tapped `(930, 420)`.
   - UI dump verified dialog opened with:
     - `ലോഗൗട്ട് ചെയ്യണോ?`
     - `സെഷൻ അവസാനിപ്പിച്ച് ലോഗിൻ സ്‌ക്രീനിലേക്ക് മടങ്ങാൻ ആഗ്രഹിക്കുന്നുവോ?`
     - Action button `Sign Out (ലോഗൗട്ട്)` at bounds `[418,1371][912,1497]` (Center: `665, 1434`).
4. **Confirm Sign Out:**
   - Tapped `(665, 1434)`.
   - UI dump verified immediate transition to `LoginScreen` (`com.example.tekfix_pos.staging`):
     - `ഷോപ്പ് ഉടമ ലോഗിൻ • Owner Sign-in`
     - `Shop ID`: `shop_staging_001`
     - `Owner Email`: `staging-owner@tekfix.internal`
     - `Password`: Empty

### 4.3. Cold Restart & Persistence Verification
1. Force-stopped app:
   ```powershell
   adb shell am force-stop com.example.tekfix_pos.staging
   ```
2. Relaunched cold from Android Launcher:
   ```powershell
   adb shell monkey -p com.example.tekfix_pos.staging -c android.intent.category.LAUNCHER 1
   ```
3. UI dump verified:
   - App opened directly to `LoginScreen` (unauthenticated).
   - Session was NOT restored.
   - Proves `staging_owner_signed_in = 'false'` in Hive storage persisted across process termination.

### 4.4. Re-Login Verification
1. Entered Owner Password `Staging@TekFix2026`.
2. Tapped `പ്രവേശിക്കുക (Sign In)` at `(540, 1212)`.
3. UI dump verified:
   - Returned immediately to Dashboard (`Home - Tab 1 of 5`, `Sale - Tab 2 of 5`, etc.).
   - Switched to More Tab (`(972, 2191)`); Owner Profile Card and `Sign Out (ലോഗൗട്ട്)` button (`[867,357][993,483]`) correctly re-rendered.

---

## 5. Security & Isolation Invariants

| Invariant | Status | Evidence |
|---|---|---|
| **Production Firebase Block** | **PRESERVED** | `enforceProductionIsolation` active; production app ID `tekfix-45b38` strictly blocked. |
| **Backup Branch Protection** | **PRESERVED** | `wip-backup-20261112` / `050c29d` untouched. |
| **Staff Isolation** | **PRESERVED** | Staff portal disabled in Staging UAT; Owner profile card guarded by `isOwner`. |
| **Fail-Closed Session** | **PRESERVED** | `init()` checks `staging_owner_signed_in == 'true'`; resets to `none` on sign out. |
| **Business Data Integrity** | **PRESERVED** | Hive sales, repair records, and cash balances untouched. |

---

## 6. Conclusion
The missing Logout button on Android mobile screens has been fully diagnosed, cleanly resolved in `lib/main.dart`, and physically proven through end-to-end automated UI interaction, cold restart, and re-login on the connected TECNO Android 14 device.

