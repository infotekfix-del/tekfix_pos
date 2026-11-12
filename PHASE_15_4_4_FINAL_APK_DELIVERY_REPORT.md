# PHASE 15.4.4 — FINAL PHYSICAL UAT APK DELIVERY REPORT
**Date:** November 11, 2026  
**Environment:** Staging Physical UAT (`stagingUat`)  
**Target Backend:** Supabase Staging (`mwhsvidbrfkryuiwhnev` • Mumbai `ap-south-1`)  
**Production Isolation:** Production Firebase (`tekfix-45b38`) STRICTLY UNTOUCHED (0 reads, 0 writes, 0 auth requests, ₹0.00 billing)  
**Status:** **COMPILED, AUDITED, VERIFIED & DELIVERED**

---

## 1. Build Verification & Deliverables Summary

The staging release APK compilation has completed with exit code 0 using Flutter release toolchain and Gradle `assembleStagingRelease`.

| Parameter | Authoritative Verified Value |
| :--- | :--- |
| **Build Status** | **SUCCESS (Exit Code 0)** |
| **Flutter Build Command** | `flutter build apk --flavor staging --dart-define=TEKFIX_ENV=staging_uat --dart-define=TEKFIX_UAT=true --release` |
| **Original Build Artifact** | [`build/app/outputs/flutter-apk/app-staging-release.apk`](file:///d:/tekfix_pos/build/app/outputs/flutter-apk/app-staging-release.apk) |
| **Dedicated Delivery Location** | [`Output/staging_uat/app-staging-release.apk`](file:///d:/tekfix_pos/Output/staging_uat/app-staging-release.apk) |
| **Delivery Checksum File** | [`Output/staging_uat/app-staging-release.apk.sha256`](file:///d:/tekfix_pos/Output/staging_uat/app-staging-release.apk.sha256) |
| **Audited SHA-256 Checksum** | `4df384b19650ee280f0d2f49f30974c8496e71add2832da4ed4000328c3a003a` |
| **File Size** | `76,541,764 bytes` (73.0 MB) |
| **Build Timestamp** | November 11, 2026, 11:59:42 IST |

---

## 2. Package Identity & Android Manifest Audit

Extracted and verified using Android SDK `aapt dump badging`:
* **Package Name (Application ID):** `com.example.tekfix_pos.staging`
* **Version Code:** `28`
* **Version Name:** `1.0.28-staging`
* **Launchable Activity:** `com.example.tekfix_pos.MainActivity`
* **Target SDK Version:** `36` (Android 16 compatibility)
* **Minimum SDK Version:** `24` (Android 7.0+)
* **Supported Architectures (ABIs):** `arm64-v8a`, `armeabi-v7a`, `x86_64`

The `.staging` application ID suffix guarantees complete sandboxing on physical Android devices. It installs side-by-side with any production `com.example.tekfix_pos` package without overriding local production databases, keystores, or shared preferences.

---

## 3. Staging UAT Flags & Zero-Production Air-Gap Verification

1. **Compile-Time Flags (`--dart-define`):**
   - `TEKFIX_ENV=staging_uat`: Resolves `DefaultFirebaseOptions.currentEnvironment` to `TekFixEnvironment.stagingUat`.
   - `TEKFIX_UAT=true`: Sets compile-time constant `DefaultFirebaseOptions.isUatBuild = true`.
   - `DefaultFirebaseOptions.isUatMode` evaluates to `true`.
2. **Production Firebase Strict Air-Gap (`tekfix-45b38`):**
   - `Firebase.initializeApp()` is **100% bypassed** in `lib/main.dart` when running in UAT mode.
   - Any runtime attempt to initialize with `tekfix-45b38` triggers a hard `StateError` fail-closed security boundary.
   - Background update checks, presence beacons, and Firestore snapshot listeners across `AppUpdateService`, `OrderService`, `PresenceService`, `NotificationService`, `RepairService`, and `SmartInventorySearchEngine` are guarded with UAT early exits.
3. **No Production Credentials or Real Recharge Execution:**
   - Production telecom APIs and real distributor wallets are inactive.
   - Recharge operations route exclusively to isolated Supabase Edge Function `https://mwhsvidbrfkryuiwhnev.supabase.co/functions/v1/recharge-bridge` with synthetic integer paise balances.
   - Owner identity uses synthetic whitelisted identity `shop_staging_001` / `owner_staging_001`.

---

## 4. Staging Login & Authentication Invariants

* **Authentication Architecture:** Local salted SHA-256 (`TEKFIX_STAGING_SALT_2026_`) in `AuthController`.
* **Zero Firebase Auth Dependency:** The previous `[core/no-app] No Firebase App '[DEFAULT]' has been created` error is eliminated because `AuthController.signIn` no longer contacts `FirebaseAuth`.
* **Default Staging Credentials:**
  - **Shop ID:** `shop_staging_001`
  - **Owner Email:** `staging-owner@tekfix.internal` (or `owner@tekfix.com`)
  - **Initial Password:** `Staging@TekFix2026`
* **Emergency Password Reset:**
  - In-app **"Reset Staging Password"** dialog available on the login screen.
  - Requires Master Recovery PIN `9999`.
  - Sets new local salted hash without touching any remote cloud registry.

---

## 5. Physical Device Installation Instructions

1. **Connect Android Device to PC:**
   - Enable USB Debugging or File Transfer (MTP) mode on the Android device.
2. **Transfer the Delivery APK:**
   - File to copy: [`Output/staging_uat/app-staging-release.apk`](file:///d:/tekfix_pos/Output/staging_uat/app-staging-release.apk)
   - Alternatively, install via ADB:
     ```bash
     adb install -r D:\tekfix_pos\Output\staging_uat\app-staging-release.apk
     ```
3. **Verify Integrity on Device (Optional):**
   - Checksum: `4df384b19650ee280f0d2f49f30974c8496e71add2832da4ed4000328c3a003a`
4. **Launch Application:**
   - App icon: **TekFix ERP & POS** (Staging flavor)
   - Observe the top banner: `⚠️ STAGING UAT MODE • PROD FIREBASE BLOCKED • SUPABASE ap-south-1`
   - Observe pre-filled fields:
     - Shop ID: `shop_staging_001`
     - Owner Email: `staging-owner@tekfix.internal`
5. **Authenticate:**
   - Enter Password: `Staging@TekFix2026`
   - Tap **"പ്രവേശിക്കുക (Sign In)"**.
   - The app logs in immediately and opens **`AppShell`** (Owner Dashboard).
6. **Hardware Device Enrollment Acceptance:**
   - Navigate to **Owner Trusted Devices** within the ERP settings/recharge section to proceed with physical hardware key enrollment.
